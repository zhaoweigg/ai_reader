import Foundation
import UIKit

@MainActor
final class ReaderChatSession: ObservableObject {
    @Published private(set) var messages: [ReaderChatMessage] = []
    @Published var draft = "" { didSet { if !restoring { draftDirty = true; scheduleCheckpoint() } } }
    @Published private(set) var selectedContext: ReadingChatContext?
    @Published private(set) var isSending = false {
        didSet {
            if isSending != oldValue { isSending ? holdInBackground() : releaseBackground() }
            updateRetention()
        }
    }
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
    /// The rest of the app, which every chat's agent can read.
    private var app: ChatAppData?
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
    /// The prompt last put in the draft for the reader, so the next one can replace it.
    private var preparedPrompt: String?
    private var pendingMessageIDs = Set<UUID>()
    private var checkpoint: Task<Void, Never>?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    /// Streamed text reaches the history in batches: a reply arrives a few characters at
    /// a time, and re-laying the history out for each piece made scrolling it stutter.
    private var pendingText: (id: UUID, token: UUID, text: String)?
    private var pendingTextFlush: Task<Void, Never>?
    /// Set by the chat panel while the reader's finger or momentum moves the history, so
    /// new text waits instead of competing with the scroll for frames.
    var holdsStreamedText = false { didSet { if oldValue && !holdsStreamedText { flushPendingText() } } }
    static let streamBatchDelay: Duration = .milliseconds(80)
    static let streamHoldDelay: Duration = .milliseconds(1200)
    var canRetry: Bool { !isSending && !hasNewerMessages && messages.last?.isUser == false && messages.last?.state != .complete }
    /// iOS suspends Leaf seconds after it leaves the screen and cuts its connections. A reply keeps
    /// running for the short extra time iOS grants, and one cut off there continues on return.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var backgroundedDuringReply = false
    private var resumeOnForeground = false { didSet { updateRetention() } }
    private var retentionChanged: ((Bool) -> Void)?
    private static let conversations = ChatSessionRegistry<ReaderChatSession>()

    /// Library, other tabs and the reader reopen the same live request instead
    /// of interpreting its saved streaming checkpoint as an interrupted reply.
    static func conversation(directory: URL?, id: String) -> ReaderChatSession {
        guard let directory else { return ReaderChatSession(directory: nil, conversation: id) }
        let key = ChatSessionKey(directory: directory, conversation: id)
        let session = conversations.session(for: key) { ReaderChatSession(directory: directory, conversation: id) }
        session.retentionChanged = { [weak session] active in
            guard let session else { return }
            conversations.setActive(active, session: session, for: key)
        }
        session.updateRetention()
        return session
    }
    private func updateRetention() { retentionChanged?(isSending || resumeOnForeground) }
    /// Held strongly: the continue must still have the settings the question was asked with.
    private var replySettings: AISettingsStore?
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
        flushPendingText()
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
    /// Attaches a passage with a request that is complete in itself, such as Translate.
    /// True when that request is the whole draft and no reply is in flight, so the
    /// caller can send it; otherwise it stays a draft beside what the reader wrote.
    func attachSelection(_ context: ReadingChatContext, sending intent: ReaderSelectionIntent) -> Bool {
        guard !context.isEmpty, intent != .ask else { return false }
        let passage = context.bounded()
        selectedContext = passage; selectionDirty = true
        prepareSelectionPrompt(intent)
        return !isSending && draft.trimmingCharacters(in: .whitespacesAndNewlines) == intent.prompt(for: passage.text)
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
        prepare(intent.prompt(for: selection.text), about: selection)
    }
    /// Puts a quick prompt about the selected text in the draft, after anything the
    /// reader has typed. True when no reply is in flight, so the caller can send the
    /// draft at once; otherwise it waits there for the reader to send.
    func applyQuickPrompt(_ prompt: String) -> Bool {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selection = selectedContext, !prompt.isEmpty else { return false }
        prepare(prompt, about: selection)
        return !isSending
    }
    /// A prepared prompt replaces the one prepared before it instead of piling up.
    private func prepare(_ prompt: String, about selection: ReadingChatContext) {
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = ([preparedPrompt].compactMap { $0 } + [ReaderSelectionIntent.explain, .summarize, .translate].map { $0.prompt(for: selection.text) }).filter { !$0.isEmpty }
        if current.isEmpty || presets.contains(current) { draft = prompt }
        else if let previous = presets.first(where: { current.hasSuffix("\n\n" + $0) }) {
            draft = String(current.dropLast(previous.count)) + prompt
        }
        else if !current.hasSuffix(prompt) { draft += "\n\n" + prompt }
        preparedPrompt = prompt
        flush()
    }

