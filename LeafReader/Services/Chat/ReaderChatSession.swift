import Foundation
import UIKit

@MainActor
final class ReaderChatSession: ObservableObject {
    @Published private(set) var messages: [ReaderChatMessage] = []
    @Published var draft = "" { didSet { if !restoring { draftDirty = true; scheduleCheckpoint() } } }
    @Published private(set) var selectedContext: ReadingChatContext?
    @Published private(set) var isSending = false { didSet { if isSending != oldValue { isSending ? holdInBackground() : releaseBackground() } } }
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var historyError: String?
    @Published private(set) var hasEarlierMessages = false
    @Published private(set) var hasNewerMessages = false
    /// What the book search agent is doing, shown in place of “Thinking…”.
    @Published private(set) var activity: String?
    private let history: (any ChatHistoryStorage)?
    /// Where generated pictures are kept: beside the chat database, or a
    /// temporary folder for a conversation that is not saved.
    let imageDirectory: URL
    /// Why this reply's request went out without the image tool, if it did.
    private var imageRefusal: String?
    private var recall: (@MainActor (String, ReadingChatContext) async throws -> ReadingBookRecall?)?
    private var agentBook: (@MainActor (ReadingChatContext) async throws -> ReadingAgentBook?)?
    /// The app screen this chat was opened from, which the agent reads with view tools.
    private var screen: ChatScreen?
    private var traceStore: AgentTraceStore?
    private var traceSource = (provider: "", model: "")
    private var agentLimits = AgentLimits()
    private var contextLimits = ReadingContextLimits()
    var retryPolicy = ChatRetryPolicy()
    private var activeRecorder: AgentTraceRecorder?
    private var recordTraces = false
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
    /// iOS suspends Leaf seconds after it leaves the screen and cuts its connections. A reply keeps
    /// running for the short extra time iOS grants, and one cut off there continues on return.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundedDuringReply = false
    private var resumeOnForeground = false
    private weak var replySettings: AISettingsStore?
    var appInBackground: () -> Bool = { UIApplication.shared.applicationState == .background }
    static let resumedNotice = "Leaf left the screen during this reply, so it was asked again."
    var canSaveHistory: Bool { history != nil && historyReadable }

