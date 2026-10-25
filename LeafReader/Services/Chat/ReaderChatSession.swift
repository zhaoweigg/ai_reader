import Foundation

@MainActor
final class ReaderChatSession: ObservableObject {
    @Published private(set) var messages: [ReaderChatMessage] = []
    @Published var draft = "" { didSet { if !restoring { draftDirty = true; scheduleCheckpoint() } } }
    @Published private(set) var selectedContext: ReadingChatContext?
    @Published private(set) var isSending = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var historyError: String?
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var hasNewerMessages = false
    /// What the book search agent is doing, shown in place of “Thinking…”.
    @Published private(set) var activity: String?
    private let history: (any ChatHistoryStorage)?
    private var recall: (@MainActor (String, ReadingChatContext) async throws -> ReadingBookRecall?)?
    private var agentBook: (@MainActor (ReadingChatContext) async throws -> ReadingAgentBook?)?
    private var historyRequired = false
    private var historyReadable = true
    private var oldest: Int64?
    private var newest: Int64?
    private var restoring = false
    private var draftDirty = false
    private var selectionDirty = false
    private var pendingMessageIDs = Set<UUID>()
    private var checkpoint: Task<Void, Never>?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    var canRetry: Bool { !isSending && !hasNewerMessages && messages.last?.isUser == false && messages.last?.state != .complete }
    var canSaveHistory: Bool { history != nil && historyReadable }