    func send(settings: AISettingsStore, missingContextNotice: String? = "No readable page text was found. This question is sent without a passage; you can paste one yourself.", app: ChatAppData? = nil, agentBook: (@MainActor (ReadingChatContext) async throws -> ReadingAgentBook?)? = nil, screen: ChatScreen? = nil, traces: AgentTraceStore? = nil, context: @escaping @MainActor () async throws -> ReadingChatContext?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !question.isEmpty else { return }
        guard flush() else { return }
        guard question.count <= 4000 else { error = "Keep your question under 4,000 characters."; return }
        let provider: any ChatProvider
        do { provider = try settings.provider() }
        catch { self.error = error.localizedDescription; return }
        let sharePage = settings.configuration.sharePage
        replySettings = settings
        // Retries reuse the book access of the reader that sent the question.
        self.app = app; self.agentBook = agentBook; self.screen = screen; traceStore = traces
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
                await self.respond(provider: provider, token: token, sharePage: sharePage, replyID: replyID)
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
            start { [weak self] token in await self?.respond(provider: provider, token: token, sharePage: configuration.sharePage) }
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        let waitingToResume = resumeOnForeground
        resumeOnForeground = false
        if waitingToResume && !isSending { notice = "Response stopped."; flush() }
        guard isSending else { return }
        flushPendingText()
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
    /// Dismissal saves the view's draft and passage; only Stop/Clear cancels a reply.
    func close() { flush() }

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
        task?.cancel(); checkpoint?.cancel(); pendingTextFlush?.cancel()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        if backgroundTask != .invalid { let task = backgroundTask; Task { @MainActor in UIApplication.shared.endBackgroundTask(task) } }
    }

