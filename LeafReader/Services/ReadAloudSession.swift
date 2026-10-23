import AVFoundation
import Combine
import NaturalLanguage

struct ReadAloudPassage: Codable, Equatable {
    let text: String
    let locator: String
    let nextLocator: String
    let language: String
    let label: String
}

struct ReadAloudBookmark: Codable, Equatable {
    let locator: String
    let offset: Int
}

enum ReadAloudError: LocalizedError {
    case unavailable, noText, noVoice
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Open the book before listening."
        case .noText: return "There is no readable text here. Image-only pages cannot be read aloud."
        case .noVoice: return "No matching voice is available. Choose a voice in listening settings."
        }
    }
}

@MainActor protocol ReadAloudSpeaking: AnyObject {
    var finished: (() -> Void)? { get set }
    var progressed: ((NSRange) -> Void)? { get set }
    func speak(_ text: String, language: String, voice: String, speed: Double) throws
    func pause()
    func resume() -> Bool
    func stop()
}

@MainActor final class SystemReadAloudSpeaker: NSObject, ReadAloudSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    var finished: (() -> Void)?
    var progressed: ((NSRange) -> Void)?
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String, language: String, voice: String, speed: Double) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        var detected = recognizer.dominantLanguage?.rawValue
        if detected == "zh-Hans" { detected = "zh-CN" }
        if detected == "zh-Hant" { detected = "zh-TW" }
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
            ?? AVSpeechSynthesisVoice(language: detected ?? language)
            ?? AVSpeechSynthesisVoice(language: language)
        guard utterance.voice != nil else { throw ReadAloudError.noVoice }
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        current = utterance
        synthesizer.speak(utterance)
    }
    func pause() { synthesizer.pauseSpeaking(at: .immediate) }
    func resume() -> Bool { synthesizer.continueSpeaking() }
    func stop() { current = nil; synthesizer.stopSpeaking(at: .immediate) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }; self.current = nil; self.finished?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.current === utterance else { return }; self.progressed?(characterRange)
        }
    }
}

