import Foundation

#if DEBUG
@MainActor final class UnavailableDictationFixture: ChatDictationRecognizing {
    func authorize() async throws { throw ChatDictationError.unavailable }
    func start(locale: String, update: @escaping (String, Bool) -> Void, failure: @escaping (Error) -> Void) throws { throw ChatDictationError.unavailable }
    func finish() { }
    func cancel() { }
}
/// Deterministic transcript events for UI checks, never a substitute for physical microphone QA.
@MainActor final class FixtureChatDictationRecognizer: ChatDictationRecognizing {
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
