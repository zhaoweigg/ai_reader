import AVFoundation
import Speech
import Combine
import NaturalLanguage

enum DictationLanguage: String, CaseIterable, Identifiable {
    case system, mandarin, traditionalChinese, cantonese, english
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Automatic · book or device"
        case .mandarin: return "中文 · 普通话"
        case .traditionalChinese: return "中文 · 國語"
        case .cantonese: return "中文 · 廣東話"
        case .english: return "English"
        }
    }
    var locale: String {
        switch self {
        case .system: return Locale.preferredLanguages.first ?? Locale.current.identifier
        case .mandarin: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .cantonese: return "zh-HK"
        case .english: return "en-US"
        }
    }
    func resolvedLocale(bookTitle: String, selectedText: String? = nil, deviceLanguage: String? = nil) -> String {
        guard self == .system else { return locale }
        // The phone's interface language doesn't tell us which language a reader
        // wants to speak. Chinese book/quote context takes precedence in Automatic.
        for text in [bookTitle, selectedText ?? ""] where !text.isEmpty {
            let detector = NLLanguageRecognizer()
            detector.processString(String(text.prefix(256)))
            if detector.dominantLanguage == .simplifiedChinese { return "zh-CN" }
            if detector.dominantLanguage == .traditionalChinese { return "zh-TW" }
        }
        return deviceLanguage ?? locale
    }
    static func shortLabel(locale: String) -> String {
        let code = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        if code.hasPrefix("yue") || code.hasPrefix("zh-hk") { return "粤语" }
        if code.hasPrefix("zh") { return "中文" }
        return String(code.prefix(2)).uppercased()
    }
}

enum ChatDictationError: LocalizedError, Equatable {
    case microphonePermission, speechPermission, unavailable, noMicrophone, noSpeech
    var errorDescription: String? {
        switch self {
        case .microphonePermission: return "Allow microphone access for Leaf in Settings to dictate a question."
        case .speechPermission: return "Allow speech recognition for Leaf in Settings to turn your voice into text."
        case .unavailable: return "Speech recognition is unavailable for this language right now. Try another language or check your connection."
        case .noMicrophone: return "No microphone is available. Check your audio connection and try again."
        case .noSpeech: return "No speech was heard. Tap the microphone and try again."
        }
    }
}

@MainActor protocol ChatDictationRecognizing: AnyObject {
    func authorize() async throws
    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws
    func finish()
    func cancel()
}

/// Owns only the current microphone stream. No audio recordings are written to disk.
@MainActor final class AppleChatDictationRecognizer: ChatDictationRecognizing {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var hasTap = false
    private var ownsAudioSession = false
    #if DEBUG
    var testAudioFile: URL?
    private var fileRequest: SFSpeechURLRecognitionRequest?
    #endif

    func authorize() async throws {
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard microphone else { throw ChatDictationError.microphonePermission }
        try Task.checkCancellation()
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { throw ChatDictationError.speechPermission }
    }

    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw ChatDictationError.unavailable
        }
        #if DEBUG
        if let testAudioFile {
            let request = SFSpeechURLRecognitionRequest(url: testAudioFile)
            fileRequest = request; self.recognizer = recognizer
            recognize(request, with: recognizer, update: update, failure: failure)
            return
        }
        #endif
        // Synchronous: pause Leaf's read-aloud before taking the audio session.
        NotificationCenter.default.post(name: ChatDictationSession.willRecord, object: nil)
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true)
            ownsAudioSession = true
            let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
            self.engine = engine; self.request = request; self.recognizer = recognizer
            let input = engine.inputNode, format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ChatDictationError.noMicrophone }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            recognize(request, with: recognizer, update: update, failure: failure)
            engine.prepare()
            try engine.start()
        } catch { cancel(); throw error }
    }

    private func recognize(_ request: SFSpeechRecognitionRequest, with recognizer: SFSpeechRecognizer,
                           update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) {
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false
            Task { @MainActor in
                if let text { update(text, final) }
                if let error, !final { failure(error) }
            }
        }
    }

    func finish() {
        stopCapture()
        request?.endAudio()
    }
    func cancel() {
        stopCapture()
        request?.endAudio(); task?.cancel()
        task = nil; request = nil; recognizer = nil
        #if DEBUG
        fileRequest = nil
        #endif
    }
    private func stopCapture() {
        if hasTap { engine?.inputNode.removeTap(onBus: 0); hasTap = false }
        engine?.stop(); engine = nil
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }
}

@MainActor final class ChatDictationSession: ObservableObject {
    enum State: Equatable { case idle, authorizing, recording, finishing }
    static let willRecord = Notification.Name("LeafWillRecordDictation")
    @Published private(set) var state: State = .idle
    @Published var error: String?
    @Published private(set) var needsSettings = false
    @Published private(set) var localeIdentifier: String?
    var isActive: Bool { state != .idle }
    var status: String {
        switch state {
        case .idle: return ""
        case .authorizing: return "Starting microphone…"
        case .recording: return "Listening…"
        case .finishing: return "Finishing…"
        }
    }
    private let recognizer: any ChatDictationRecognizing
    private let recordingLimit: Duration
    private let finishLimit: Duration
    private var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var token = UUID()
    private var baseDraft = ""
    private var transcript = ""
    private var applyDraft: ((String) -> Void)?