    private func start(_ operation: @escaping @MainActor (UUID) async -> Void) {
        error = nil; notice = nil; backgroundedDuringReply = appInBackground(); resumeOnForeground = false; isSending = true
        let token = UUID(); generation = token
        task = Task { await operation(token) }
    }
    private func respond(provider: any ChatProvider, token: UUID, sharePage: Bool, replyID: UUID? = nil) async {
        let id = replyID ?? UUID()
        var history = messages.filter { $0.id != id }
        if !sharePage { for index in history.indices { history[index].context = nil } }
        if replyID == nil { messages.append(ReaderChatMessage(id: id, isUser: false, text: "", state: .streaming)) }
        changed(messages.last!)
        guard flush() else {
            messages[messages.count - 1].state = .failed; changed(messages.last!)
            notice = "The reply has not been sent. Retry after saving your conversation."
            isSending = false; task = nil; return
        }
        var trace = ChatTrace()
        imageRefusal = nil
        let asked = history.last(where: \.isUser)
        let tools = provider as? any ToolChatProvider
        let recorder: AgentTraceRecorder? = recordTraces && traceStore != nil ? AgentTraceRecorder(trace: AgentTrace(
            provider: traceSource.provider, model: traceSource.model, bookTitle: asked?.context?.title ?? "",
            chapter: asked?.context?.chapter ?? "", question: asked?.text ?? "",
            selection: asked?.context?.source == "selection" ? asked?.context?.text : nil, limits: tools == nil ? nil : agentLimits)) : nil
        activeRecorder = recorder
        let recovery = ChatRetryBudget(policy: retryPolicy)
        do {
            let truncated: Bool
            if let tools {
                // Book text leaves the device only through tool results, which passage sharing governs.
                // Catalog and library listings are not book text; passages and notes follow the same switch.
                var book: ReadingAgentBook?
                if sharePage, let context = asked?.context, let agentBook { book = try? await agentBook(context) }
                try Task.checkCancellation()
                let app = self.app
                let toolbox = ReadingAgentToolbox(book: book, screen: book == nil ? screen : nil, app: app) { [weak self] terms in self?.conversationMatches(terms) ?? "{\"matches\":[]}" }
                toolbox.limits = agentLimits; toolbox.sharePassages = sharePage; toolbox.webSearch = true
                toolbox.activity = { [weak self] text in if self?.generation == token { self?.activity = text } }
                do {
                    let request = ChatRequest.conversation(history, earlierMessages: book == nil && app == nil ? loadEarlier(sharePage: sharePage) : [],
                                                           bookTools: book != nil, appTools: app != nil, screen: book == nil ? screen?.name : nil, limits: contextLimits)
                    var detail = book.map { Self.traceDetail(asked?.context?.bounded(contextLimits), boundary: $0.boundary, limits: agentLimits) }
                        ?? screen.map { "\($0.name) screen · limits \(agentLimits.maxToolCalls) calls / \(agentLimits.maxRounds) rounds" }
                        ?? "no book open · limits \(agentLimits.maxToolCalls) calls / \(agentLimits.maxRounds) rounds"
                    if app != nil { detail += " · app tools" }
                    if book == nil, sharePage, agentBook != nil { trace.steps = ["book text unavailable"] }
                    recorder?.context(system: request.system, turns: request.turns, detail: detail)
                    // A highlighted name is searched before the model answers, so a
                    // “who is this” reply always starts from the book, not the chat.
                    let selection = asked?.context?.source == "selection" ? asked?.context?.text : nil
                    let followUp = asked.flatMap { asked in asked.context.flatMap { context in
                        ReadingAgentToolbox.followUpTerm(question: asked.text, context: context, previous: Self.previousSubject(history.filter { $0.id != asked.id }))
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
                    trace.steps += toolbox.steps; truncated = outcome.truncated
                } catch ReadingAgentError.toolsUnsupported {
                    // The model or provider refused tools: answer once without them.
                    trace.steps = []; trace.fellBack = true; recorder?.withoutTools()
                    truncated = try await streamWithoutTools(provider: provider, history: history, id: id, token: token, trace: &trace,
                                                             recorder: recorder, recovery: recovery, sharePage: sharePage)
                }
            } else {
                trace.fellBack = true; recorder?.withoutTools()
                truncated = try await streamWithoutTools(provider: provider, history: history, id: id, token: token, trace: &trace,
                                                         recorder: recorder, recovery: recovery, sharePage: sharePage)
            }
            flushPendingText()
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
            flushPendingText()
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].state = .failed; messages[index].trace = trace; changed(messages[index])
            }
            if backgroundedDuringReply, ChatRetryBudget.backgroundInterruption(error) {
                // Not the reader's or the provider's fault: continue on return instead of showing an error.
                recorder?.failed("Interrupted while Leaf was in the background.", outcome: .failed)
                if let recorder { traceStore?.add(recorder.finish(outcome: .failed)) }
                // Keep an owner until either the foreground notification or the
                // queued foreground continuation takes over. Close may have
                // already removed every view; Stop clears this pending flag.
                resumeOnForeground = true
                if appInBackground() {
                    notice = "Leaf left the screen during this reply. It continues when you come back."
                } else {
                    Task { @MainActor [weak self] in self?.appWillEnterForeground() }
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
                case .toolCall, .webSearch, .webSearchRefused, .providerContent: break
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
        flushPendingText()
        guard generation == token, let message = messages.first(where: { $0.id == id }), message.text.isEmpty else { return }
        activity = "Drawing the picture…"
    }
    private func attachImage(_ data: Data, to id: UUID, token: UUID) throws {
        guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let name = try ChatImageStore.save(data, in: imageDirectory)
        flushPendingText()
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
    /// Older messages for a request that cannot search them with a tool.
    private func loadEarlier(sharePage: Bool) -> [ReaderChatMessage] {
        guard let storage = history, let oldest, hasEarlierMessages else { return [] }
        do {
            var earlier = try storage.page(before: oldest, after: nil, limit: 48).messages
            if !sharePage { for index in earlier.indices { earlier[index].context = nil } }
            return earlier
        } catch {
            notice = "Earlier discussion could not be loaded; this reply uses recent messages."
            return []
        }
    }
    /// A reply from a provider or model without tool support: the question, its
    /// passage, earlier discussion and, from a screen, the screen's list as text.
    private func streamWithoutTools(provider: any ChatProvider, history: [ReaderChatMessage], id: UUID, token: UUID, trace: inout ChatTrace,
                                    recorder: AgentTraceRecorder? = nil, recovery: ChatRetryBudget, sharePage: Bool) async throws -> Bool {
        let earlier = loadEarlier(sharePage: sharePage)
        activity = nil
        try Task.checkCancellation()
        if let screen {
            let view = Self.screenText(screen, sharePassages: sharePage)
            trace.steps.append("sent the \(screen.name) screen as text (\(view.items))")
            return try await stream(ChatRequest.conversation(history, earlierMessages: earlier, screen: screen.name, screenView: view.json, limits: contextLimits),
                                    provider: provider, into: id, token: token, recorder: recorder, recovery: recovery, detail: "\(screen.name) screen as text")
        }
        if !sharePage { trace.steps.append("passage sharing off") }
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
        // The first words replace “Thinking…” at once; what follows is batched.
        if messages[index].text.isEmpty, pendingText == nil {
            messages[index].text += text; changed(messages[index]); return
        }
        if pendingText?.id == id { pendingText?.text += text } else { flushPendingText(); pendingText = (id, token, text) }
        scheduleTextFlush()
    }
    private func scheduleTextFlush() {
        guard pendingTextFlush == nil else { return }
        pendingTextFlush = Task { [weak self] in
            var delay = self?.holdsStreamedText == true ? Self.streamHoldDelay : Self.streamBatchDelay
            while true {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                // A scroll that began during the wait keeps the text back a while longer.
                guard self.holdsStreamedText, delay == Self.streamBatchDelay else { break }
                delay = Self.streamHoldDelay
            }
            self?.pendingTextFlush = nil
            self?.flushPendingText()
        }
    }
    /// Puts text waiting in a batch into its reply. Every other change to a streaming
    /// reply goes through here first, so nothing lands out of order or gets lost.
    private func flushPendingText() {
        pendingTextFlush?.cancel(); pendingTextFlush = nil
        guard let pending = pendingText else { return }
        pendingText = nil
        guard generation == pending.token, let index = messages.firstIndex(where: { $0.id == pending.id }) else { return }
        messages[index].text += pending.text; changed(messages[index])
    }
    private func withdraw(_ id: UUID, token: UUID) {
        guard generation == token, let index = messages.firstIndex(where: { $0.id == id }) else { return }
        pendingTextFlush?.cancel(); pendingTextFlush = nil; pendingText = nil
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