/// Only the playing passage and one prefetched passage are retained. Source
/// loading and speech are separate so navigation/reflow cannot alter the cursor.
@MainActor final class ReadAloudSession: ObservableObject {
    enum State: Equatable { case idle, loading, playing, paused, finished, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var passage: ReadAloudPassage?
    @Published private(set) var error: String?
    @Published private(set) var bookmark: ReadAloudBookmark?
    @Published var isPresented = false
    @Published var followsText = true
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "audio.speed"); restartVoice() } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: "audio.voice"); restartVoice() } }
    var source: ((String?) async throws -> ReadAloudPassage?)?
    var reveal: ((String) async -> Void)?
    private let speaker: any ReadAloudSpeaking
    private let defaults: UserDefaults
    private let bookmarkURL: URL?
    private var loadTask: Task<Void, Never>?
    private var prefetch: Task<ReadAloudPassage?, Error>?
    private var revealTask: Task<Void, Never>?
    private var generation = UUID()
    private var offset = 0
    private var utteranceOffset = 0
    private var history: [String] = []
    private var isLoading = false
    private var lastSavedAt = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    var canGoBack: Bool { !history.isEmpty }
    var isPlaying: Bool { state == .playing || state == .loading }
    var speedLabel: String { String(format: "%g×", speed) }

    init(bookmarkURL: URL? = nil, defaults: UserDefaults = .standard, speaker: (any ReadAloudSpeaking)? = nil) {
        self.bookmarkURL = bookmarkURL; self.defaults = defaults
        self.speaker = speaker ?? SystemReadAloudSpeaker()
        let savedSpeed = defaults.double(forKey: "audio.speed")
        speed = savedSpeed.isFinite && (0.5...2).contains(savedSpeed) ? savedSpeed : 1
        voice = defaults.string(forKey: "audio.voice") ?? ""
        if let bookmarkURL, let data = try? Data(contentsOf: bookmarkURL) {
            bookmark = try? JSONDecoder().decode(ReadAloudBookmark.self, from: data)
        }
        self.speaker.finished = { [weak self] in self?.advance() }
        self.speaker.progressed = { [weak self] range in
            guard let self, self.state == .playing else { return }
            self.offset = self.utteranceOffset + range.location
            if Date().timeIntervalSince(self.lastSavedAt) > 1 { self.saveBookmark() }
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            guard (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
    }
    deinit { for token in notificationTokens { NotificationCenter.default.removeObserver(token) } }

    func start(at locator: String? = nil, offset: Int = 0) {
        cancelWork(); history = []; passage = nil; self.offset = max(0, offset)
        error = nil; isPresented = true; state = .loading
        load(at: locator)
    }
    func resumeSaved() { if let bookmark { start(at: bookmark.locator, offset: bookmark.offset) } }
    func togglePlayback() { isPlaying ? pause() : resume() }
    func pause() {
        guard isPlaying else { return }; speaker.pause(); state = .paused; saveBookmark()
    }
    func resume() {
        guard state == .paused else {
            if state == .failed, let passage { start(at: passage.locator, offset: offset) }
            return
        }
        state = .playing
        if isLoading { state = .loading; return }
        if passage != nil, !speaker.resume() { speakCurrent() }
    }
    func next() { guard passage != nil, !isLoading else { return }; advance() }
    func previous() {
        guard let target = history.popLast() else { return }
        let paused = state == .paused
        let retained = history
        start(at: target); history = retained
        if paused { pause() }
    }
    func stop() {
        saveBookmark(); cancelWork(); state = .idle; isPresented = false
        passage = nil; error = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func cancelWork() {
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        isLoading = false
        prefetch?.cancel(); prefetch = nil; revealTask?.cancel(); revealTask = nil; speaker.stop()
    }
    private func load(at locator: String?, prepared: Task<ReadAloudPassage?, Error>? = nil) {
        let token = generation
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { isLoading = false } }
            do {
                guard let source else { throw ReadAloudError.unavailable }
                let next: ReadAloudPassage?
                if let prepared { next = try await prepared.value }
                else { next = try await source(locator) }
                guard !Task.isCancelled, generation == token else { return }
                guard let next else {
                    if passage == nil { throw ReadAloudError.noText }
                    state = .finished; bookmark = nil
                    if let bookmarkURL { try? FileManager.default.removeItem(at: bookmarkURL) }
                    return
                }
                guard !next.text.isEmpty, next.locator != next.nextLocator else { throw ReadAloudError.noText }
                passage = next; saveBookmark()
                let cursor = next.nextLocator
                prefetch = Task { try Task.checkCancellation(); return try await source(cursor) }
                if state != .paused { speakCurrent() }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription; state = .failed
            }
        }
    }
    private func speakCurrent() {
        guard let passage else { return }
        let text = passage.text as NSString
        offset = min(max(0, offset), max(0, text.length - 1))
        if offset > 0, CFStringIsSurrogateLowCharacter(text.character(at: offset)) { offset -= 1 }
        utteranceOffset = offset
        do {
            try speaker.speak(text.substring(from: offset), language: passage.language, voice: voice, speed: speed)
            state = .playing
            if followsText {
                revealTask?.cancel()
                let locator = passage.locator
                revealTask = Task { [weak self] in guard !Task.isCancelled else { return }; await self?.reveal?(locator) }
            }
        } catch { self.error = error.localizedDescription; state = .failed }
    }
    private func advance() {
        guard let passage else { return }
        let paused = state == .paused
        history.append(passage.locator); if history.count > 50 { history.removeFirst() }
        let prepared = prefetch; prefetch = nil
        speaker.stop(); loadTask?.cancel(); generation = UUID(); offset = 0
        state = paused ? .paused : .loading
        load(at: passage.nextLocator, prepared: prepared)
    }
    private func restartVoice() {
        guard passage != nil else { return }
        let playing = state == .playing
        speaker.stop(); if playing { speakCurrent() }
    }
    private func saveBookmark() {
        guard let passage, state != .finished else { return }
        let value = ReadAloudBookmark(locator: passage.locator, offset: offset)
        bookmark = value
        lastSavedAt = Date()
        guard let bookmarkURL, let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: bookmarkURL, options: .atomic)
    }
}