    init(recognizer: (any ChatDictationRecognizing)? = nil, recordingLimit: Duration = .seconds(60), finishLimit: Duration = .seconds(2)) {
        self.recognizer = recognizer ?? Self.makeRecognizer()
        self.recordingLimit = recordingLimit; self.finishLimit = finishLimit
    }
    private static func makeRecognizer() -> any ChatDictationRecognizing {
        #if DEBUG
        if let encoded = UITesting.environment("LEAF_UI_DICTATION_NATIVE_AUDIO") {
            guard let audio = Data(base64Encoded: encoded) else { return UnavailableDictationFixture() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-mandarin-dictation.m4a")
            do {
                try audio.write(to: url)
                let recognizer = AppleChatDictationRecognizer(); recognizer.testAudioFile = url
                return recognizer
            } catch { return UnavailableDictationFixture() }
        }
        if UITesting.flag("LEAF_UI_DICTATION_MOCK") { return FixtureChatDictationRecognizer() }
        #endif
        return AppleChatDictationRecognizer()
    }

    func start(draft: String, language: DictationLanguage, bookTitle: String = "", selectedText: String? = nil, apply: @escaping (String) -> Void) {
        guard !isActive else { return }
        error = nil; needsSettings = false; baseDraft = draft; transcript = ""; applyDraft = apply
        let generation = UUID(); token = generation; state = .authorizing
        let locale = language.resolvedLocale(bookTitle: bookTitle, selectedText: selectedText)
        localeIdentifier = locale
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.authorize()
                guard token == generation, !Task.isCancelled else { return }
                try recognizer.start(locale: locale, update: { [weak self] text, final in
                    guard let self, self.token == generation, self.isActive else { return }
                    self.transcript = text
                    self.applyDraft?(Self.appending(text, to: self.baseDraft))
                    if final { self.complete() }
                }, failure: { [weak self] error in
                    guard let self, self.token == generation, self.isActive else { return }
                    if self.state == .finishing { self.complete() }
                    else { self.fail(error) }
                })
                guard token == generation, isActive else { return }
                state = .recording
                timeout = Task { [weak self, recordingLimit] in
                    do { try await Task.sleep(for: recordingLimit); self?.finish() } catch { }
                }
            } catch {
                if token == generation, !Task.isCancelled { fail(error) }
            }
        }
    }
    func finish() {
        guard isActive else { return }
        if state == .authorizing { cancel(); return }
        guard state != .finishing else { return }
        state = .finishing; timeout?.cancel(); recognizer.finish()
        guard state == .finishing else { return }
        // A recognizer need not emit a final result after an interruption or silence.
        timeout = Task { [weak self, finishLimit] in
            do { try await Task.sleep(for: finishLimit); self?.complete() } catch { }
        }
    }
    /// Closing/backgrounding keeps text already transcribed, but accepts no late results.
    func suspend(background: Bool) {
        // A system permission dialog can temporarily deactivate the scene.
        // It must be allowed to finish the first-use authorization sequence.
        if background || state != .authorizing { cancel() }
    }
    func cancel() {
        token = UUID(); operation?.cancel(); operation = nil; timeout?.cancel(); timeout = nil
        recognizer.cancel(); state = .idle; applyDraft = nil
    }
    private func complete() {
        let empty = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cancel()
        if empty { error = ChatDictationError.noSpeech.localizedDescription }
    }
    private func fail(_ failure: Error) {
        let permission = failure as? ChatDictationError
        cancel(); needsSettings = permission == .microphonePermission || permission == .speechPermission
        error = failure.localizedDescription
    }
    static func appending(_ transcript: String, to draft: String) -> String {
        guard !transcript.isEmpty else { return draft }
        guard let last = draft.last, let first = transcript.first else { return transcript }
        let cjk: (Character) -> Bool = { $0.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) } }
        let separator = last.isWhitespace || first.isWhitespace || cjk(last) || cjk(first) ? "" : " "
        return draft + separator + transcript
    }
}

#if DEBUG
@MainActor private final class UnavailableDictationFixture: ChatDictationRecognizing {
    func authorize() async throws { throw ChatDictationError.unavailable }
    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws { throw ChatDictationError.unavailable }
    func finish() { }
    func cancel() { }
}
/// Deterministic transcript events for UI checks, never a substitute for physical microphone QA.
@MainActor private final class FixtureChatDictationRecognizer: ChatDictationRecognizing {
    private var update: ((String, Bool) -> Void)?
    private var transcript = ""
    func authorize() async throws { }
    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws {
        self.update = update
        transcript = locale.hasPrefix("zh") || locale.hasPrefix("yue") ? "帮我解释这段文字" : "Explain this passage"
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            update(self.transcript, false)
        }
    }
    func finish() { update?(transcript + (transcript.hasPrefix("帮") ? "。" : "."), true) }
    func cancel() { update = nil }
}
#endif
