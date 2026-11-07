import AVFoundation
import Combine
import UIKit

@MainActor protocol VoiceNoteRecording: AnyObject {
    func authorize() async -> Bool
    func start(at url: URL, limit: TimeInterval, finished: @escaping (Bool) -> Void) throws
    var currentTime: TimeInterval { get }
    func stop()
    func cancel()
}

@MainActor final class AppleVoiceNoteRecorder: NSObject, VoiceNoteRecording, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var completion: ((Bool) -> Void)?
    private var ownsSession = false
    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }
    func authorize() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func start(at url: URL, limit: TimeInterval, finished: @escaping (Bool) -> Void) throws {
        cancel()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true); ownsSession = true
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            self.recorder = recorder; completion = finished; recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record(forDuration: limit) else { throw VoiceNoteError.unavailable }
        } catch { cancel(); throw error }
    }
    func stop() { recorder?.stop() }
    func cancel() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; completion = nil
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.completion?(flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.completion?(false) }
    }
    deinit {
        recorder?.stop()
        if ownsSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

/// Owns a single unsaved recording and/or player. Audio never starts merely by
/// opening an editor. Closing, backgrounding and interruptions stop capture.
@MainActor final class VoiceNoteSession: ObservableObject {
    enum State: Equatable { case idle, authorizing, recording, processing, ready }
    static let willActivate = Notification.Name("LeafWillActivateVoiceNoteAudio")
    @Published private(set) var state = State.idle
    @Published private(set) var recordedNote: VoiceNote?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published var error: String?
    @Published private(set) var needsSettings = false
    private(set) var draftURL: URL?
    var isBusy: Bool { state == .authorizing || state == .recording || state == .processing }
    private let recorder: any VoiceNoteRecording
    private let limit: TimeInterval
    private var player: AVAudioPlayer?
    private var ownsPlaybackSession = false
    private var pendingURL: URL?
    private var token = UUID()
    private var operation: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(recorder: (any VoiceNoteRecording)? = nil, limit: TimeInterval = VoiceNote.maximumDuration) {
        self.recorder = recorder ?? Self.makeRecorder()
        self.limit = min(VoiceNote.maximumDuration, max(0.1, limit))
    }
    private static func makeRecorder() -> any VoiceNoteRecording {
        #if DEBUG
        if UITesting.flag("LEAF_UI_VOICE_NOTES") { return FixtureVoiceNoteRecorder() }
        #endif
        return AppleVoiceNoteRecorder()
    }
    func startRecording() {
        guard !isBusy else { return }
        discardDraft(); error = nil; needsSettings = false
        observeIfNeeded()
        NotificationCenter.default.post(name: Self.willActivate, object: self)
        let generation = UUID(); token = generation; state = .authorizing
        operation = Task { [weak self] in
            guard let self else { return }
            let allowed = await recorder.authorize()
            guard token == generation, !Task.isCancelled else { return }
            guard allowed else {
                state = .idle; needsSettings = true
                error = VoiceNoteError.microphonePermission.localizedDescription; return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LeafVoice-" + UUID().uuidString + ".m4a")
            pendingURL = url
            do {
                try recorder.start(at: url, limit: limit) { [weak self] success in
                    guard let self, self.token == generation else { return }
                    self.finishRecording(success: success)
                }
                state = .recording; elapsed = 0; startTicker()
                limitTask = Task { [weak self, limit] in
                    do { try await Task.sleep(for: .seconds(limit)); self?.stopRecording() } catch { }
                }
            } catch {
                recorder.cancel(); try? FileManager.default.removeItem(at: url); pendingURL = nil
                state = .idle; self.error = error.localizedDescription
            }
        }
    }
    func stopRecording() { finishRecording(success: true) }
    private func finishRecording(success: Bool) {
        guard state == .recording, let url = pendingURL else { return }
        state = .processing; limitTask?.cancel(); ticker?.cancel()
        recorder.stop(); recorder.cancel()
        guard success else {
            try? FileManager.default.removeItem(at: url); pendingURL = nil
            state = .idle; error = VoiceNoteError.unavailable.localizedDescription; return
        }
        let generation = token, id = UUID()
        operation = Task { [weak self] in
            do {
                let note = try await Task.detached(priority: .userInitiated) { try VoiceNoteFiles.inspect(url, id: id) }.value
                guard let self, self.token == generation, !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                self.recordedNote = note; self.draftURL = url; self.pendingURL = nil
                self.elapsed = note.duration; self.state = .ready
            } catch {
                try? FileManager.default.removeItem(at: url)
                guard let self, self.token == generation, !Task.isCancelled else { return }
                self.pendingURL = nil; self.state = .idle; self.error = error.localizedDescription
            }
        }
    }
    func togglePlayback(url: URL?) {
        guard !isBusy else { return }
        if isPlaying { pausePlayback(); return }
        error = nil
        do {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { throw VoiceNoteError.missingAudio }
            observeIfNeeded()
            NotificationCenter.default.post(name: Self.willActivate, object: self)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio); try audio.setActive(true); ownsPlaybackSession = true
            if player?.url != url {
                player = try AVAudioPlayer(contentsOf: url)
                #if DEBUG
                if UITesting.isActive || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { player?.volume = 0 }
                #endif
            }
            guard let player, player.duration.isFinite, player.duration > 0,
                  player.duration <= VoiceNote.maximumDuration + 0.1 else { throw VoiceNoteError.invalidRecording }
            if player.currentTime >= player.duration - 0.02 { player.currentTime = 0 }
            guard player.prepareToPlay(), player.play() else { throw VoiceNoteError.invalidRecording }
            playbackDuration = player.duration; playbackTime = player.currentTime; isPlaying = true; startTicker()
        } catch { stopPlayback(); self.error = error.localizedDescription }
    }
    func pausePlayback() {
        player?.pause(); playbackTime = player?.currentTime ?? playbackTime
        isPlaying = false; ticker?.cancel(); releasePlayback()
    }
    private func stopPlayback() {
        pausePlayback(); player?.stop(); player = nil; playbackTime = 0; playbackDuration = 0
    }
    private func releasePlayback() {
        if ownsPlaybackSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsPlaybackSession = false
        }
    }
    func suspend(background: Bool) {
        if state == .recording { stopRecording() }
        else if background && state == .authorizing { discardDraft() }
        pausePlayback()
    }
    func discardDraft() {
        token = UUID(); operation?.cancel(); limitTask?.cancel(); ticker?.cancel()
        recorder.cancel(); stopPlayback()
        for url in [pendingURL, draftURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        pendingURL = nil; draftURL = nil; recordedNote = nil; elapsed = 0; state = .idle
    }
    func close() {
        discardDraft()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                if self.state == .recording { self.elapsed = min(self.limit, self.recorder.currentTime) }
                if self.isPlaying {
                    self.playbackTime = self.player?.currentTime ?? 0
                    if self.player?.isPlaying != true { self.stopPlayback(); return }
                }
            }
        }
    }
    private func observeIfNeeded() {
        guard observers.isEmpty else { return }
        for name in [Self.willActivate, ReadAloudAudioSession.willActivate, ChatDictationSession.willRecord] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as AnyObject? !== self else { return }
                    self.suspend(background: true)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                MainActor.assumeIsolated { self?.suspend(background: true) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                MainActor.assumeIsolated { self?.suspend(background: true) }
            }
        })
    }
    deinit {
        operation?.cancel(); ticker?.cancel(); limitTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for url in [pendingURL, draftURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        if ownsPlaybackSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

#if DEBUG
/// Deterministic, real AAC files for UI/storage/player checks, not microphone QA.
@MainActor private final class FixtureVoiceNoteRecorder: VoiceNoteRecording {
    private var url: URL?
    private var started = Date()
    var currentTime: TimeInterval { Date().timeIntervalSince(started) }
    func authorize() async -> Bool { UITesting.environment("LEAF_UI_VOICE_NOTE_PERMISSION") != "denied" }
    func start(at url: URL, limit: TimeInterval, finished: @escaping (Bool) -> Void) throws { self.url = url; started = Date() }
    func stop() {
        guard let url else { return }; self.url = nil
        try? VoiceNoteFixture.write(to: url, duration: 5)
    }
    func cancel() { url = nil }
}
enum VoiceNoteFixture {
    static func write(to url: URL, duration: TimeInterval = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let count = AVAudioFrameCount(24_000 * min(10, max(0.1, duration)))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for index in 0..<Int(count) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 24_000) * 0.03) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try file.write(from: buffer)
    }
}
#endif
