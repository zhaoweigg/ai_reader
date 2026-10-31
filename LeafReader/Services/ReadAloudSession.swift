import AVFoundation
import Combine
import MediaPlayer
import NaturalLanguage
import UIKit

struct ReadAloudSegment: Codable, Equatable {
    let offset: Int
    let length: Int
    let locator: String
}

struct ReadAloudPassage: Codable, Equatable {
    let text: String
    let locator: String
    let nextLocator: String
    let language: String
    let label: String
    let segments: [ReadAloudSegment]?

    init(text: String, locator: String, nextLocator: String, language: String, label: String, segments: [ReadAloudSegment] = []) {
        self.text = text; self.locator = locator; self.nextLocator = nextLocator
        self.language = language; self.label = label; self.segments = segments
    }
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

/// The audio session used by Apple narration.
enum ReadAloudAudioSession {
    static let willActivate = Notification.Name("LeafWillActivateReadAloudAudio")
    /// Takes the spoken-audio playback category; other apps' audio ducks or pauses.
    static func activate() throws {
        NotificationCenter.default.post(name: willActivate, object: nil)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }
    /// Hands audio back to other apps. A failure leaves nothing to recover, so it is ignored.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The book a narration belongs to, as the Lock Screen and Control Center present it.
struct ReadAloudBookInfo: Equatable {
    var title: String
    var author: String
    var coverURL: URL?
}

/// What the Lock Screen and Control Center show and which of their buttons work.
struct ReadAloudNowPlayingInfo: Equatable {
    var title: String
    var author: String
    var chapter: String
    var isPlaying: Bool
    var canGoNext: Bool
    var canGoBack: Bool
}

enum ReadAloudRemoteCommand { case play, pause, toggle, next, previous }

@MainActor protocol ReadAloudNowPlayingPresenting: AnyObject {
    /// Play, pause, next and previous from the Lock Screen, Control Center, headphones or CarPlay.
    var handler: ((ReadAloudRemoteCommand) -> Void)? { get set }
    func show(_ info: ReadAloudNowPlayingInfo, artwork: UIImage?)
    func clear()
}

/// The system Now Playing surfaces: `MPNowPlayingInfoCenter` fills the Lock Screen and
/// Control Center player, `MPRemoteCommandCenter` routes their buttons back. Passages
/// stand in for tracks, so next/previous move by passage and seeking stays off.
@MainActor final class SystemNowPlayingPresenter: ReadAloudNowPlayingPresenting {
    var handler: ((ReadAloudRemoteCommand) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []
    init() {
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, ReadAloudRemoteCommand.play), (center.pauseCommand, .pause), (center.togglePlayPauseCommand, .toggle),
                                  (center.nextTrackCommand, .next), (center.previousTrackCommand, .previous)] {
            targets.append((command, command.addTarget { [weak self] _ in
                Task { @MainActor in self?.handler?(action) }
                return .success
            }))
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand, center.seekForwardCommand, center.seekBackwardCommand,
                        center.changePlaybackPositionCommand, center.changePlaybackRateCommand] { command.isEnabled = false }
    }
    deinit { for (command, target) in targets { command.removeTarget(target) } }
    func show(_ info: ReadAloudNowPlayingInfo, artwork: UIImage?) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true; center.pauseCommand.isEnabled = true; center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = info.canGoNext; center.previousTrackCommand.isEnabled = info.canGoBack
        var payload: [String: Any] = [
            MPMediaItemPropertyTitle: info.title, MPMediaItemPropertyArtist: info.author, MPMediaItemPropertyAlbumTitle: info.chapter,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0, MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue, MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let artwork { payload[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = payload
    }
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = false; center.previousTrackCommand.isEnabled = false
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
/// The iPhone voice. A passage is spoken as a queue of sentence/clause-sized
/// utterances rather than one utterance, because only
/// some voices report word ranges through `willSpeakRangeOfSpeechString`; with a
/// voice that reports none, a single utterance per passage left the highlight on
/// the passage's first line until the next passage. Every utterance start is
/// reported exactly through `didStart`, so progress is at least per sentence
/// with any voice and per word where the voice provides words.
@MainActor final class SystemReadAloudSpeaker: NSObject, ReadAloudSpeaking, AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    /// Queued utterances with the UTF-16 offset of each chunk in the spoken text.
    private var queue: [(utterance: AVSpeechUtterance, offset: Int, firstWord: Int)] = []
    private var last: AVSpeechUtterance?
    /// Test hook: false ignores the voice's word ranges so chunk starts alone drive progress.
    var reportsWordRanges = true
    private let requiresHighQuality: Bool
    private let installedVoices: () -> [AppleReadingVoice]
    var finished: (() -> Void)?
    var progressed: ((NSRange) -> Void)?
    // Direct speaker adapters can exercise system timing with simulator voices.
    // Production always uses the strict downloaded-quality policy.
    init(requiresHighQuality: Bool = false, installedVoices: @escaping () -> [AppleReadingVoice] = { AppleVoiceCatalog.installed }) {
        self.requiresHighQuality = requiresHighQuality; self.installedVoices = installedVoices
        super.init()
    }
    func speak(_ text: String, language: String, voice: String, speed: Double) throws {
        stop()
        if synthesizer == nil {
            synthesizer = AVSpeechSynthesizer(); synthesizer?.delegate = self
            synthesizer?.usesApplicationAudioSession = true
        }
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        var detected = recognizer.dominantLanguage?.rawValue
        if detected == "zh-Hans" { detected = "zh-CN" }
        if detected == "zh-Hant" { detected = "zh-TW" }
        // Resolve eligibility before taking over the audio session: a missing
        // download must leave other audio untouched.
        let selected = try selectedVoice(identifier: voice, detectedLanguage: detected, sourceLanguage: language)
        try ReadAloudAudioSession.activate()
        let rate = min(AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        // A passage with no letters or digits yields no chunks; speak it whole.
        var chunks = ReadAloudSentenceSplitter.split(text)
        if chunks.isEmpty { chunks = [ReadAloudSentence(text: text, range: NSRange(location: 0, length: (text as NSString).length))] }
        queue = chunks.map { chunk in
            let utterance = AVSpeechUtterance(string: chunk.text)
            utterance.voice = selected; utterance.rate = rate
            let units = Array(chunk.text.utf16)
            let word = units.firstIndex { $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x3000 } ?? units.count
            return (utterance, chunk.range.location, max(1, word))
        }
        last = queue.last?.utterance
        for item in queue { synthesizer?.speak(item.utterance) }
    }
    private func selectedVoice(identifier: String, detectedLanguage: String?, sourceLanguage: String) throws -> AVSpeechSynthesisVoice {
        if requiresHighQuality {
            let language = detectedLanguage?.isEmpty == false ? detectedLanguage!
                : sourceLanguage.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : sourceLanguage
            guard let id = AppleVoiceCatalog.preferredIdentifier(selected: identifier, language: language, voices: installedVoices()),
                  let selected = AVSpeechSynthesisVoice(identifier: id),
                  selected.quality == .enhanced || selected.quality == .premium else { throw AppleReadingVoiceError.downloadRequired }
            return selected
        }
        guard let selected = AVSpeechSynthesisVoice(identifier: identifier)
            ?? AVSpeechSynthesisVoice(language: detectedLanguage ?? sourceLanguage)
            ?? AVSpeechSynthesisVoice(language: sourceLanguage)
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode()) else { throw ReadAloudError.noVoice }
        return selected
    }
    func pause() { synthesizer?.pauseSpeaking(at: .immediate) }
    func resume() -> Bool { synthesizer?.continueSpeaking() ?? false }
    func stop() { queue = []; last = nil; synthesizer?.stopSpeaking(at: .immediate) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, let item = self.queue.first(where: { $0.utterance === utterance }) else { return }
            self.progressed?(NSRange(location: item.offset, length: item.firstWord))
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.last === utterance else { return }
            self.queue = []; self.last = nil; self.finished?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.reportsWordRanges, let item = self.queue.first(where: { $0.utterance === utterance }) else { return }
            self.progressed?(NSRange(location: item.offset + characterRange.location, length: characterRange.length))
        }
    }
}

/// Only the playing passage and one prefetched passage are retained. Source
/// loading and speech are separate so navigation/reflow cannot alter the cursor.
@MainActor final class ReadAloudSession: ObservableObject {
    enum State: Equatable { case idle, loading, playing, paused, finished, failed }
    @Published private(set) var state: State = .idle { didSet { if state != oldValue { publishNowPlaying() } } }
    @Published private(set) var passage: ReadAloudPassage? { didSet { if passage != oldValue { publishNowPlaying() } } }
    /// The book being read, for the Lock Screen and Control Center.
    var book: ReadAloudBookInfo? { didSet {
        guard book != oldValue else { return }
        artwork = book?.coverURL.flatMap { UIImage(contentsOfFile: $0.path) }
        publishNowPlaying()
    } }
    private var artwork: UIImage?
    private let nowPlaying: any ReadAloudNowPlayingPresenting
    @Published private(set) var error: String?
    @Published private(set) var bookmark: ReadAloudBookmark?
    @Published private(set) var spokenText = ""
    @Published var isPresented = false
    @Published var followsText: Bool { didSet {
        defaults.set(followsText, forKey: "audio.followsText")
        if isForeground, let passage, let spokenRange { highlight?(passage, spokenRange, followsText) }
    } }
    @Published var speed: Double { didSet {
        defaults.set(speed, forKey: "audio.speed.system")
        restartVoice()
    } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: "audio.voice"); restartVoice() } }
    var source: ((String?) async throws -> ReadAloudPassage?)?
    var reveal: ((String) async -> Void)?
    var clearSource: (() -> Void)?
    var highlight: ((ReadAloudPassage?, NSRange, Bool) -> Void)?
    private let speaker: any ReadAloudSpeaking
    private let defaults: UserDefaults
    private let bookmarkURL: URL?
    private var loadTask: Task<Void, Never>?
    private var prefetch: Task<ReadAloudPassage?, Error>?
    private var revealTask: Task<Void, Never>?
    private var generation = UUID()
    private var offset = 0
    private var utteranceOffset = 0
    private var spokenRange: NSRange?
    private var history: [String] = []
    private var isLoading = false
    private var isForeground = true
    private var lastSavedAt = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    #if DEBUG
    private var backgroundStarts: [TimeInterval] = []
    private var firstBackgroundProgress: TimeInterval?
    /// Opt-in fixture evidence, with no book text, locators, or account data.
    var backgroundPlaybackTestEvidence: String {
        let proof: [String: Any] = ["starts": backgroundStarts, "firstProgress": firstBackgroundProgress ?? -1]
        return (try? JSONSerialization.data(withJSONObject: proof)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    #endif
    var canGoBack: Bool { !history.isEmpty }
    var isPlaying: Bool { state == .playing || state == .loading }
    var speedLabel: String { String(format: "%g×", speed) }

    private static func savedSpeed(defaults: UserDefaults) -> Double {
        let saved = defaults.double(forKey: "audio.speed.system")
        if saved.isFinite && (0.5...2).contains(saved) { return saved }
        // Preserve Apple's own rate, or migrate the pre-engine shared preference.
        let legacy = defaults.double(forKey: "audio.speed")
        let migrated = legacy.isFinite && (0.5...2).contains(legacy) ? legacy : 1
        defaults.set(migrated, forKey: "audio.speed.system")
        return migrated
    }

    init(bookmarkURL: URL? = nil, defaults: UserDefaults = .standard, speaker: (any ReadAloudSpeaking)? = nil,
         nowPlaying: (any ReadAloudNowPlayingPresenting)? = nil) {
        self.bookmarkURL = bookmarkURL; self.defaults = defaults
        self.nowPlaying = nowPlaying ?? SystemNowPlayingPresenter()
        var highQuality = true
        #if DEBUG
        // Explicit simulator UI launches can exercise real AVSpeech playback with
        // the runtime's installed voices; ordinary launches always stay strict.
        if UITesting.testID != nil, UITesting.flag("LEAF_UI_APPLE_SPEECH") { highQuality = false }
        #endif
        self.speaker = speaker ?? SystemReadAloudSpeaker(requiresHighQuality: highQuality)
        speed = Self.savedSpeed(defaults: defaults)
        for key in ["audio.engine", "audio.kokoroVoice", "audio.speed.kokoro"] { defaults.removeObject(forKey: key) }
        let savedVoice = defaults.string(forKey: "audio.voice") ?? ""
        let eligibleVoice = AppleVoiceCatalog.installed.contains(where: { $0.id == savedVoice }) ? savedVoice : ""
        voice = eligibleVoice
        if savedVoice != eligibleVoice { defaults.set(eligibleVoice, forKey: "audio.voice") }
        followsText = defaults.object(forKey: "audio.followsText") == nil || defaults.bool(forKey: "audio.followsText")
        if let bookmarkURL, let data = try? Data(contentsOf: bookmarkURL) {
            bookmark = try? JSONDecoder().decode(ReadAloudBookmark.self, from: data)
        }
        self.nowPlaying.handler = { [weak self] command in
            guard let self else { return }
            switch command {
            case .play: resume()
            case .pause: pause()
            case .toggle: togglePlayback()
            case .next: next()
            case .previous: previous()
            }
        }
        self.speaker.finished = { [weak self] in self?.advance() }
        self.speaker.progressed = { [weak self] range in
            guard let self, self.state == .playing, let passage = self.passage,
                  range.location != NSNotFound, range.length > 0 else { return }
            let count = (passage.text as NSString).length
            self.offset = min(count, self.utteranceOffset + range.location)
            let spoken = NSRange(location: self.offset, length: min(range.length, count - self.offset))
            self.spokenRange = spoken
            self.spokenText = (passage.text as NSString).substring(with: spoken)
            #if DEBUG
            if !self.isForeground, UITesting.flag("LEAF_UI_BACKGROUND_AUDIO"), self.firstBackgroundProgress == nil {
                self.firstBackgroundProgress = ProcessInfo.processInfo.systemUptime
            }
            #endif
            if self.isForeground { self.highlight?(passage, spoken, self.followsText) }
            if Date().timeIntervalSince(self.lastSavedAt) > 1 { self.saveBookmark() }
        }
        notificationTokens.append(NotificationCenter.default.addObserver(forName: ChatDictationSession.willRecord, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
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

    /// Locking the phone suspends presentation, not narration. Keep the bounded
    /// source/prefetch and speech cursor running without navigating hidden pages.
    func setForeground(_ active: Bool) {
        guard isForeground != active else { return }
        isForeground = active
        if !active {
            revealTask?.cancel(); revealTask = nil
            saveBookmark()
        } else if let passage, let spokenRange {
            if let highlight { highlight(passage, spokenRange, followsText) }
            else if followsText { revealCurrent(passage.locator) }
        } else {
            highlight?(nil, NSRange(location: 0, length: 0), false)
        }
    }

    func start(at locator: String? = nil, offset: Int = 0) {
        cancelWork(); history = []; passage = nil; self.offset = max(0, offset)
        #if DEBUG
        backgroundStarts = []; firstBackgroundProgress = nil
        #endif
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
        if passage != nil {
            // Dictation may have changed the category and released the session.
            do { try ReadAloudAudioSession.activate() }
            catch { fail(error); saveBookmark(); return }
            if !speaker.resume() { speakCurrent() }
        }
    }
    func next() { guard passage != nil, !isLoading else { return }; advance() }
    func previous() {
        guard let target = history.popLast() else { return }
        let paused = state == .paused
        let retained = history
        start(at: target); history = retained
        if paused { pause() }
        publishNowPlaying()
    }
    /// The Lock Screen and Control Center mirror the player while a narration is
    /// open; stopping or reaching the end of the book takes it down.
    private func publishNowPlaying() {
        guard isPresented, [.loading, .playing, .paused, .failed].contains(state) else { nowPlaying.clear(); return }
        nowPlaying.show(ReadAloudNowPlayingInfo(title: book?.title ?? "Leaf", author: book?.author ?? "", chapter: passage?.label ?? "",
                                                isPlaying: state == .playing, canGoNext: passage != nil && state != .loading, canGoBack: canGoBack),
                        artwork: artwork)
    }
    func stop() {
        saveBookmark(); cancelWork(); state = .idle; isPresented = false
        passage = nil; error = nil
        ReadAloudAudioSession.deactivate()
    }
    private func cancelWork() {
        clearHighlight()
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        isLoading = false
        prefetch?.cancel(); prefetch = nil
        revealTask?.cancel(); revealTask = nil; speaker.stop()
        clearSource?()
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
                    clearHighlight()
                    clearSource?()
                    ReadAloudAudioSession.deactivate()
                    if let bookmarkURL { try? FileManager.default.removeItem(at: bookmarkURL) }
                    return
                }
                guard !next.text.isEmpty, next.locator != next.nextLocator else { throw ReadAloudError.noText }
                passage = next; saveBookmark()
                let cursor = next.nextLocator
                let prefetch = Task { try Task.checkCancellation(); return try await source(cursor) }
                self.prefetch = prefetch
                if state != .paused { speakCurrent() }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                fail(error)
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
            #if DEBUG
            if !isForeground, UITesting.flag("LEAF_UI_BACKGROUND_AUDIO"), backgroundStarts.count < 4 {
                backgroundStarts.append(ProcessInfo.processInfo.systemUptime)
            }
            #endif
            // Start/resume at the saved speech offset, not at the beginning of
            // its up-to-800-character passage while waiting for a voice callback.
            let length = CFStringIsSurrogateHighCharacter(text.character(at: offset)) ? 2 : 1
            let range = NSRange(location: offset, length: min(length, text.length - offset))
            spokenRange = range
            if isForeground {
                if let highlight { highlight(passage, range, followsText) }
                else if followsText { revealCurrent(passage.locator) }
            }
        } catch { fail(error) }
    }
    /// Reports an error for the current passage; the cursor is kept so Resume can retry it.
    private func fail(_ error: Error) {
        self.error = error.localizedDescription; state = .failed
        clearHighlight()
    }
    private func advance() {
        guard let passage else { return }
        clearHighlight()
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
    private func clearHighlight() {
        spokenRange = nil
        spokenText = ""
        if isForeground { highlight?(nil, NSRange(location: 0, length: 0), false) }
    }
    private func revealCurrent(_ locator: String) {
        revealTask?.cancel()
        revealTask = Task { [weak self] in guard !Task.isCancelled else { return }; await self?.reveal?(locator) }
    }
    private func saveBookmark() {
        guard let passage, state != .finished else { return }
        let value = ReadAloudBookmark(locator: passage.locator, offset: offset)
        bookmark = value
        lastSavedAt = Date()
        guard let bookmarkURL, let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: bookmarkURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
