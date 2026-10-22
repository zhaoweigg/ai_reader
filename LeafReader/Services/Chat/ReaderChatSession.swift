import Foundation

@MainActor
final class ReaderChatSession: ObservableObject {
    @Published private(set) var messages: [ReaderChatMessage] = []
    @Published var draft = "" { didSet { if !restoring { draftDirty = true; scheduleCheckpoint() } } }
    @Published private(set) var isSending = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var historyError: String?
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var hasNewerMessages = false
    private let history: (any ChatHistoryStorage)?
    private var historyRequired = false
    private var historyReadable = true
    private var oldest: Int64?
    private var newest: Int64?
    private var restoring = false
    private var draftDirty = false
    private var pendingMessageIDs = Set<UUID>()
    private var checkpoint: Task<Void, Never>?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    var canRetry: Bool { !isSending && !hasNewerMessages && messages.last?.isUser == false && messages.last?.state != .complete }
    var canSaveHistory: Bool { history != nil && historyReadable }

    init(history: (any ChatHistoryStorage)? = nil) {
        self.history = history; historyRequired = history != nil
        if let history {
            do { draft = try history.loadDraft(); apply(try history.page(before: nil, after: nil, limit: 24)); restoredNotice() }
            catch { historyReadable = false; historyError = ChatHistoryError.unreadable.localizedDescription }
        }
    }
    convenience init(directory: URL?, conversation: String) {
        do {
            guard let directory else { throw ChatHistoryError.unavailable }
            self.init(history: try ChatHistoryStore(directory: directory, conversation: conversation))
        } catch {
            self.init(); historyRequired = true; historyReadable = false; historyError = ChatHistoryError.unavailable.localizedDescription
        }
    }
    func loadEarlier() { navigate(before: oldest, after: nil) }
    func loadNewer() { navigate(before: nil, after: newest) }
    func loadLatest() { navigate(before: nil, after: nil) }
    private func navigate(before: Int64?, after: Int64?) {
        guard !isSending, flush(), let history else { return }
        do { apply(try history.page(before: before, after: after, limit: 24)); restoredNotice() }
        catch { historyReadable = false; historyError = ChatHistoryError.unreadable.localizedDescription }
    }
    private func apply(_ page: ChatHistoryPage) {
        messages = page.messages; oldest = page.oldest; newest = page.newest
        hasEarlierMessages = page.hasEarlier; hasNewerMessages = page.hasNewer
    }
    private func restoredNotice() {
        notice = canRetry ? "The previous reply did not finish. You can retry it." : nil
    }
    private func setSavedDraft(_ value: String) {
        restoring = true; draft = value; restoring = false; draftDirty = false
    }
    private func save(_ values: [ReaderChatMessage], draft: String? = nil) -> Bool {
        guard historyReadable else { return false }
        guard let history else { return !historyRequired }
        do { try history.save(values, draft: draft); historyError = nil; return true }
        catch { historyError = ChatHistoryError.write.localizedDescription; return false }
    }
    @discardableResult func flush() -> Bool {
        checkpoint?.cancel(); checkpoint = nil
        guard historyReadable, history != nil || !historyRequired else { return false }
        guard !pendingMessageIDs.isEmpty || draftDirty else {
            return historyError == nil || save([], draft: draft)
        }
        guard save(messages.filter { pendingMessageIDs.contains($0.id) }, draft: draftDirty ? draft : nil) else { return false }
        pendingMessageIDs = []; draftDirty = false
        return true
    }
    private func changed(_ message: ReaderChatMessage) {
        guard history != nil else { return }
        pendingMessageIDs.insert(message.id)
        scheduleCheckpoint()
    }
    private func scheduleCheckpoint() {
        guard history != nil, checkpoint == nil else { return }
        // A fixed interval checkpoints long streams; a continuous stream must not
        // postpone every write until completion, as a debounce would.
        checkpoint = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)); self?.flush() } catch { }
        }
    }
    private func refreshLatest() {
        guard let history, pendingMessageIDs.isEmpty else { return }
        do { apply(try history.page(before: nil, after: nil, limit: 24)) }
        catch { historyReadable = false; historyError = ChatHistoryError.unreadable.localizedDescription }
    }

    func send(settings: AISettingsStore, context: @escaping @MainActor () async throws -> ReadingChatContext?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !question.isEmpty else { return }
        guard flush() else { return }
        guard question.count <= 4000 else { error = "Keep your question under 4,000 characters."; return }
        let provider: any ChatProvider
        do { provider = try settings.provider() }
        catch { self.error = error.localizedDescription; return }
        let sharePage = settings.configuration.sharePage
        if hasNewerMessages { loadLatest(); guard historyError == nil else { return } }
        start { [weak self] token in
            guard let self else { return }
            do {
                let snapshot = sharePage ? try await context()?.bounded() : nil
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let message = ReaderChatMessage(isUser: true, text: question, context: snapshot)
                let nextDraft = self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == question ? "" : self.draft
                guard self.save([message], draft: nextDraft) else { self.isSending = false; self.task = nil; return }
                self.messages.append(message)
                self.setSavedDraft(nextDraft)
                if sharePage && (snapshot?.isEmpty ?? true) { self.notice = "No readable page text was found. This question is sent without a passage; you can paste one yourself." }
                await self.respond(provider: provider, token: token, sharePage: sharePage)
            } catch {
                guard self.generation == token else { return }
                self.error = self.errorMessage(error); self.isSending = false
            }
        }
    }

    func retry(settings: AISettingsStore) {
        guard canRetry, flush() else { return }
        do {
            let provider = try settings.provider()
            if let id = messages.last?.id { try history?.remove(id) }
            messages.removeLast() // Retain the original question and passage snapshot.
            start { [weak self] token in await self?.respond(provider: provider, token: token, sharePage: settings.configuration.sharePage) }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        guard isSending else { return }
        generation = UUID(); task?.cancel(); task = nil; isSending = false
        if let last = messages.indices.last, messages[last].state == .streaming { messages[last].state = .stopped; changed(messages[last]) }
        notice = "Response stopped."
        flush(); refreshLatest()
    }
    func close() { stop(); flush() }
    func clear() {
        stop(); checkpoint?.cancel(); checkpoint = nil
        guard history != nil || !historyRequired else { return }
        do {
            try history?.clear()
            pendingMessageIDs = []; setSavedDraft("")
            messages = []; error = nil; notice = nil; historyReadable = true; historyError = nil
            oldest = nil; newest = nil; hasEarlierMessages = false; hasNewerMessages = false
        } catch { historyError = "The saved conversation could not be cleared. Your history has been kept. Try again." }
    }
    deinit { task?.cancel(); checkpoint?.cancel() }

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
        changed(messages.last!)
        guard flush() else {
            messages[messages.count - 1].state = .failed; changed(messages.last!)
            notice = "The reply has not been sent. Retry after saving your conversation."
            isSending = false; task = nil; return
        }
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
                changed(messages[index])
            }
            if !completed { throw ChatError.interrupted }
        } catch {
            guard generation == token else { return }
            if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].state = .failed; changed(messages[index]) }
            self.error = errorMessage(error)
        }
        if generation == token { isSending = false; task = nil; flush(); refreshLatest() }
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
