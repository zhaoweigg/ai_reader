import AVFoundation
import Combine
import NaturalLanguage

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

@MainActor protocol ReadAloudSpeaking: AnyObject {
    var finished: (() -> Void)? { get set }
    var progressed: ((NSRange) -> Void)? { get set }
    func speak(_ text: String, language: String, voice: String, speed: Double) throws
    /// Optional warm-up for the passage that follows the one being spoken.
    func prepare(_ text: String, language: String, voice: String, speed: Double)
    func pause()
    func resume() -> Bool
    func stop()
}
extension ReadAloudSpeaking {
    func prepare(_ text: String, language: String, voice: String, speed: Double) {}
}

/// The iPhone voice. A passage is spoken as a queue of sentence/clause-sized
/// utterances (the Kokoro chunk limits) rather than one utterance, because only
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
    var finished: (() -> Void)?
    var progressed: ((NSRange) -> Void)?
    func speak(_ text: String, language: String, voice: String, speed: Double) throws {
        stop()
        if synthesizer == nil {
            synthesizer = AVSpeechSynthesizer(); synthesizer?.delegate = self
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
        var detected = recognizer.dominantLanguage?.rawValue
        if detected == "zh-Hans" { detected = "zh-CN" }
        if detected == "zh-Hant" { detected = "zh-TW" }
        let selected = AVSpeechSynthesisVoice(identifier: voice)
            ?? AVSpeechSynthesisVoice(language: detected ?? language)
            ?? AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        guard let selected else { throw ReadAloudError.noVoice }
        let rate = min(AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
        // A passage with no letters or digits yields no chunks; speak it whole.
        var chunks = KokoroSentenceSplitter.split(text)
        if chunks.isEmpty { chunks = [KokoroSentence(text: text, range: NSRange(location: 0, length: (text as NSString).length))] }
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
    @Published private(set) var state: State = .idle
    @Published private(set) var passage: ReadAloudPassage?
    @Published private(set) var error: String?
    @Published private(set) var bookmark: ReadAloudBookmark?
    @Published private(set) var spokenText = ""
    @Published var isPresented = false
    @Published var followsText: Bool { didSet {
        defaults.set(followsText, forKey: "audio.followsText")
        if let passage, let spokenRange { highlight?(passage, spokenRange, followsText) }
    } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "audio.speed"); restartVoice() } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: "audio.voice"); restartVoice() } }
    /// `.kokoro` speaks with the downloaded on-device model; the iPhone voice is
    /// used for any passage the model cannot start.
    @Published var engine: ReadAloudEngine { didSet { defaults.set(engine.rawValue, forKey: "audio.engine"); restartVoice() } }
    /// Kokoro voice id, or empty for automatic selection by the text's script.
    @Published var kokoroVoice: String { didSet { defaults.set(kokoroVoice, forKey: "audio.kokoroVoice"); restartVoice() } }
    /// True while the on-device model is generating audio that has not started playing.
    @Published private(set) var isBuffering = false
    /// Why the last passage used the iPhone voice although the on-device engine was selected.
    @Published private(set) var fallbackReason: String?
    var voiceModel: KokoroModelStore? { (speaker as? RoutingReadAloudSpeaker)?.kokoro.store }
    var effectiveVoice: String { engine == .kokoro ? ReadAloudEngine.kokoroPrefix + kokoroVoice : voice }
    var source: ((String?) async throws -> ReadAloudPassage?)?
    var reveal: ((String) async -> Void)?
    var clearSource: (() -> Void)?
    var highlight: ((ReadAloudPassage?, NSRange, Bool) -> Void)?
    private let speaker: any ReadAloudSpeaking
    private let defaults: UserDefaults
    private let bookmarkURL: URL?
    private var loadTask: Task<Void, Never>?
    private var prefetch: Task<ReadAloudPassage?, Error>?
    private var warmTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var generation = UUID()
    private var offset = 0
    private var utteranceOffset = 0
    private var spokenRange: NSRange?
    private var history: [String] = []
    private var isLoading = false
    private var lastSavedAt = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    var canGoBack: Bool { !history.isEmpty }
    var isPlaying: Bool { state == .playing || state == .loading }
    var speedLabel: String { String(format: "%g×", speed) }

    init(bookmarkURL: URL? = nil, defaults: UserDefaults = .standard, speaker: (any ReadAloudSpeaking)? = nil) {
        self.bookmarkURL = bookmarkURL; self.defaults = defaults
        self.speaker = speaker ?? RoutingReadAloudSpeaker(system: SystemReadAloudSpeaker(), kokoro: KokoroReadAloudSpeaker(store: .shared))
        let savedSpeed = defaults.double(forKey: "audio.speed")
        speed = savedSpeed.isFinite && (0.5...2).contains(savedSpeed) ? savedSpeed : 1
        voice = defaults.string(forKey: "audio.voice") ?? ""
        engine = ReadAloudEngine(rawValue: defaults.string(forKey: "audio.engine") ?? "") ?? .system
        kokoroVoice = defaults.string(forKey: "audio.kokoroVoice") ?? ""
        followsText = defaults.object(forKey: "audio.followsText") == nil || defaults.bool(forKey: "audio.followsText")
        if let bookmarkURL, let data = try? Data(contentsOf: bookmarkURL) {
            bookmark = try? JSONDecoder().decode(ReadAloudBookmark.self, from: data)
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
            self.highlight?(passage, spoken, self.followsText)
            if Date().timeIntervalSince(self.lastSavedAt) > 1 { self.saveBookmark() }
        }
        (self.speaker as? ReadAloudBufferingReporter)?.buffering = { [weak self] buffering in self?.isBuffering = buffering }
        (self.speaker as? RoutingReadAloudSpeaker)?.onFallback = { [weak self] reason in self?.fallbackReason = reason }
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
        clearHighlight()
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        isLoading = false
        prefetch?.cancel(); prefetch = nil; warmTask?.cancel(); warmTask = nil
        revealTask?.cancel(); revealTask = nil; speaker.stop(); isBuffering = false
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
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    if let bookmarkURL { try? FileManager.default.removeItem(at: bookmarkURL) }
                    return
                }
                guard !next.text.isEmpty, next.locator != next.nextLocator else { throw ReadAloudError.noText }
                passage = next; saveBookmark()
                let cursor = next.nextLocator
                let prefetch = Task { try Task.checkCancellation(); return try await source(cursor) }
                self.prefetch = prefetch
                // Warm the on-device voice for the next passage once its text is known.
                warmTask?.cancel()
                warmTask = Task { [weak self] in
                    guard let upcoming = try? await prefetch.value, let self, !Task.isCancelled, generation == token else { return }
                    speaker.prepare(upcoming.text, language: upcoming.language, voice: effectiveVoice, speed: speed)
                }
                if state != .paused { speakCurrent() }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                self.error = error.localizedDescription; state = .failed
                clearHighlight()
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
            try speaker.speak(text.substring(from: offset), language: passage.language, voice: effectiveVoice, speed: speed)
            state = .playing
            // Start/resume at the saved speech offset, not at the beginning of
            // its up-to-800-character passage while waiting for a voice callback.
            let length = CFStringIsSurrogateHighCharacter(text.character(at: offset)) ? 2 : 1
            let range = NSRange(location: offset, length: min(length, text.length - offset))
            spokenRange = range
            if let highlight { highlight(passage, range, followsText) }
            else if followsText {
                revealTask?.cancel()
                let locator = passage.locator
                revealTask = Task { [weak self] in guard !Task.isCancelled else { return }; await self?.reveal?(locator) }
            }
        } catch { self.error = error.localizedDescription; state = .failed; clearHighlight() }
    }
    private func advance() {
        guard let passage else { return }
        clearHighlight()
        let paused = state == .paused
        history.append(passage.locator); if history.count > 50 { history.removeFirst() }
        let prepared = prefetch; prefetch = nil; warmTask?.cancel(); warmTask = nil
        speaker.stop(); isBuffering = false; loadTask?.cancel(); generation = UUID(); offset = 0
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
        highlight?(nil, NSRange(location: 0, length: 0), false)
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