    init(history: (any ChatHistoryStorage)? = nil, imageDirectory: URL? = nil) {
        self.history = history; historyRequired = history != nil
        self.imageDirectory = imageDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("LeafChatImages", isDirectory: true)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillEnterForeground() }
            }
        ]
        if let history {
            do { draft = try history.loadDraft(); selectedContext = try history.loadSelectedContext(); apply(try history.page(before: nil, after: nil, limit: 24)); restoredNotice() }
            catch { historyReadable = false; historyError = ChatHistoryError.unreadable.localizedDescription }
        }
    }
    convenience init(directory: URL?, conversation: String) {
        do {
            guard let directory else { throw ChatHistoryError.unavailable }
            self.init(history: try ChatHistoryStore(directory: directory, conversation: conversation),
                      imageDirectory: directory.appendingPathComponent("Images", isDirectory: true))
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

    func send(settings: AISettingsStore, missingContextNotice: String? = "No readable page text was found. This question is sent without a passage; you can paste one yourself.", recall: (@MainActor (String, ReadingChatContext) async throws -> ReadingBookRecall?)? = nil, agentBook: (@MainActor (ReadingChatContext) async throws -> ReadingAgentBook?)? = nil, screen: ChatScreen? = nil, traces: AgentTraceStore? = nil, context: @escaping @MainActor () async throws -> ReadingChatContext?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !question.isEmpty else { return }
        guard flush() else { return }
        guard question.count <= 4000 else { error = "Keep your question under 4,000 characters."; return }
        let provider: any ChatProvider
        do { provider = try settings.provider() }
        catch { self.error = error.localizedDescription; return }
        let sharePage = settings.configuration.sharePage
        let harness = settings.configuration.harness
        replySettings = settings
        // Retries reuse the book access of the reader that sent the question.
        self.recall = recall; self.agentBook = agentBook; self.screen = screen; traceStore = traces
        adopt(settings.configuration)
        let selected = selectedContext
        if hasNewerMessages { loadLatest(); guard historyError == nil else { return } }
        start { [weak self] token in
            guard let self else { return }
            // The question and a reply placeholder show at once. Reading the page and
            // looking through the book can take seconds; they attach to the question
            // before the request leaves, and the placeholder names what is happening.
            let message = ReaderChatMessage(isUser: true, text: question)
            let nextDraft = self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == question ? "" : self.draft
            let priorDraft = self.draft
            self.messages.append(message)
            let replyID = self.appendReply()
            self.pendingQuestion = (message.id, replyID, priorDraft)
            self.setSavedDraft(nextDraft)
            do {
                var snapshot: ReadingChatContext?
                if sharePage {
                    if let selected { snapshot = selected }
                    else { self.activity = "Reading the page…"; snapshot = try await context()?.bounded() }
                    // The agent searches during its reply; pre-fetching is the other harness.
                    if harness == .evidence, var passage = snapshot, let recall,
                       let term = ReadingBookRecall.lookupTerm(question: question, context: passage,
                                                               previous: Self.previousSubject(self.messages.filter { $0.id != message.id && $0.id != replyID })) {
                        self.activity = "Looking up “\(term)”…"
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
                guard self.generation == token, let index = self.messages.firstIndex(where: { $0.id == message.id }) else { return }
                self.activity = nil
                self.messages[index].context = snapshot
                let nextSelection = self.selectedContext == selected ? nil : self.selectedContext
                guard self.save([self.messages[index]], draft: nextDraft, selection: .set(nextSelection)) else {
                    self.withdrawPending(); self.isSending = false; self.task = nil; return
                }
                self.pendingQuestion = nil
                self.selectedContext = nextSelection; self.selectionDirty = false
                if !sharePage && selected != nil { self.notice = "Selected text was not sent because passage sharing is off." }
                if sharePage && (snapshot?.isEmpty ?? true) { self.notice = missingContextNotice }
                await self.respond(provider: provider, token: token, sharePage: sharePage, harness: harness, replyID: replyID)
            } catch {
                guard self.generation == token else { return }
                self.withdrawPending()
                self.error = self.errorMessage(error); self.isSending = false
            }
        }
    }
    /// A question whose passage is still being gathered: nothing has left the device.
    private var pendingQuestion: (question: UUID, reply: UUID, draft: String)?
    private func appendReply() -> UUID {
        let id = UUID()
        messages.append(ReaderChatMessage(id: id, isUser: false, text: "", state: .streaming))
        return id
    }
    /// Drops an unsent question and its placeholder and gives the draft back.
    private func withdrawPending() {
        guard let pending = pendingQuestion else { return }
        pendingQuestion = nil; activity = nil
        messages.removeAll { $0.id == pending.question || $0.id == pending.reply }
        setSavedDraft(pending.draft)
    }

    func retry(settings: AISettingsStore) {
        guard canRetry, flush() else { return }
        do {
            let provider = try settings.provider()
            replySettings = settings
            if let id = messages.last?.id { try history?.remove(id) }
            messages.removeLast() // Retain the original question and passage snapshot.
            let configuration = settings.configuration
            adopt(configuration)
            start { [weak self] token in await self?.respond(provider: provider, token: token, sharePage: configuration.sharePage, harness: configuration.harness) }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        guard isSending else { return }
        generation = UUID(); task?.cancel(); task = nil; isSending = false
        if let recorder = activeRecorder {
            recorder.failed("Response stopped.", outcome: .stopped)
            traceStore?.add(recorder.finish(outcome: .stopped)); activeRecorder = nil
        }
        if pendingQuestion != nil { withdrawPending(); flush(); return }
        if let last = messages.indices.last, messages[last].state == .streaming { messages[last].state = .stopped; changed(messages[last]) }
        notice = "Response stopped."
        flush(); refreshLatest()
    }
    func close() { resumeOnForeground = false; stop(); flush() }

    func appDidEnterBackground() {
        if isSending { backgroundedDuringReply = true }
    }
    func appWillEnterForeground() {
        guard resumeOnForeground else { return }
        resumeOnForeground = false
        resumeInterruptedReply()
    }
    private func holdInBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Ask Leaf reply") { [weak self] in
            MainActor.assumeIsolated { self?.releaseBackground() }
        }
    }
    private func releaseBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    /// Asks the interrupted question again, as Retry does, once Leaf is back on screen.
    private func resumeInterruptedReply() {
        guard let settings = replySettings, canRetry, error == nil else { return }
        retry(settings: settings)
        if isSending { notice = Self.resumedNotice }
    }
    func clear() {
        stop(); checkpoint?.cancel(); checkpoint = nil
        guard history != nil || !historyRequired else { return }
        do {
            // Every saved reply in this conversation, not just the loaded page.
            var pictures = messages.flatMap { $0.images ?? [] }
            var cursor: Int64?
            while let history, let page = try? history.page(before: cursor, after: nil, limit: 48) {
                pictures += page.messages.flatMap { $0.images ?? [] }
                guard page.hasEarlier, let oldest = page.oldest, oldest != cursor else { break }
                cursor = oldest
            }
            try history?.clear()
            ChatImageStore.remove(pictures, in: imageDirectory)
            pendingMessageIDs = []; setSavedDraft(""); selectedContext = nil; selectionDirty = false
            messages = []; error = nil; notice = nil; historyReadable = true; historyError = nil
            oldest = nil; newest = nil; hasEarlierMessages = false; hasNewerMessages = false
        } catch { historyError = "The saved conversation could not be cleared. Your history has been kept. Try again." }
    }
    deinit {
        task?.cancel(); checkpoint?.cancel()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if backgroundTask != .invalid { let task = backgroundTask; Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
    }

    private func start(_ operation: @escaping @MainActor (UUID) async -> Void) {
        error = nil; notice = nil; backgroundedDuringReply = appInBackground(); resumeOnForeground = false; isSending = true
        let token = UUID(); generation = token
        task = Task { await operation(token) }
    }
    private func respond(provider: any ChatProvider, token: UUID, sharePage: Bool, harness: ReadingChatHarness, replyID: UUID? = nil) async {
        let id = replyID ?? UUID()
        var history = messages.filter { $0.id != id }
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
        if replyID == nil { messages.append(ReaderChatMessage(id: id, isUser: false, text: "", state: .streaming)) }
        changed(messages.last!)
        guard flush() else {
            messages[messages.count - 1].state = .failed; changed(messages.last!)
            notice = "The reply has not been sent. Retry after saving your conversation."
            isSending = false; task = nil; return
        }
        var trace = ChatTrace(harness: harness)
        imageRefusal = nil
        let asked = history.last(where: \.isUser)
        let recorder: AgentTraceRecorder? = recordTraces && traceStore != nil ? AgentTraceRecorder(trace: AgentTrace(
            harness: harness, provider: traceSource.provider, model: traceSource.model, bookTitle: asked?.context?.title ?? "",
            chapter: asked?.context?.chapter ?? "", question: asked?.text ?? "",
            selection: asked?.context?.source == "selection" ? asked?.context?.text : nil, limits: harness == .agent && (sharePage || screen != nil) ? agentLimits : nil)) : nil
        activeRecorder = recorder
        let recovery = ChatRetryBudget(policy: retryPolicy)
        do {
            let truncated: Bool
            if harness == .agent, sharePage || screen != nil {
                // Book text leaves the device only through tool results, which passage sharing governs.
                // A screen's catalog listing is not book text; its passages and notes follow the same switch.
                var book: ReadingAgentBook?
                if sharePage, let context = history.last(where: \.isUser)?.context, let agentBook { book = try? await agentBook(context) }
                try Task.checkCancellation()
                if let tools = provider as? any ToolChatProvider, book != nil || screen != nil {
                    let toolbox = ReadingAgentToolbox(book: book, screen: book == nil ? screen : nil) { [weak self] terms in self?.conversationMatches(terms) ?? "{\"matches\":[]}" }
                    toolbox.limits = agentLimits; toolbox.sharePassages = sharePage
                    toolbox.activity = { [weak self] text in if self?.generation == token { self?.activity = text } }
                    do {
                        let request = ChatRequest.conversation(history, harness: .agent, screen: book == nil ? screen?.name : nil, limits: contextLimits)
                        let detail = book.map { Self.traceDetail(asked?.context?.bounded(contextLimits), boundary: $0.boundary, limits: agentLimits) }
                            ?? "\(screen?.name ?? "") screen · limits \(agentLimits.maxToolCalls) calls / \(agentLimits.maxRounds) rounds"
                        recorder?.context(system: request.system, turns: request.turns, detail: detail)
                        // A highlighted name is searched before the model answers, so a
                        // “who is this” reply always starts from the book, not the chat.
                        let question = history.last(where: \.isUser)
                        let selection = question?.context?.source == "selection" ? question?.context?.text : nil
                        let followUp = question.flatMap { asked in asked.context.flatMap { context in
                            ReadingBookRecall.lookupTerm(question: asked.text, context: context, previous: Self.previousSubject(history.filter { $0.id != asked.id }))
                        } }
                        let seed = try await toolbox.seed(selection, followUp: followUp, recorder: recorder)
                        let outcome = try await ReadingAgentRunner.run(provider: tools, request: request, toolbox: toolbox, seed: seed,
                                                                       limits: agentLimits, recorder: recorder, recovery: recovery, onRetry: { [weak self] in
                            self?.recover(id, token: token, retry: recovery.retries)
                        }, onText: { [weak self] text in
                            self?.append(text, to: id, token: token)
                        }, onWithdraw: { [weak self] in self?.withdraw(id, token: token) },
                        onImageStarted: { [weak self] in self?.drawing(id, token: token) },
                        onImage: { [weak self] data in try? self?.attachImage(data, to: id, token: token) },
                        onImageRefused: { [weak self] reason in self?.imageToolRefused(reason, token: token) })
                        trace.steps = toolbox.steps; truncated = outcome.truncated
                    } catch ReadingAgentError.toolsUnsupported {
                        trace.steps = []; trace.fellBack = true
                        truncated = try await streamEvidence(provider: provider, history: history, earlier: earlier, id: id, token: token, trace: &trace, recorder: recorder, recovery: recovery, sharePage: sharePage)
                    }
                } else {
                    // A provider without tool support, or a book without readable text.
                    trace.fellBack = !(provider is any ToolChatProvider)
                    if !trace.fellBack { trace.steps = [agentBook == nil ? "no book open" : "book text unavailable"] }
                    truncated = try await streamEvidence(provider: provider, history: history, earlier: earlier, id: id, token: token, trace: &trace, recorder: recorder, recovery: recovery, sharePage: sharePage)
                }
            } else if screen != nil {
                // Without tools the screen's list travels with the question instead.
                truncated = try await streamEvidence(provider: provider, history: history, earlier: earlier, id: id, token: token, trace: &trace, recorder: recorder, recovery: recovery, sharePage: sharePage)
            } else {
                if !sharePage { trace.steps = ["passage sharing off"] }
                else if let recall = history.last(where: \.isUser)?.context?.bookRecall {
                    trace.steps = ["looked up “\(recall.term)” (\(recall.excerpts.count))"]
                    recorder?.lookup(recall)
                }
                truncated = try await stream(ChatRequest.conversation(history, earlierMessages: earlier, limits: contextLimits), provider: provider, into: id, token: token,
                                             recorder: recorder, recovery: recovery, detail: Self.traceDetail(asked?.context?.bounded(contextLimits), boundary: nil, limits: nil))
            }
            guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
            messages[index].trace = trace
            if let recorder { traceStore?.add(recorder.finish(outcome: truncated ? .truncated : .complete)) }
            if truncated {
                messages[index].state = .stopped
                notice = "The reply ended before completion. Retry or ask for a shorter answer."
            } else { messages[index].state = .complete }
            // A picture was asked for but the image tool was refused: say so, rather
            // than leave the model's “I can't draw” as the only explanation.
            if !truncated, let refusal = imageRefusal, !messages[index].hasImages, let asked, Self.asksForPicture(asked.text) {
                notice = "This model or ChatGPT plan didn’t accept drawing (\(refusal)), so Leaf answered in words."
            }
            changed(messages[index])
        } catch {
            guard generation == token else { return }
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].state = .failed; messages[index].trace = trace; changed(messages[index])
            }
            if backgroundedDuringReply, ChatRetryBudget.backgroundInterruption(error) {
                // Not the reader's or the provider's fault: continue on return instead of showing an error.
                recorder?.failed("Interrupted while Leaf was in the background.", outcome: .failed)
                if let recorder { traceStore?.add(recorder.finish(outcome: .failed)) }
                if appInBackground() {
                    resumeOnForeground = true
                    notice = "Leaf left the screen during this reply. It continues when you come back."
                } else {
                    Task { @MainActor [weak self] in self?.resumeInterruptedReply() }
                }
                activeRecorder = nil; activity = nil; isSending = false; task = nil; flush(); refreshLatest()
                return
            }
            self.error = errorMessage(error)
            if let recorder {
                recorder.failed(self.error ?? "Failed", outcome: .failed)
                traceStore?.add(recorder.finish(outcome: .failed))
            }
        }
        if generation == token { activeRecorder = nil; activity = nil; isSending = false; task = nil; flush(); refreshLatest() }
    }
    /// Reuse the frozen request and reply ID. Never re-capture the book or append
    /// a second question when replacing an interrupted attempt.
    private func stream(_ request: ChatRequest, provider: any ChatProvider, into id: UUID, token: UUID,
                        recorder: AgentTraceRecorder? = nil, recovery: ChatRetryBudget, detail: String = "") async throws -> Bool {
        recorder?.context(system: request.system, turns: request.turns, detail: detail)
        return try await recovery.run(round: 1, recorder: recorder, onRetry: { [weak self] in
            self?.recover(id, token: token, retry: recovery.retries)
        }) { attempt in
            try await self.streamAttempt(request, provider: provider, into: id, token: token, recorder: recorder, attempt: attempt)
        }
    }
    /// Streams a plain request into a reply; returns whether it was truncated.
    private func streamAttempt(_ request: ChatRequest, provider: any ChatProvider, into id: UUID, token: UUID,
                               recorder: AgentTraceRecorder?, attempt: ChatRetryBudget.Attempt) async throws -> Bool {
        var answer = ""
        // A traced reply streams through the agent interface without tools, which also reports token usage.
        if let recorder, let tools = provider as? any ToolChatProvider {
            var usage: TokenUsage?
            for try await event in tools.streamAgent(system: request.system, items: request.turns.map(AgentItem.turn), tools: [], allowTools: false) {
                try Task.checkCancellation()
                attempt.received = true
                guard generation == token else { throw CancellationError() }
                switch event {
                case .text(let text): answer += text; append(text, to: id, token: token)
                case .usage(let value): usage = (usage ?? TokenUsage()) + value
                case .imageStarted: drawing(id, token: token)
                case .image(let data): try attachImage(data, to: id, token: token)
                case .imageToolRefused(let reason): imageToolRefused(reason, token: token)
                case .toolCall: break
                case .finished(let truncated): recorder.round(1, text: answer, calls: [], usage: usage, final: true); return truncated
                }
            }
            throw ChatError.interrupted
        }
        for try await event in provider.stream(request) {
            try Task.checkCancellation()
            attempt.received = true
            guard generation == token else { throw CancellationError() }
            switch event {
            case .text(let text): answer += text; append(text, to: id, token: token)
            case .imageStarted: drawing(id, token: token)
            case .image(let data): try attachImage(data, to: id, token: token)
            case .imageToolRefused(let reason): imageToolRefused(reason, token: token)
            case .finished(let truncated): recorder?.round(1, text: answer, calls: [], usage: nil, final: true); return truncated
            }
        }
        throw ChatError.interrupted
    }
    private func imageToolRefused(_ reason: String, token: UUID) {
        guard generation == token else { return }
        imageRefusal = reason
        activeRecorder?.imageToolRefused(reason)
    }
    /// Whether a question asks for a picture, in Chinese or English.
    static func asksForPicture(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["图片", "图像", "插图", "插画", "画一", "画个", "画张", "画幅", "配图", "生成一张", "draw", "picture", "image", "illustrat", "sketch", "paint"]
            .contains { lowered.contains($0) }
    }
    /// Shown in place of “Thinking…” while the model draws.
    private func drawing(_ id: UUID, token: UUID) {
        guard generation == token, let message = messages.first(where: { $0.id == id }), message.text.isEmpty else { return }
        activity = "Drawing the picture…"
    }
    private func attachImage(_ data: Data, to id: UUID, token: UUID) throws {
        guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let name = try ChatImageStore.save(data, in: imageDirectory)
        activity = nil
        messages[index].images = (messages[index].images ?? []) + [name]; changed(messages[index])
    }
    /// The file for one of a reply's pictures, if it is on this device.
    func imageURL(_ name: String) -> URL? { ChatImageStore.url(name, in: imageDirectory) }
    private func adopt(_ configuration: ChatConfiguration) {
        agentLimits = configuration.agentLimits; contextLimits = configuration.contextLimits; recordTraces = configuration.recordTraces
        traceSource = (configuration.provider.title, configuration.profile.model)
    }
    static func traceDetail(_ context: ReadingChatContext?, boundary: BookTextBoundary?, limits: AgentLimits?) -> String {
        guard let context else { return "no passage" }
        var parts = [context.source == "selection" ? "selection “\(context.text.prefix(30))”" : "page \(context.text.count.formatted()) chars"]
        let before = context.precedingText?.count ?? 0, after = context.followingText?.count ?? 0
        if before + after > 0 { parts.append("\(before.formatted()) + \(after.formatted()) chars nearby") }
        if let progress = context.progress { parts.append(String(format: "progress %.1f%%", progress * 100)) }
        if let boundary { parts.append("boundary §\(boundary.section + 1) @ \(boundary.offset)") }
        if let limits { parts.append("limits \(limits.maxToolCalls) calls / \(limits.maxRounds) rounds") }
        return parts.joined(separator: " · ")
    }
    /// The subject of the reader's last lookup or name selection, for follow-up questions.
    static func previousSubject(_ messages: [ReaderChatMessage]) -> String? {
        guard let context = messages.last(where: \.isUser)?.context else { return nil }
        if let term = context.bookRecall?.term, !term.isEmpty { return term }
        return context.source == "selection" ? ReadingAgentToolbox.nameLike(context.text) : nil
    }
    /// A screen's list for a request without tools: the top items, kept within a few thousand characters.
    static func screenText(_ screen: ChatScreen, sharePassages: Bool) -> (json: String, items: Int) {
        var limit = 30
        while true {
            let view = screen.view(limit, sharePassages)
            let json = ReadingAgentToolbox.json(view)
            let items = (view["items"] as? [Any])?.count ?? 0
            if json.count <= 12_000 || limit <= 5 { return (String(json.prefix(12_000)), items) }
            limit /= 2
        }
    }
    /// The pre-fetched evidence harness, also the agent's fallback.
    private func streamEvidence(provider: any ChatProvider, history: [ReaderChatMessage], earlier: [ReaderChatMessage], id: UUID, token: UUID, trace: inout ChatTrace,
                                recorder: AgentTraceRecorder? = nil, recovery: ChatRetryBudget, sharePage: Bool = true) async throws -> Bool {
        if let screen {
            let view = Self.screenText(screen, sharePassages: sharePage)
            trace.steps.append("sent the \(screen.name) screen as text (\(view.items))")
            return try await stream(ChatRequest.conversation(history, earlierMessages: earlier, screen: screen.name, screenView: view.json, limits: contextLimits),
                                    provider: provider, into: id, token: token, recorder: recorder, recovery: recovery, detail: "\(screen.name) screen as text")
        }
        var history = history
        if let index = history.lastIndex(where: \.isUser), var context = history[index].context, context.bookRecall == nil, let recall,
           let term = ReadingBookRecall.lookupTerm(question: history[index].text, context: context, previous: Self.previousSubject(Array(history[..<index]))) {
            activity = "Looking up “\(term)”…"
            context.bookRecall = try? await recall(term, context)
            history[index].context = context.bounded()
            if let found = context.bookRecall { trace.steps = ["looked up “\(found.term)” (\(found.excerpts.count))"]; recorder?.lookup(found) }
        }
        activity = nil
        try Task.checkCancellation()
        return try await stream(ChatRequest.conversation(history, earlierMessages: earlier, limits: contextLimits), provider: provider, into: id, token: token,
                                recorder: recorder, recovery: recovery, detail: Self.traceDetail(history.last(where: \.isUser)?.context?.bounded(contextLimits), boundary: nil, limits: nil))
    }
    private func recover(_ id: UUID, token: UUID, retry: Int) {
        guard generation == token else { return }
        withdraw(id, token: token)
        // The interrupted attempt is asked again in full, so its pictures are redrawn.
        if let index = messages.firstIndex(where: { $0.id == id }), let pictures = messages[index].images {
            ChatImageStore.remove(pictures, in: imageDirectory)
            messages[index].images = nil; changed(messages[index])
        }
        activity = "Connection interrupted. Retrying (\(retry)/\(retryPolicy.delays.count))…"
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
        let error = ChatRequestFailure.source(error)
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
        if ChatRetryBudget.socketDropped(error) { return "The connection was lost. Check your internet connection and retry." }
        return "Could not prepare the reading passage. Try again."
    }
}

#if DEBUG
// Explicit UI-test injection only; shipping builds never substitute sample replies.
struct UITestChatProvider: ChatProvider {
    var slow = false
    /// A landscape test picture: sky, sea and a sun, as JPEG like the hosted tool returns.
    static let samplePicture: Data = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).jpegData(withCompressionQuality: 0.85) { context in
        UIColor(red: 0.93, green: 0.76, blue: 0.55, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
        UIColor(red: 0.18, green: 0.36, blue: 0.47, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 240, width: 640, height: 160))
        UIColor(red: 0.98, green: 0.55, blue: 0.27, alpha: 1).setFill(); context.cgContext.fillEllipse(in: CGRect(x: 270, y: 170, width: 100, height: 100))
    }
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if UITesting.flag("LEAF_UI_CHAT_SCROLL_PERF") {
                        continuation.yield(.text((1...28).map {
                            "### 线索 \($0)\n\n白虎说完又看向几人。**人物的猜测**需要和已经发生的事情分开来看。读到这里，可以结合前文回顾这个角色的身份，观察他的话和行动是否一致。\n\n- 当前的解释还不是最终结论。\n- 保留阅读位置，继续寻找书中的证据。"
                        }.joined(separator: "\n\n")))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag("LEAF_UI_CHAT_SCROLL_STREAM") {
                        // A real model takes seconds before its first token; that pause is
                        // when the question and its placeholder have the history to themselves.
                        if UITesting.flag("LEAF_UI_CHAT_SLOW_START") { try await Task.sleep(for: .seconds(3)) }
                        continuation.yield(.text((1...10).map { "Paragraph \($0): Read this explanation at your own pace, without jumping to the newest words." }.joined(separator: "\n\n")))
                        continuation.yield(.text("\n\nUpdate 1:"))
                        for index in 1...600 {
                            try await Task.sleep(for: .milliseconds(500))
                            continuation.yield(.text(" next \(index)."))
                        }
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag("LEAF_UI_CHAT_FOLLOW") {
                        // A placeholder first, then small Chinese chunks that wrap and break paragraphs.
                        try await Task.sleep(for: .milliseconds(700))
                        let reply = (1...3).map { "第\($0)段：有，是一场限时十分钟的体力型淘汰游戏，发生在第三十七到四十四章。场地四面高墙，中央有一块圆形铁板；大铁门打开后，一只体型异常巨大的黑熊进场，门随即关闭。" }.joined(separator: "\n\n")
                        var index = reply.startIndex
                        while index < reply.endIndex {
                            let next = reply.index(index, offsetBy: 4, limitedBy: reply.endIndex) ?? reply.endIndex
                            continuation.yield(.text(String(reply[index..<next])))
                            index = next
                            try await Task.sleep(for: .milliseconds(60))
                        }
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag("LEAF_UI_CHAT_IMAGE") {
                        // The hosted image tool's order: drawing starts, the picture
                        // arrives whole, then the model's words.
                        continuation.yield(.imageStarted)
                        try await Task.sleep(for: .milliseconds(3000))
                        continuation.yield(.image(Self.samplePicture))
                        continuation.yield(.text("Here is the harbor "))
                        try await Task.sleep(for: .milliseconds(150))
                        continuation.yield(.text("at dawn, as the chapter describes it."))
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
                    if UITesting.flag("LEAF_UI_CHAT_MARKDOWN") {
                        continuation.yield(.text("## 人物\n\n这是**李"))
                        try await Task.sleep(for: .milliseconds(250))
                        continuation.yield(.text("香玲**，云瑶的队友。**要点：**模型常把结尾标记贴在标点上。\n\n- 第一条\n- 第二条\n\n```swift\nlet value = 1\n```\n\n尾句。"))
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
                    // Without tools (a traced pre-fetched reply) behave like the plain chat reply.
                    if tools.isEmpty {
                        let turns = items.compactMap { item -> ChatTurn? in if case .turn(let turn) = item { return turn }; return nil }
                        for try await event in stream(ChatRequest(system: system, turns: turns)) {
                            switch event {
                            case .text(let text): continuation.yield(.text(text))
                            case .imageStarted: continuation.yield(.imageStarted)
                            case .image(let data): continuation.yield(.image(data))
                            case .imageToolRefused(let reason): continuation.yield(.imageToolRefused(reason))
                            case .finished(let value):
                                continuation.yield(.usage(TokenUsage(input: 900, output: 24)))
                                continuation.yield(.finished(truncated: value))
                            }
                        }
                        continuation.finish(); return
                    }
                    try await Task.sleep(for: .milliseconds(150))
                    continuation.yield(.usage(TokenUsage(input: 1200 + items.count * 300, output: 30, cachedInput: 800)))
                    let results = items.compactMap { item -> [AgentToolResult]? in if case .toolResults(let value) = item { return value }; return nil }.last
                    if tools.contains(where: { $0.name == "get_current_view" }) {
                        if let output = results?.first(where: { $0.name == "get_current_view" })?.output {
                            let object = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] ?? [:]
                            if let open = object["open_book"] as? [String: Any] {
                                continuation.yield(.text("Screen reply: open book \(open["title"] ?? "?") · \(open["description"] ?? open["description_note"] ?? "?")"))
                            } else {
                                let rows = (object["items"] as? [[String: Any]] ?? []).prefix(3).map { "\($0["rank"] ?? "?"). \($0["title"] ?? $0["book"] ?? "?")" }
                                continuation.yield(.text("Screen reply: \(object["list"] ?? "?") · \(rows.joined(separator: "; "))"))
                            }
                        } else {
                            continuation.yield(.toolCall(AgentToolCall(id: "call_view", name: "get_current_view", arguments: ReadingAgentToolbox.json(["max_items": 5]))))
                        }
                        continuation.yield(.finished(truncated: false)); continuation.finish(); return
                    }
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