    init(history: (any ChatHistoryStorage)? = nil) {
        self.history = history; historyRequired = history != nil
        if let history {
            do { draft = try history.loadDraft(); selectedContext = try history.loadSelectedContext(); apply(try history.page(before: nil, after: nil, limit: 24)); restoredNotice() }
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
    private func save(_ values: [ReaderChatMessage], draft: String? = nil, selection: ChatDraftSelectionUpdate = .unchanged) -> Bool {
        guard historyReadable else { return false }
        guard let history else { return !historyRequired }
        do { try history.save(values, draft: draft, selection: selection); historyError = nil; return true }
        catch { historyError = ChatHistoryError.write.localizedDescription; return false }
    }
    @discardableResult func flush() -> Bool {
        checkpoint?.cancel(); checkpoint = nil
        guard historyReadable, history != nil || !historyRequired else { return false }
        guard !pendingMessageIDs.isEmpty || draftDirty || selectionDirty else {
            return historyError == nil || save([], draft: draft)
        }
        guard save(messages.filter { pendingMessageIDs.contains($0.id) }, draft: draftDirty ? draft : nil, selection: selectionDirty ? .set(selectedContext) : .unchanged) else { return false }
        pendingMessageIDs = []; draftDirty = false; selectionDirty = false
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

    func attachSelection(_ context: ReadingChatContext, prompt: String = "") {
        guard !context.isEmpty else { return }
        selectedContext = context.bounded(); selectionDirty = true
        if !prompt.isEmpty { draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? prompt : draft + "\n\n" + prompt }
        flush()
    }
    func attachLiveSelection(_ context: ReadingChatContext?, chatIsPresented: Bool) {
        guard chatIsPresented, let context, !context.isEmpty else { return }
        let bounded = context.bounded()
        guard selectedContext != bounded else { return }
        selectedContext = bounded; selectionDirty = true
        // Selection handles can send many updates. Show the quote immediately,
        // but checkpoint the final snapshot without writing on every handle move.
        scheduleCheckpoint()
    }
    func removeSelection() { selectedContext = nil; selectionDirty = true; flush() }

    func prepareSelectionPrompt(_ intent: ReaderSelectionIntent) {
        guard let selection = selectedContext, intent != .ask else { return }
        let prompt = intent.prompt(for: selection.text)
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = [ReaderSelectionIntent.explain, .summarize].map { $0.prompt(for: selection.text) }
        if current.isEmpty || presets.contains(current) { draft = prompt }
        else if let previous = presets.first(where: { current.hasSuffix("\n\n" + $0) }) {
            draft = String(current.dropLast(previous.count)) + prompt
        }
        else if !current.hasSuffix(prompt) { draft += "\n\n" + prompt }
        flush()
    }

    func send(settings: AISettingsStore, missingContextNotice: String? = "No readable page text was found. This question is sent without a passage; you can paste one yourself.", recall: (@MainActor (String, ReadingChatContext) async throws -> ReadingBookRecall?)? = nil, agentBook: (@MainActor (ReadingChatContext) async throws -> ReadingAgentBook?)? = nil, context: @escaping @MainActor () async throws -> ReadingChatContext?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !question.isEmpty else { return }
        guard flush() else { return }
        guard question.count <= 4000 else { error = "Keep your question under 4,000 characters."; return }
        let provider: any ChatProvider
        do { provider = try settings.provider() }
        catch { self.error = error.localizedDescription; return }
        let sharePage = settings.configuration.sharePage
        let harness = settings.configuration.harness
        // Retries reuse the book access of the reader that sent the question.
        self.recall = recall; self.agentBook = agentBook
        let selected = selectedContext
        if hasNewerMessages { loadLatest(); guard historyError == nil else { return } }
        start { [weak self] token in
            guard let self else { return }
            do {
                var snapshot: ReadingChatContext?
                if sharePage {
                    if let selected { snapshot = selected }
                    else { snapshot = try await context()?.bounded() }
                    // The agent searches during its reply; pre-fetching is the other harness.
                    if harness == .evidence, var passage = snapshot, let recall,
                       let term = ReadingBookRecall.lookupTerm(question: question, context: passage, previous: Self.previousSubject(self.messages)) {
                        do { passage.bookRecall = try await recall(term, passage) }
                        catch {
                            try Task.checkCancellation()
                            passage.bookRecall = ReadingBookRecall(term: term, excerpts: [], scannedSections: 0, totalSections: 0, complete: false)
                            self.notice = "Book lookup was incomplete; this reply uses the passages available."
                        }
                        snapshot = passage.bounded()
                    }
                }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let message = ReaderChatMessage(isUser: true, text: question, context: snapshot)
                let nextDraft = self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == question ? "" : self.draft
                let nextSelection = self.selectedContext == selected ? nil : self.selectedContext
                guard self.save([message], draft: nextDraft, selection: .set(nextSelection)) else { self.isSending = false; self.task = nil; return }
                self.messages.append(message)
                self.setSavedDraft(nextDraft)
                self.selectedContext = nextSelection; self.selectionDirty = false
                if !sharePage && selected != nil { self.notice = "Selected text was not sent because passage sharing is off." }
                if sharePage && (snapshot?.isEmpty ?? true) { self.notice = missingContextNotice }
                await self.respond(provider: provider, token: token, sharePage: sharePage, harness: harness)
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
            let configuration = settings.configuration
            start { [weak self] token in await self?.respond(provider: provider, token: token, sharePage: configuration.sharePage, harness: configuration.harness) }
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
            pendingMessageIDs = []; setSavedDraft(""); selectedContext = nil; selectionDirty = false
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
    private func respond(provider: any ChatProvider, token: UUID, sharePage: Bool, harness: ReadingChatHarness) async {
        var history = messages
        var earlier: [ReaderChatMessage] = []
        // The agent searches older discussion with a tool instead.
        if harness == .evidence || !sharePage, let storage = self.history, let oldest, hasEarlierMessages {
            do { earlier = try storage.page(before: oldest, after: nil, limit: 48).messages }
            catch { notice = "Earlier discussion could not be loaded; this reply uses recent messages." }
        }
        if !sharePage {
            for index in history.indices { history[index].context = nil }
            for index in earlier.indices { earlier[index].context = nil }
        }
        let id = UUID()
        messages.append(ReaderChatMessage(id: id, isUser: false, text: "", state: .streaming))
        changed(messages.last!)
        guard flush() else {
            messages[messages.count - 1].state = .failed; changed(messages.last!)
            notice = "The reply has not been sent. Retry after saving your conversation."
            isSending = false; task = nil; return
        }
        var trace = ChatTrace(harness: harness)
        do {
            let truncated: Bool
            if harness == .agent, sharePage {
                // Book text leaves the device only through tool results, which passage sharing governs.
                var book: ReadingAgentBook?
                if let context = history.last(where: \.isUser)?.context, let agentBook { book = try? await agentBook(context) }
                try Task.checkCancellation()
                if let tools = provider as? any ToolChatProvider, let book {
                    let toolbox = ReadingAgentToolbox(book: book) { [weak self] terms in self?.conversationMatches(terms) ?? "{\"matches\":[]}" }
                    toolbox.activity = { [weak self] text in if self?.generation == token { self?.activity = text } }
                    do {
                        let request = ChatRequest.conversation(history, harness: .agent)
                        // A highlighted name is searched before the model answers, so a
                        // “who is this” reply always starts from the book, not the chat.
                        let question = history.last(where: \.isUser)
                        let selection = question?.context?.source == "selection" ? question?.context?.text : nil
                        let followUp = question.flatMap { asked in asked.context.flatMap { context in
                            ReadingBookRecall.lookupTerm(question: asked.text, context: context, previous: Self.previousSubject(history.filter { $0.id != asked.id }))
                        } }
                        let seed = try await toolbox.seed(selection, followUp: followUp)
                        let outcome = try await ReadingAgentRunner.run(provider: tools, request: request, toolbox: toolbox, seed: seed, onText: { [weak self] text in
                            self?.append(text, to: id, token: token)
                        }, onWithdraw: { [weak self] in self?.withdraw(id, token: token) })
                        trace.steps = toolbox.steps; truncated = outcome.truncated
                    } catch ReadingAgentError.toolsUnsupported {
                        trace.steps = []; trace.fellBack = true
                        truncated = try await streamEvidence(provider: provider, history: history, earlier: earlier, id: id, token: token, trace: &trace)
                    }
                } else {
                    // A provider without tool support, or a book without readable text.
                    trace.fellBack = !(provider is any ToolChatProvider)
                    if !trace.fellBack { trace.steps = [agentBook == nil ? "no book open" : "book text unavailable"] }
                    truncated = try await streamEvidence(provider: provider, history: history, earlier: earlier, id: id, token: token, trace: &trace)
                }
            } else {
                if !sharePage { trace.steps = ["passage sharing off"] }
                else if let recall = history.last(where: \.isUser)?.context?.bookRecall {
                    trace.steps = ["looked up “\(recall.term)” (\(recall.excerpts.count))"]
                }
                truncated = try await stream(ChatRequest.conversation(history, earlierMessages: earlier), provider: provider, into: id, token: token)
            }
            guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index].trace = trace
            if truncated {
                messages[index].state = .stopped
                notice = "The reply ended before completion. Retry or ask for a shorter answer."
            } else { messages[index].state = .complete }
            changed(messages[index])
        } catch {
            guard generation == token else { return }
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].state = .failed; messages[index].trace = trace; changed(messages[index])
            }
            self.error = errorMessage(error)
        }
        if generation == token { activity = nil; isSending = false; task = nil; flush(); refreshLatest() }
    }
    /// Streams a plain request into a reply; returns whether it was truncated.
    private func stream(_ request: ChatRequest, provider: any ChatProvider, into id: UUID, token: UUID) async throws -> Bool {
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            switch event {
            case .text(let text): append(text, to: id, token: token)
            case .finished(let truncated): return truncated
            }
        }
        throw ChatError.interrupted
    }
    /// The subject of the reader's last lookup or name selection, for follow-up questions.
    static func previousSubject(_ messages: [ReaderChatMessage]) -> String? {
        guard let context = messages.last(where: \.isUser)?.context else { return nil }
        if let term = context.bookRecall?.term, !term.isEmpty { return term }
        return context.source == "selection" ? ReadingAgentToolbox.nameLike(context.text) : nil
    }
    /// The pre-fetched evidence harness, also the agent's fallback.
    private func streamEvidence(provider: any ChatProvider, history: [ReaderChatMessage], earlier: [ReaderChatMessage], id: UUID, token: UUID, trace: inout ChatTrace) async throws -> Bool {
        var history = history
        if let index = history.lastIndex(where: \.isUser), var context = history[index].context, context.bookRecall == nil, let recall,
           let term = ReadingBookRecall.lookupTerm(question: history[index].text, context: context, previous: Self.previousSubject(Array(history[..<index]))) {
            activity = "Looking up “\(term)”…"
            context.bookRecall = try? await recall(term, context)
            history[index].context = context.bounded()
            if let found = context.bookRecall { trace.steps = ["looked up “\(found.term)” (\(found.excerpts.count))"] }
        }
        activity = nil
        try Task.checkCancellation()
        return try await stream(ChatRequest.conversation(history, earlierMessages: earlier), provider: provider, into: id, token: token)
    }
    private func append(_ text: String, to id: UUID, token: UUID) {
        guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        activity = nil
        messages[index].text += text; changed(messages[index])
    }
    private func withdraw(_ id: UUID, token: UUID) {
        guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = ""; changed(messages[index])
    }
    /// Earlier exchanges in this book's conversation that mention any term, for the agent.
    private func conversationMatches(_ terms: [String]) -> String {
        let all = ((try? history?.page(before: nil, after: nil, limit: 200).messages) ?? nil) ?? messages
        let needles = terms.map { $0.lowercased() }
        var matches: [[String: String]] = []
        for (index, message) in all.enumerated() where message.isUser && message.state == .complete {
            let answer = all.indices.contains(index + 1) && !all[index + 1].isUser ? all[index + 1].text : ""
            let haystack = (message.text + " " + answer).lowercased()
            guard needles.contains(where: { haystack.contains($0) }) else { continue }
            var match = ["reader_question": String(message.text.prefix(400)), "assistant_answer": String(answer.prefix(900))]
            if let chapter = message.context?.chapter, !chapter.isEmpty { match["chapter"] = String(chapter.prefix(200)) }
            matches.append(match)
        }
        return ReadingAgentToolbox.json(["matches": Array(matches.suffix(4)), "note": "Earlier answers may be wrong; prefer book text."])
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
                    if UITesting.flag("LEAF_UI_CHAT_MARKDOWN") {
                        continuation.yield(.text("## 人物\n\n这是**李"))
                        try await Task.sleep(for: .milliseconds(250))
                        continuation.yield(.text("香玲**，云瑶的队友。\n\n- 第一条\n- 第二条\n\n```swift\nlet value = 1\n```\n\n尾句。"))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag("LEAF_UI_CHAT_CONTEXT_PROBE") {
                        let content = request.turns.last?.content ?? ""
                        let body = content.components(separatedBy: "reading_context (source material):\n").last?.components(separatedBy: "\n\nReader question:\n").first ?? ""
                        let context = body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        let valid = context["source"] as? String == "selection" && !(context["text"] as? String ?? "").isEmpty &&
                            (!(context["preceding_text"] as? String ?? "").isEmpty || !(context["following_text"] as? String ?? "").isEmpty) &&
                            context["approximate_book_progress_percent"] != nil && context["spoiler_boundary"] != nil &&
                            !content.contains("epubcfi(") && request.system.contains("Treat previous assistant answers as fallible")
                        continuation.yield(.text(valid ? "Reading context verified: focused quote, nearby passage, reading progress and spoiler boundary." : "Reading context verification failed: \(body)"))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
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

// Scripted agent: searches the words after “about” in the question, then
// answers from the real on-device tool result.
extension UITestChatProvider: ToolChatProvider {
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    let results = items.compactMap { item -> [AgentToolResult]? in if case .toolResults(let value) = item { return value }; return nil }.last
                    guard let output = results?.first?.output else {
                        let question = items.compactMap { item -> String? in if case .turn(let turn) = item, turn.role == "user" { return turn.content }; return nil }.last ?? ""
                        let asked = question.components(separatedBy: "Reader question:\n").last ?? question
                        let term = asked.components(separatedBy: "about ").dropFirst().first?
                            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) ?? asked
                        let arguments = ReadingAgentToolbox.json(["terms": [String(term.prefix(40))]])
                        continuation.yield(.text("Let me look."))
                        continuation.yield(.toolCall(AgentToolCall(id: "call_1", name: "search_book", arguments: arguments)))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
                    let hits = object["results"] as? [[String: Any]] ?? []
                    let chapter = hits.first?["chapter"] as? String ?? "no chapter"
                    continuation.yield(.text("Agent reply: found \(hits.count) passages; earliest in \(chapter)."))
                    continuation.yield(.finished(truncated: false)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
