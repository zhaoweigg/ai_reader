import XCTest
import SQLite3
@testable import LeafReader

private final class HistoryCredentials: ChatCredentialStore {
    func read(account: String) throws -> String? { nil }
    func write(_ key: String?, account: String) throws {}
}
private final class HistoryProvider: ChatProvider {
    var requests: [ChatRequest] = []
    var continuations: [AsyncThrowingStream<ChatEvent, Error>.Continuation] = []
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuations.append($0) }
    }
}
@MainActor private final class FailingHistory: ChatHistoryStorage {
    let backing: ChatHistoryStore
    var fails = false
    init(_ backing: ChatHistoryStore) { self.backing = backing }
    func page(before: Int64?, after: Int64?, limit: Int) throws -> ChatHistoryPage { try backing.page(before: before, after: after, limit: limit) }
    func loadDraft() throws -> String { try backing.loadDraft() }
    func loadSelectedContext() throws -> ReadingChatContext? { try backing.loadSelectedContext() }
    func save(_ messages: [ReaderChatMessage], draft: String?, selection: ChatDraftSelectionUpdate) throws {
        if fails { throw ChatHistoryError.write }; try backing.save(messages, draft: draft, selection: selection)
    }
    func remove(_ id: UUID) throws { if fails { throw ChatHistoryError.write }; try backing.remove(id) }
    func clear() throws { if fails { throw ChatHistoryError.write }; try backing.clear() }
}

