import AVFoundation
import Speech
import Combine

enum DictationLanguage: String, CaseIterable, Identifiable {
    case system, mandarin, traditionalChinese, cantonese, english
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Device language"
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
        // Synchronous: pause Leaf's read-aloud before taking the audio session.
        NotificationCenter.default.post(name: ChatDictationSession.willRecord, object: nil)
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true)
            ownsAudioSession = true
            let engine = AVAudioEngine(), request = SFSpeechAudioBufferRecognitionRequest()
            self.engine = engine; self.request = request; self.recognizer = recognizer
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            let input = engine.inputNode, format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ChatDictationError.noMicrophone }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            hasTap = true
            task = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false
                Task { @MainActor in
                    if let text { update(text, final) }
                    if let error, !final { failure(error) }
                }
            }
            engine.prepare()
            try engine.start()
        } catch { cancel(); throw error }
    }

    func finish() {
        stopCapture()
        request?.endAudio()
    }
    func cancel() {
        stopCapture()
        request?.endAudio(); task?.cancel()
        task = nil; request = nil; recognizer = nil
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
        if UITesting.flag("LEAF_UI_DICTATION_MOCK") { return FixtureChatDictationRecognizer() }
        #endif
        return AppleChatDictationRecognizer()
    }

    func start(draft: String, language: DictationLanguage, apply: @escaping (String) -> Void) {
        guard !isActive else { return }
        error = nil; needsSettings = false; baseDraft = draft; transcript = ""; applyDraft = apply
        let generation = UUID(); token = generation; state = .authorizing
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await recognizer.authorize()
                guard token == generation, !Task.isCancelled else { return }
                try recognizer.start(locale: language.locale, update: { [weak self] text, final in
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
/// Deterministic transcript events for UI checks, never a substitute for physical microphone QA.
@MainActor private final class FixtureChatDictationRecognizer: ChatDictationRecognizing {
    private var update: ((String, Bool) -> Void)?
    func authorize() async throws { }
    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws {
        self.update = update
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.update?("帮我解释这段文字", false)
        }
    }
    func finish() { update?("帮我解释这段文字。", true) }
    func cancel() { update = nil }
}
#endif
