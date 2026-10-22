import Foundation

@MainActor
final class ReaderChatSession: ObservableObject {
    @Published private(set) var messages: [ReaderChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    var canRetry: Bool { !isSending && messages.last?.isUser == false && messages.last?.state != .complete }

    func send(settings: AISettingsStore, context: @escaping @MainActor () async throws -> ReadingChatContext?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !question.isEmpty else { return }
        guard question.count <= 4000 else { error = "Keep your question under 4,000 characters."; return }
        let provider: any ChatProvider
        do { provider = try settings.provider() }
        catch { self.error = error.localizedDescription; return }
        let sharePage = settings.configuration.sharePage
        start { [weak self] token in
            guard let self else { return }
            do {
                let snapshot = sharePage ? try await context()?.bounded() : nil
                try Task.checkCancellation()
                guard self.generation == token else { return }
                self.messages.append(ReaderChatMessage(isUser: true, text: question, context: snapshot))
                if self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == question { self.draft = "" }
                if sharePage && (snapshot?.isEmpty ?? true) { self.notice = "No readable page text was found. This question is sent without a passage; you can paste one yourself." }
                await self.respond(provider: provider, token: token, sharePage: sharePage)
            } catch {
                guard self.generation == token else { return }
                self.error = self.errorMessage(error); self.isSending = false
            }
        }
    }

    func retry(settings: AISettingsStore) {
        guard canRetry else { return }
        do {
            let provider = try settings.provider()
            messages.removeLast() // Retain the original question and passage snapshot.
            start { [weak self] token in await self?.respond(provider: provider, token: token, sharePage: settings.configuration.sharePage) }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        guard isSending else { return }
        generation = UUID(); task?.cancel(); task = nil; isSending = false
        if let last = messages.indices.last, messages[last].state == .streaming { messages[last].state = .stopped }
        notice = "Response stopped."
    }
    func clear() { stop(); messages = []; error = nil; notice = nil }
    deinit { task?.cancel() }

    private func start(_ operation: @escaping @MainActor (UUID) async -> Void) {
        error = nil; notice = nil; isSending = true
        let token = UUID(); generation = token
        task = Task { await operation(token) }
    }
    private func respond(provider: any ChatProvider, token: UUID, sharePage: Bool) async {
        var history = messages
        if !sharePage { for index in history.indices { history[index].context = nil } }
        let request = ChatRequest.conversation(history)
        let id = UUID()
        messages.append(ReaderChatMessage(id: id, isUser: false, text: "", state: .streaming))
        do {
            var completed = false
            for try await event in provider.stream(request) {
                try Task.checkCancellation()
                guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
                switch event {
                case .text(let text): messages[index].text += text
                case .finished(let truncated):
                    completed = true
                    if truncated {
                        messages[index].state = .stopped
                        notice = "The reply ended before completion. Retry or ask for a shorter answer."
                    } else { messages[index].state = .complete }
                }
            }
            if !completed { throw ChatError.interrupted }
        } catch {
            guard generation == token else { return }
            if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].state = .failed }
            self.error = errorMessage(error)
        }
        if generation == token { isSending = false; task = nil }
    }
    private func errorMessage(_ error: Error) -> String {
        if let error = error as? ChatError { return error.localizedDescription }
        if let error = error as? ChatGPTError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "The connection was lost. Check your internet connection and retry."
            case .timedOut: return "The provider took too long to respond. Try again."
            case .cancelled: return "Response stopped."
            default: return "Could not connect to the provider. Check the endpoint and your connection."
            }
        }
        return "Could not prepare the reading passage. Try again."
    }
}

#if DEBUG
// Explicit UI-test injection only; shipping builds never substitute sample replies.
struct UITestChatProvider: ChatProvider {
    var slow = false
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.text("Test reply: "))
                    try await Task.sleep(for: .milliseconds(slow ? 30000 : 150))
                    continuation.yield(.text("Consider what the passage states and what the character assumes."))
                    continuation.yield(.finished(truncated: false)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