@MainActor final class ChatHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func settings(_ provider: HistoryProvider) -> AISettingsStore {
        let suite = "ChatHistoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        // Keep settings and credentials isolated from the app's real account.
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AISettingsStore(defaults: defaults, credentials: HistoryCredentials(), providerOverride: provider)
    }
    private var context: ReadingChatContext {
        ReadingChatContext(title: "A Book", author: "Author", chapter: "Chapter 2", text: "The door stayed shut. 🌿", source: "page", locator: "private-locator")
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func complete(_ provider: HistoryProvider, _ text: String = "An explanation") {
        provider.continuations.last?.yield(.text(text)); provider.continuations.last?.yield(.finished(truncated: false)); provider.continuations.last?.finish()
    }
    func testLiveSelectionPreservesQuestionAndPersistsLatestQuoteWithoutSending() async throws {
        let directory = try directory(), session = ReaderChatSession(directory: directory, conversation: "live-selection")
        let first = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter,
                                       text: "选中的第一句话。", source: "selection", locator: "first")
        let latest = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter,
                                        text: "新的选中文字 🌿", source: "selection", locator: "latest")
        session.draft = "Why does this matter?\nMy interpretation is…"
        let draft = session.draft
        session.attachLiveSelection(first, chatIsPresented: false)
        XCTAssertNil(session.selectedContext, "Selecting while chat is closed must not attach a quote")
        session.attachLiveSelection(first, chatIsPresented: true)
        session.attachLiveSelection(latest, chatIsPresented: true)
        session.attachLiveSelection(latest, chatIsPresented: true)
        session.attachLiveSelection(nil, chatIsPresented: true)
        session.attachLiveSelection(ReadingChatContext(title: "", author: "", chapter: "", text: " \n", source: "selection", locator: ""), chatIsPresented: true)
        XCTAssertEqual(session.selectedContext, latest, "Losing native selection to the keyboard must keep the quote")
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(session.messages.isEmpty, "Selection alone must never submit a question")
        // Exercise the scheduled checkpoint, without explicitly flushing the session.
        let saved = try ChatHistoryStore(directory: directory, conversation: "live-selection")
        try await wait { (try? saved.loadSelectedContext()) == latest }
        let restored = ReaderChatSession(directory: directory, conversation: "live-selection")
        XCTAssertEqual(restored.selectedContext, latest); XCTAssertEqual(restored.draft, draft)
        restored.removeSelection(); restored.close()
        XCTAssertNil(ReaderChatSession(directory: directory, conversation: "live-selection").selectedContext)
    }
    func testLiveQuoteChosenDuringReplyBelongsToNextQuestion() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "live-during-reply")
        let first = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter, text: "First passage", source: "selection", locator: "first")
        let next = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter, text: "Second passage", source: "selection", locator: "next")
        session.attachLiveSelection(first, chatIsPresented: true); session.draft = "First question"
        session.send(settings: settings) { XCTFail("Use the automatically attached quote"); return nil }
        try await wait { provider.requests.count == 1 }
        session.draft = "Next question"; session.attachLiveSelection(next, chatIsPresented: true)
        XCTAssertEqual(session.messages.first?.context, first)
        complete(provider); try await wait { !session.isSending }
        XCTAssertEqual(session.selectedContext, next); XCTAssertEqual(session.draft, "Next question")
        session.close()
        let restored = ReaderChatSession(directory: directory, conversation: "live-during-reply")
        XCTAssertEqual(restored.selectedContext, next)
        restored.send(settings: settings) { XCTFail("Use the new saved quote"); return nil }
        try await wait { provider.requests.count == 2 }
        XCTAssertEqual(restored.messages.filter(\.isUser).last?.context, next)
        XCTAssertNil(restored.selectedContext)
        complete(provider); try await wait { !restored.isSending }
    }
    func testSelectedPassageAndDraftRestoreUntilSentOrExplicitlyRemoved() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let original = ReaderChatSession(directory: directory, conversation: "book-a")
        let selection = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter, text: context.text, source: "selection", locator: context.locator)
        original.draft = "My own question"
        original.attachSelection(selection, prompt: ReaderSelectionIntent.explain.prompt(for: selection.text))
        XCTAssertEqual(original.draft, "My own question\n\nExplain this passage.")
        XCTAssertTrue(original.messages.isEmpty); XCTAssertTrue(provider.requests.isEmpty)
        original.close()
        let restored = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(restored.selectedContext, selection)
        XCTAssertEqual(restored.draft, original.draft)
        XCTAssertNil(ReaderChatSession(directory: directory, conversation: "book-b").selectedContext)
        restored.send(settings: settings) { XCTFail("Use the selection snapshot even after native selection disappears"); return nil }
        try await wait { provider.requests.count == 1 }
        XCTAssertEqual(restored.messages.first?.context, selection)
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains(selection.text) == true)
        XCTAssertNil(restored.selectedContext)
        complete(provider); try await wait { !restored.isSending }
        let sent = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertNil(sent.selectedContext); XCTAssertEqual(sent.draft, "")
        XCTAssertEqual(sent.messages.first?.context, selection)
        sent.attachSelection(selection); sent.removeSelection(); sent.close()
        XCTAssertNil(ReaderChatSession(directory: directory, conversation: "book-a").selectedContext)
        sent.attachSelection(selection); sent.clear()
        let cleared = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertNil(cleared.selectedContext); XCTAssertTrue(cleared.messages.isEmpty)
    }
    func testSelectionShortcutsPrepareSavedDraftWithoutSending() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "shortcuts")
        session.attachSelection(context)
        session.prepareSelectionPrompt(.explain)
        XCTAssertEqual(session.draft, "Explain this passage.")
        session.prepareSelectionPrompt(.summarize)
        XCTAssertEqual(session.draft, "Summarize this passage.")
        XCTAssertEqual(session.selectedContext, context)
        XCTAssertTrue(session.messages.isEmpty); XCTAssertTrue(provider.requests.isEmpty)
        session.close()
        let restored = ReaderChatSession(directory: directory, conversation: "shortcuts")
        XCTAssertEqual(restored.draft, "Summarize this passage."); XCTAssertEqual(restored.selectedContext, context)
        restored.send(settings: settings) { XCTFail("Use the saved selection"); return nil }
        try await wait { provider.requests.count == 1 }
        XCTAssertEqual(restored.messages.first?.text, "Summarize this passage.")
        XCTAssertEqual(restored.messages.first?.context, context)
        complete(provider); try await wait { !restored.isSending }
    }
    func testSelectionShortcutsPreserveCustomQuestionWithoutAccumulatingPrompts() throws {
        let session = ReaderChatSession(directory: try directory(), conversation: "custom")
        session.draft = "Why did they leave?\nI think this is a clue."
        let question = session.draft
        session.prepareSelectionPrompt(.explain)
        XCTAssertEqual(session.draft, question, "No selection means no shortcut")
        session.attachSelection(context)
        session.prepareSelectionPrompt(.explain); session.prepareSelectionPrompt(.explain)
        XCTAssertEqual(session.draft, question + "\n\nExplain this passage.")
        session.prepareSelectionPrompt(.summarize)
        XCTAssertEqual(session.draft, question + "\n\nSummarize this passage.")
        session.prepareSelectionPrompt(.ask)
        XCTAssertEqual(session.draft, question + "\n\nSummarize this passage.")
        XCTAssertTrue(session.messages.isEmpty)
    }
    func testFailedSelectionSaveKeepsAttachmentAndCannotSend() async throws {
        let directory = try directory(), backing = try ChatHistoryStore(directory: directory, conversation: "book-a")
        let history = FailingHistory(backing), provider = HistoryProvider(), session = ReaderChatSession(history: history)
        history.fails = true
        session.attachSelection(context, prompt: "Keep this question")
        XCTAssertEqual(session.selectedContext, context); XCTAssertNotNil(session.historyError)
        session.send(settings: settings(provider)) { XCTFail("Do not read or send when the draft cannot be saved"); return nil }
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertEqual(session.draft, "Keep this question")
        history.fails = false; XCTAssertTrue(session.flush())
        let restored = ReaderChatSession(history: backing)
        XCTAssertEqual(restored.selectedContext, context); XCTAssertEqual(restored.draft, session.draft)
    }
    func testSelectionSharingRespectsPrivacyAndIntentLanguage() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        var config = settings.configuration; config.sharePage = false
        try settings.save(config, replacementKey: nil)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        session.attachSelection(context, prompt: "Explain this")
        session.send(settings: settings) { XCTFail("Sharing is off"); return nil }
        try await wait { provider.requests.count == 1 }
        XCTAssertFalse(provider.requests[0].turns.contains { $0.content.contains(self.context.text) })
        XCTAssertNil(session.messages.first?.context)
        XCTAssertTrue(session.notice?.contains("sharing is off") == true)
        complete(provider); try await wait { !session.isSending }
        XCTAssertEqual(ReaderSelectionIntent.ask.prompt(for: "选中文字"), "")
        XCTAssertEqual(ReaderSelectionIntent.explain.prompt(for: "选中文字"), "请解释这段文字。")
        XCTAssertEqual(ReaderSelectionIntent.summarize.prompt(for: "选中文字"), "请总结这段文字。")
        XCTAssertEqual(ReaderSelectionIntent.summarize.prompt(for: "A passage"), "Summarize this passage.")
    }
    func testCompletedConversationAndDraftRestoreAfterClosingAndRecreatingStore() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        session.draft = "为什么？ 🌿"
        session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        complete(provider, "Because the passage leaves it uncertain.")
        try await wait { !session.isSending }
        session.draft = "Follow up\nwith a detail\u{0}🌿"
        session.close()
        let restored = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(restored.messages, session.messages)
        XCTAssertEqual(restored.messages.first?.context, context)
        XCTAssertEqual(restored.draft, session.draft)
        XCTAssertNil(restored.historyError)
        restored.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].turns.count, 3)
        XCTAssertTrue(provider.requests[1].turns[0].content.contains("为什么？"))
        complete(provider); try await wait { !restored.isSending }
    }
    func testLargeArchivePagesWithoutDroppingOlderHistoryAndBooksStaySeparate() throws {
        let directory = try directory(), store = try ChatHistoryStore(directory: directory, conversation: "book-a")
        let originals = (0..<1200).map { ReaderChatMessage(isUser: $0 % 2 == 0, text: "Message \($0)") }
        try store.save(originals, draft: "Draft A")
        let other = try ChatHistoryStore(directory: directory, conversation: "book-b")
        try other.save([ReaderChatMessage(isUser: true, text: "Other book")], draft: "Draft B")
        let session = ReaderChatSession(history: store)
        XCTAssertEqual(session.messages.count, 24)
        XCTAssertEqual(session.messages.first?.text, "Message 1176")
        XCTAssertTrue(session.hasEarlierMessages); XCTAssertFalse(session.hasNewerMessages)
        session.loadEarlier()
        XCTAssertEqual(session.messages.count, 24); XCTAssertEqual(session.messages.first?.text, "Message 1152")
        XCTAssertTrue(session.hasNewerMessages)
        session.loadNewer(); XCTAssertEqual(session.messages.first?.text, "Message 1176")
        var all: [ReaderChatMessage] = [], cursor: Int64?
        repeat {
            let page = try store.page(before: cursor)
            all = page.messages + all; cursor = page.oldest
            if !page.hasEarlier { break }
        } while true
        XCTAssertEqual(all, originals)
        session.clear()
        XCTAssertTrue(try store.page().messages.isEmpty); XCTAssertEqual(try store.loadDraft(), "")
        XCTAssertEqual(try other.page().messages.first?.text, "Other book")
        XCTAssertEqual(try other.loadDraft(), "Draft B")
    }
    func testInterruptedStreamIsCheckpointedAndRetryRetainsOriginalPassage() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        session.draft = "Explain this"
        session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial reply"))
        try await wait { session.messages.last?.text == "Partial reply" }
        try await Task.sleep(for: .milliseconds(650))
        let checkpoint = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(checkpoint.messages.last?.text, "Partial reply")
        XCTAssertEqual(checkpoint.messages.last?.state, .stopped)
        XCTAssertTrue(checkpoint.canRetry); XCTAssertFalse(checkpoint.isSending)
        session.close()
        let restored = ReaderChatSession(directory: directory, conversation: "book-a")
        restored.retry(settings: settings)
        try await wait { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[0].turns, provider.requests[1].turns)
        complete(provider, "Completed on retry"); try await wait { !restored.isSending }
        let final = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(final.messages.count, 2); XCTAssertEqual(final.messages.last?.text, "Completed on retry")
    }
    func testClearCannotBeUndoneByLateReplyOrPendingDraftCheckpoint() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        session.draft = "Explain this"; session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial reply"))
        try await wait { session.messages.last?.text == "Partial reply" }
        session.draft = "An unsent draft"; session.clear()
        provider.continuations[0].yield(.text("Late response must not return")); provider.continuations[0].finish()
        try await Task.sleep(for: .milliseconds(650))
        let restored = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertTrue(restored.messages.isEmpty); XCTAssertEqual(restored.draft, "")
        XCTAssertTrue(session.messages.isEmpty); XCTAssertNil(restored.historyError)
    }
    func testSendingWhileBrowsingOlderMessagesUsesLatestConversation() async throws {
        let directory = try directory(), store = try ChatHistoryStore(directory: directory, conversation: "book-a")
        try store.save((0..<60).map { ReaderChatMessage(isUser: $0 % 2 == 0, text: "Message \($0)") }, draft: nil)
        let provider = HistoryProvider(), settings = settings(provider), session = ReaderChatSession(history: store)
        session.loadEarlier(); XCTAssertTrue(session.hasNewerMessages)
        session.draft = "A followup"; session.send(settings: settings) { nil }
        try await wait { provider.requests.count == 1 }
        XCTAssertTrue(provider.requests[0].turns.contains(where: { $0.content == "Message 59" }))
        XCTAssertFalse(provider.requests[0].turns.contains(where: { $0.content == "Message 20" }))
        XCTAssertLessThanOrEqual(provider.requests[0].turns.count, 12)
        complete(provider); try await wait { !session.isSending }
        XCTAssertEqual(session.messages.count, 24); XCTAssertFalse(session.hasNewerMessages)
    }
    func testWriteFailureKeepsDraftAndDoesNotSendAndClearFailureKeepsHistory() async throws {
        let directory = try directory(), backing = try ChatHistoryStore(directory: directory, conversation: "book-a")
        try backing.save([ReaderChatMessage(isUser: true, text: "Keep this")], draft: nil)
        let history = FailingHistory(backing), session = ReaderChatSession(history: history), provider = HistoryProvider()
        history.fails = true; session.draft = "Keep my unsent question"
        session.send(settings: settings(provider)) { XCTFail("Do not read a passage when history cannot be saved"); return nil }
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertEqual(session.draft, "Keep my unsent question")
        XCTAssertNotNil(session.historyError)
        session.clear(); XCTAssertEqual(session.messages.first?.text, "Keep this")
        XCTAssertEqual(try backing.page().messages.first?.text, "Keep this")
        history.fails = false; XCTAssertTrue(session.flush())
        XCTAssertEqual(try backing.loadDraft(), "Keep my unsent question")
        session.clear(); XCTAssertTrue(try backing.page().messages.isEmpty)
    }
    func testCorruptDatabaseIsNotDeletedOrReplaced() throws {
        let directory = try directory(), file = directory.appendingPathComponent("conversations.sqlite")
        let original = Data("Existing data that is not a SQLite database".utf8)
        try original.write(to: file)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertNotNil(session.historyError); XCTAssertFalse(session.canSaveHistory)
        session.draft = "Do not overwrite the existing file"; XCTAssertFalse(session.flush())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testFailedQuestionCommitCanRecoverWithoutLosingDraftOrSendingTwice() async throws {
        let directory = try directory(), history = FailingHistory(try ChatHistoryStore(directory: directory, conversation: "book-a"))
        let session = ReaderChatSession(history: history), provider = HistoryProvider(), settings = settings(provider)
        session.draft = "Preserve this question"
        session.send(settings: settings) { history.fails = true; return self.context }
        try await wait { !session.isSending }
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.draft, "Preserve this question"); XCTAssertNotNil(session.historyError)
        history.fails = false; XCTAssertTrue(session.flush()); XCTAssertNil(session.historyError)
        session.send(settings: settings) { self.context }
        try await wait { provider.requests.count == 1 }
        complete(provider); try await wait { !session.isSending }
        XCTAssertEqual(session.messages.filter(\.isUser).count, 1)
        XCTAssertEqual(try history.backing.page().messages.count, 2)
    }
    func testMalformedMessageBlocksNewWritesUntilExplicitClear() throws {
        let directory = try directory(), store = try ChatHistoryStore(directory: directory, conversation: "book-a")
        try store.save([ReaderChatMessage(isUser: true, text: "Existing message")], draft: "Existing draft")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("conversations.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE messages SET payload = X'7B'", nil, nil, nil), SQLITE_OK)
        let session = ReaderChatSession(history: store)
        XCTAssertNotNil(session.historyError)
        session.draft = "New unsaved draft"; XCTAssertFalse(session.flush())
        XCTAssertEqual(try store.loadDraft(), "Existing draft")
        session.clear(); XCTAssertNil(session.historyError)
        XCTAssertTrue(try store.page().messages.isEmpty)
    }
    func testReimportingSameBookRestoresConversationWithoutDeletingItWithBook() throws {
        let root = try directory(), disk = try LibraryDisk(root: root)
        let source = root.appendingPathComponent("Story.txt")
        try Data("A quiet afternoon.".utf8).write(to: source)
        let original = try disk.prepareImport(source, existing: [])
        let historyDirectory = root.appendingPathComponent("ChatHistory")
        let history = try ChatHistoryStore(directory: historyDirectory, conversation: original.fingerprint)
        try history.save([ReaderChatMessage(isUser: true, text: "Keep this discussion")], draft: nil)
        try disk.removeFiles(original)
        let imported = try disk.prepareImport(source, existing: [])
        XCTAssertNotEqual(imported.id, original.id); XCTAssertEqual(imported.fingerprint, original.fingerprint)
        let restored = ReaderChatSession(directory: historyDirectory, conversation: imported.fingerprint)
        XCTAssertEqual(restored.messages.first?.text, "Keep this discussion")
    }
}
