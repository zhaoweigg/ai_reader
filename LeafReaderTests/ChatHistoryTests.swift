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
    private func complete(_ provider: HistoryProvider, _ text: String = "An explanation") {
        provider.continuations.last?.yield(.text(text)); provider.continuations.last?.yield(.finished(truncated: false)); provider.continuations.last?.finish()
    }
    func testReadingContextAndRelevantOlderDiscussionSurviveRelaunchAndClear() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let storage = try ChatHistoryStore(directory: directory, conversation: "book")
        let enriched = ReadingChatContext(title: "A Book", author: "Author", chapter: "Chapter 2", text: "A silver key", source: "selection", locator: "private-locator",
                                          precedingText: "Lin entered.", followingText: "He locked the door.", progress: 0.2)
        var messages = [ReaderChatMessage(isUser: true, text: "Who hid the silver key?", context: enriched), ReaderChatMessage(isUser: false, text: "We discussed Lin's silver key.")]
        for n in 0..<16 { messages += [ReaderChatMessage(isUser: true, text: "Unrelated topic \(n)"), ReaderChatMessage(isUser: false, text: "Other discussion \(n)")] }
        try storage.save(messages, draft: "Why is the silver key important?", selection: .set(enriched))
        let session = ReaderChatSession(directory: directory, conversation: "book")
        XCTAssertTrue(session.hasEarlierMessages); XCTAssertEqual(session.selectedContext, enriched)
        session.send(settings: settings) { XCTFail("Restored attached quote should be used"); return nil }
        try await eventually { !provider.requests.isEmpty }
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains("Who hid the silver key?") == true)
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains("Lin entered.") == true)
        complete(provider); try await eventually { !session.isSending }
        session.clear(); XCTAssertTrue(session.messages.isEmpty)
        session.draft = "Why is the silver key important?"
        session.send(settings: settings) { nil }; try await eventually { provider.requests.count == 2 }
        XCTAssertFalse(provider.requests[1].turns.last?.content.contains("earlier_discussion") == true)
        complete(provider); try await eventually { !session.isSending }
    }
    func testSharingOffRemovesPassagesFromOlderDiscussionAsWellAsRecentMessages() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        var config = settings.configuration; config.sharePage = false; try settings.save(config, replacementKey: nil)
        let storage = try ChatHistoryStore(directory: directory, conversation: "book")
        var messages = [ReaderChatMessage(isUser: true, text: "Explain the silver key", context: context), ReaderChatMessage(isUser: false, text: "An interpretation of the silver key")]
        for n in 0..<16 { messages += [ReaderChatMessage(isUser: true, text: "Other \(n)"), ReaderChatMessage(isUser: false, text: "Other answer \(n)")] }
        try storage.save(messages, draft: "What about the silver key?", selection: .set(context))
        let session = ReaderChatSession(directory: directory, conversation: "book")
        session.send(settings: settings) { XCTFail("Passage sharing is disabled"); return nil }
        try await eventually { !provider.requests.isEmpty }
        let request = provider.requests[0].turns.map(\.content).joined()
        XCTAssertTrue(request.contains("earlier_discussion")); XCTAssertFalse(request.contains("passage_excerpt"))
        XCTAssertFalse(request.contains("The door stayed shut.")); XCTAssertFalse(request.contains("private-locator"))
        complete(provider); try await eventually { !session.isSending }
    }
    func testLibraryGeneralChatHasNoBookContextAndStaysSeparateFromBookHistory() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let book = ReaderChatSession(directory: directory, conversation: "book-fingerprint")
        book.draft = "Book draft"; book.attachSelection(context)
        let general = ReaderChatSession(directory: directory, conversation: "leaf.library.general.v1")
        general.draft = "Hello from Library"
        general.send(settings: settings, missingContextNotice: nil) { nil }
        try await eventually { provider.requests.count == 1 }
        XCTAssertEqual(provider.requests[0].turns.last?.content, "Hello from Library")
        XCTAssertNil(general.messages.first?.context); XCTAssertNil(general.notice)
        complete(provider); try await eventually { !general.isSending }
        general.close()
        XCTAssertEqual(ReaderChatSession(directory: directory, conversation: "leaf.library.general.v1").messages.count, 2)
        general.clear()
        let restoredBook = ReaderChatSession(directory: directory, conversation: "book-fingerprint")
        XCTAssertEqual(restoredBook.draft, "Book draft"); XCTAssertEqual(restoredBook.selectedContext, context)
    }
    func testLibraryBookChatSendsOnlyMetadataAndResumesAnAttachedQuote() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let metadata = ReadingChatContext(title: "A Book", author: "Author", chapter: "", text: "", source: "library_metadata", locator: "")
        let library = ReaderChatSession(directory: directory, conversation: "same-book")
        library.draft = "Who wrote this?"
        library.send(settings: settings, missingContextNotice: nil) { metadata }
        try await eventually { provider.requests.count == 1 }
        XCTAssertEqual(library.messages.first?.context, metadata); XCTAssertNil(library.notice)
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains("library_metadata") == true)
        XCTAssertFalse(provider.requests[0].turns.last?.content.contains(context.text) == true)
        complete(provider); try await eventually { !library.isSending }; library.close()
        let reader = ReaderChatSession(directory: directory, conversation: "same-book")
        XCTAssertEqual(reader.messages.count, 2)
        reader.attachSelection(context); reader.draft = "Explain this quote"; reader.close()
        let resumed = ReaderChatSession(directory: directory, conversation: "same-book")
        resumed.send(settings: settings, missingContextNotice: nil) { XCTFail("Use the persisted quote"); return metadata }
        try await eventually { provider.requests.count == 2 }
        XCTAssertEqual(resumed.messages.last(where: \.isUser)?.context, context)
        complete(provider); try await eventually { !resumed.isSending }
    }
    func testLiveSelectionPreservesQuestionAndPersistsLatestQuoteWithoutSending() async throws {
        let directory = try directory(), session = ReaderChatSession(directory: directory, conversation: "live-selection")
        let first = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter,
                                       text: "选中的第一句话。", source: "selection", locator: "first")
        let latest = ReadingChatContext(title: context.title, author: context.author, chapter: context.chapter,
                                        text: "”\n\n　　是是是！阿目被抽了一巴掌，反而笑得更灿烂了。\n\n各位大哥大姐，我们真的错了。 🌿", source: "selection", locator: "latest")
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
        XCTAssertEqual(session.selectedContext?.previewText, "” 是是是！阿目被抽了一巴掌，反而笑得更灿烂了。 各位大哥大姐，我们真的错了。 🌿")
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(session.messages.isEmpty, "Selection alone must never submit a question")
        // Exercise the scheduled checkpoint, without explicitly flushing the session.
        let saved = try ChatHistoryStore(directory: directory, conversation: "live-selection")
        try await eventually { (try? saved.loadSelectedContext()) == latest }
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
        try await eventually { provider.requests.count == 1 }
        session.draft = "Next question"; session.attachLiveSelection(next, chatIsPresented: true)
        XCTAssertEqual(session.messages.first?.context, first)
        complete(provider); try await eventually { !session.isSending }
        XCTAssertEqual(session.selectedContext, next); XCTAssertEqual(session.draft, "Next question")
        session.close()
        let restored = ReaderChatSession(directory: directory, conversation: "live-during-reply")
        XCTAssertEqual(restored.selectedContext, next)
        restored.send(settings: settings) { XCTFail("Use the new saved quote"); return nil }
        try await eventually { provider.requests.count == 2 }
        XCTAssertEqual(restored.messages.filter(\.isUser).last?.context, next)
        XCTAssertNil(restored.selectedContext)
        complete(provider); try await eventually { !restored.isSending }
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
        try await eventually { provider.requests.count == 1 }
        XCTAssertEqual(restored.messages.first?.context, selection)
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains(selection.text) == true)
        XCTAssertNil(restored.selectedContext)
        complete(provider); try await eventually { !restored.isSending }
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
        try await eventually { provider.requests.count == 1 }
        XCTAssertEqual(restored.messages.first?.text, "Summarize this passage.")
        XCTAssertEqual(restored.messages.first?.context, context)
        complete(provider); try await eventually { !restored.isSending }
    }
    func testTranslateRequestIsSentAtOnceOnlyWhenNothingElseIsWaiting() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let request = "请把这段文字翻译成简体中文。"
        let session = ReaderChatSession(directory: directory, conversation: "translate")
        XCTAssertFalse(session.attachSelection(context, sending: .ask), "Ask Leaf has no request of its own")
        XCTAssertNil(session.selectedContext)
        XCTAssertTrue(session.attachSelection(context, sending: .translate))
        XCTAssertEqual(session.draft, request); XCTAssertEqual(session.selectedContext, context)
        XCTAssertTrue(provider.requests.isEmpty, "Attaching sends nothing by itself")
        session.send(settings: settings) { XCTFail("Use the selected passage"); return nil }
        try await eventually { provider.requests.count == 1 }
        XCTAssertEqual(session.messages.first?.text, request); XCTAssertEqual(session.messages.first?.context, context)
        XCTAssertEqual(session.draft, ""); XCTAssertNil(session.selectedContext)
        XCTAssertTrue(provider.requests[0].turns.last?.content.contains("The door stayed shut.") == true, "The passage travels with the request")
        // A reply is still arriving: the next request waits as a draft.
        XCTAssertFalse(session.attachSelection(context, sending: .translate))
        XCTAssertEqual(session.draft, request); XCTAssertEqual(provider.requests.count, 1)
        complete(provider, "门一直关着。"); try await eventually { !session.isSending }
        // A prepared shortcut is replaced; the reader's own words are kept and never sent for them.
        session.prepareSelectionPrompt(.explain)
        XCTAssertEqual(session.draft, "Explain this passage.")
        XCTAssertTrue(session.attachSelection(context, sending: .translate))
        XCTAssertEqual(session.draft, request)
        session.draft = "Why did they leave?"
        XCTAssertFalse(session.attachSelection(context, sending: .translate))
        XCTAssertEqual(session.draft, "Why did they leave?\n\n" + request)
        let chinese = ReadingChatContext(title: "书", author: "作者", chapter: "第一章", text: "门一直关着。", source: "selection", locator: "private-locator")
        session.draft = ""
        XCTAssertTrue(session.attachSelection(chinese, sending: .translate))
        XCTAssertEqual(session.draft, "Translate this passage into English.")
    }
    func testQuickPromptIsSentAtOnceWithWhatTheReaderTyped() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "quick")
        XCTAssertFalse(session.applyQuickPrompt("List the hard words."), "No selection means no quick prompt")
        XCTAssertEqual(session.draft, "")
        session.attachSelection(context)
        XCTAssertFalse(session.applyQuickPrompt("  \n"), "An empty prompt asks nothing")
        XCTAssertTrue(session.applyQuickPrompt(" List the hard words. "))
        XCTAssertEqual(session.draft, "List the hard words.")
        XCTAssertTrue(provider.requests.isEmpty, "Preparing sends nothing by itself")
        // Another prompt replaces the prepared one, built-in or the reader's own.
        XCTAssertTrue(session.applyQuickPrompt("Who is speaking?"))
        XCTAssertEqual(session.draft, "Who is speaking?")
        session.prepareSelectionPrompt(.explain)
        XCTAssertEqual(session.draft, "Explain this passage.")
        XCTAssertTrue(session.applyQuickPrompt("Who is speaking?"))
        session.send(settings: settings) { XCTFail("Use the selected passage"); return nil }
        try await eventually { provider.requests.count == 1 }
        XCTAssertEqual(session.messages.first?.text, "Who is speaking?"); XCTAssertEqual(session.messages.first?.context, context)
        XCTAssertEqual(session.draft, ""); XCTAssertNil(session.selectedContext)
        // While a reply is arriving the next prompt waits as a draft.
        session.attachSelection(context)
        XCTAssertFalse(session.applyQuickPrompt("List the hard words."))
        XCTAssertEqual(session.draft, "List the hard words."); XCTAssertEqual(provider.requests.count, 1)
        complete(provider); try await eventually { !session.isSending }
        // What the reader typed goes first, and the prompt is not added twice.
        session.draft = "Why did they leave?"
        XCTAssertTrue(session.applyQuickPrompt("List the hard words."))
        XCTAssertEqual(session.draft, "Why did they leave?\n\nList the hard words.")
        XCTAssertTrue(session.applyQuickPrompt("Who is speaking?"))
        XCTAssertEqual(session.draft, "Why did they leave?\n\nWho is speaking?")
        XCTAssertTrue(session.applyQuickPrompt("Who is speaking?"))
        XCTAssertEqual(session.draft, "Why did they leave?\n\nWho is speaking?")
        session.send(settings: settings) { XCTFail("Use the selected passage"); return nil }
        try await eventually { provider.requests.count == 2 }
        XCTAssertEqual(session.messages.last(where: { $0.isUser })?.text, "Why did they leave?\n\nWho is speaking?")
        XCTAssertEqual(session.draft, ""); XCTAssertNil(session.selectedContext)
        complete(provider); try await eventually { !session.isSending }
    }
    func testQuickPromptsFollowThePassageLanguageUntilRewrittenAndAreSaved() throws {
        let suite = "ChatQuickPrompts.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        func store() -> AISettingsStore { AISettingsStore(defaults: defaults, credentials: HistoryCredentials()) }
        let settings = store()
        XCTAssertEqual(settings.quickPrompts, ChatQuickPrompt.defaults)
        settings.saveQuickPrompts(ChatQuickPrompt.defaults)
        XCTAssertNil(defaults.object(forKey: "chat.quickPrompts"), "A list that was never edited stores nothing")
        XCTAssertEqual(settings.quickPrompts.map(\.label), ["Explain", "Summarize"])
        XCTAssertEqual(settings.quickPrompts.map { $0.text(for: "A passage") }, ["Explain this passage.", "Summarize this passage."])
        XCTAssertEqual(settings.quickPrompts.map { $0.text(for: "选中文字") }, ["请解释这段文字。", "请总结这段文字。"])
        XCTAssertEqual(settings.quickPrompts.enumerated().map { $1.chipIdentifier(at: $0) }, ["explainChatSelection", "summarizeChatSelection"])

        var explain = ChatQuickPrompt.defaults[0]
        explain.title = "  解释  "; explain.prompt = " 用简单的话解释。 "
        let words = ChatQuickPrompt(title: "Words", prompt: "List the hard words.")
        let long = ChatQuickPrompt(title: String(repeating: "x", count: 40), prompt: String(repeating: "y", count: 600))
        settings.saveQuickPrompts([words, ChatQuickPrompt(title: "", prompt: "No name"), ChatQuickPrompt(title: "No request"), explain, long])
        XCTAssertEqual(settings.quickPrompts.map(\.label), ["Words", "解释", String(repeating: "x", count: 24)], "Unusable prompts are dropped; order and names are kept")
        XCTAssertEqual(settings.quickPrompts[1].text(for: "A passage"), "用简单的话解释。", "A rewritten built-in sends the reader's words in any language")
        XCTAssertEqual(settings.quickPrompts[1].chipIdentifier(at: 1), "explainChatSelection")
        XCTAssertEqual(settings.quickPrompts[0].chipIdentifier(at: 0), "customChatSelection-0")
        XCTAssertEqual(settings.quickPrompts[2].text(for: "A passage").count, 500)
        XCTAssertEqual(store().quickPrompts, settings.quickPrompts, "Prompts survive a relaunch")

        settings.saveQuickPrompts((0..<20).map { ChatQuickPrompt(title: "P\($0)", prompt: "Ask \($0)") })
        XCTAssertEqual(settings.quickPrompts.count, ChatQuickPrompt.limit)
        settings.saveQuickPrompts([])
        XCTAssertTrue(store().quickPrompts.isEmpty, "Deleting every prompt is remembered")
        settings.saveQuickPrompts(ChatQuickPrompt.defaults)
        XCTAssertEqual(defaults.data(forKey: "chat.quickPrompts"), Data(), "A reset is stored, so that sync can carry it to other devices")
        XCTAssertEqual(store().quickPrompts, ChatQuickPrompt.defaults)
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
        try await eventually { provider.requests.count == 1 }
        XCTAssertFalse(provider.requests[0].turns.contains { $0.content.contains(self.context.text) })
        XCTAssertNil(session.messages.first?.context)
        XCTAssertTrue(session.notice?.contains("sharing is off") == true)
        complete(provider); try await eventually { !session.isSending }
        XCTAssertEqual(ReaderSelectionIntent.ask.prompt(for: "选中文字"), "")
        XCTAssertEqual(ReaderSelectionIntent.explain.prompt(for: "选中文字"), "请解释这段文字。")
        XCTAssertEqual(ReaderSelectionIntent.summarize.prompt(for: "选中文字"), "请总结这段文字。")
        XCTAssertEqual(ReaderSelectionIntent.summarize.prompt(for: "A passage"), "Summarize this passage.")
        XCTAssertEqual(ReaderSelectionIntent.translate.prompt(for: "A passage"), "请把这段文字翻译成简体中文。")
        XCTAssertEqual(ReaderSelectionIntent.translate.prompt(for: "选中文字"), "Translate this passage into English.")
    }
    func testCompletedConversationAndDraftRestoreAfterClosingAndRecreatingStore() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        session.draft = "为什么？ 🌿"
        session.send(settings: settings) { self.context }
        try await eventually { provider.requests.count == 1 }
        complete(provider, "Because the passage leaves it uncertain.")
        try await eventually { !session.isSending }
        session.draft = "Follow up\nwith a detail\u{0}🌿"
        session.close()
        let restored = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(restored.messages, session.messages)
        XCTAssertEqual(restored.messages.first?.context, context)
        XCTAssertEqual(restored.draft, session.draft)
        XCTAssertNil(restored.historyError)
        restored.send(settings: settings) { self.context }
        try await eventually { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[1].turns.count, 3)
        XCTAssertTrue(provider.requests[1].turns[0].content.contains("为什么？"))
        complete(provider); try await eventually { !restored.isSending }
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
        try await eventually { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial reply"))
        try await eventually { session.messages.last?.text == "Partial reply" }
        try await Task.sleep(for: .milliseconds(650))
        let checkpoint = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(checkpoint.messages.last?.text, "Partial reply")
        XCTAssertEqual(checkpoint.messages.last?.state, .stopped)
        XCTAssertTrue(checkpoint.canRetry); XCTAssertFalse(checkpoint.isSending)
        session.stop()
        let restored = ReaderChatSession(directory: directory, conversation: "book-a")
        restored.retry(settings: settings)
        try await eventually { provider.requests.count == 2 }
        XCTAssertEqual(provider.requests[0].turns, provider.requests[1].turns)
        complete(provider, "Completed on retry"); try await eventually { !restored.isSending }
        let final = ReaderChatSession(directory: directory, conversation: "book-a")
        XCTAssertEqual(final.messages.count, 2); XCTAssertEqual(final.messages.last?.text, "Completed on retry")
    }
    func testClosingBeforeFirstTokenRetainsTheRequestAndReopensWithoutRetry() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        var presented: ReaderChatSession? = .conversation(directory: directory, id: "leaf.library.general.v1")
        weak var live = presented
        presented?.draft = "Hello"
        presented?.send(settings: settings, missingContextNotice: nil) { nil }
        // Close in the same actor turn, before even the send task starts.
        presented?.close(); presented = nil
        XCTAssertNotNil(live, "The reply must outlive the last visible panel")
        try await eventually { provider.requests.count == 1 }
        let reopened = ReaderChatSession.conversation(directory: directory, id: "leaf.library.general.v1")
        XCTAssertTrue(reopened === live); XCTAssertTrue(reopened.isSending); XCTAssertFalse(reopened.canRetry)
        XCTAssertNil(reopened.notice); XCTAssertNil(reopened.error)
        provider.continuations[0].yield(.text("Still answering"))
        try await eventually { reopened.messages.last?.text == "Still answering" }
        reopened.draft = "My next question"; reopened.close()
        complete(provider, " and finished")
        try await eventually { !reopened.isSending }
        XCTAssertEqual(provider.requests.count, 1); XCTAssertEqual(reopened.messages.count, 2)
        XCTAssertEqual(reopened.messages.last?.state, .complete)
        let saved = ReaderChatSession(directory: directory, conversation: "leaf.library.general.v1")
        XCTAssertEqual(saved.messages.last?.text, "Still answering and finished")
        XCTAssertEqual(saved.messages.last?.state, .complete); XCTAssertEqual(saved.draft, "My next question")
    }
    func testLibraryDiscoverAndReaderShareTheActiveBookConversation() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let book = Book(id: UUID(), title: "A Book", author: "Author", fileName: "book.txt", format: .txt, fingerprint: "shared-book")
        let library = TabChat(); library.open(book, directory: directory)
        let original = try XCTUnwrap(library.session)
        original.attachSelection(context); original.draft = "Explain this quote"
        original.send(settings: settings) { XCTFail("Reuse the attached quote"); return nil }
        try await eventually { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial"))
        try await eventually { original.messages.last?.text == "Partial" }
        library.close()
        let discover = TabChat(); discover.open(book, directory: directory)
        let reader = ReaderChatSession.conversation(directory: directory, id: book.fingerprint)
        XCTAssertTrue(discover.session === original && reader === original)
        XCTAssertTrue(reader.isSending); XCTAssertFalse(reader.canRetry)
        complete(provider, " answer"); try await eventually { !reader.isSending }
        XCTAssertEqual(provider.requests.count, 1); XCTAssertEqual(reader.messages.count, 2)
        XCTAssertEqual(reader.messages.first?.context, context); XCTAssertEqual(reader.messages.last?.text, "Partial answer")
    }
    func testClosingKeepsTheChosenBookAndRemovingItDoesNotOpenChat() throws {
        let directory = try directory()
        let book = Book(id: UUID(), title: "A Book", author: "Author", fileName: "book.txt", format: .txt, fingerprint: "chosen-book")
        let chat = TabChat(); chat.open(book, directory: directory)
        chat.session?.draft = "Saved book draft"; chat.close()
        XCTAssertNil(chat.session); XCTAssertEqual(chat.book?.fingerprint, book.fingerprint)
        chat.open(chat.book, directory: directory)
        XCTAssertEqual(chat.session?.draft, "Saved book draft")
        chat.close(); chat.booksChanged([], directory: directory)
        XCTAssertNil(chat.session); XCTAssertNil(chat.book)
        chat.open(chat.book, directory: directory)
        XCTAssertEqual(chat.conversation, "general"); XCTAssertEqual(chat.session?.draft, "")
    }
    func testClearCannotBeUndoneByLateReplyOrPendingDraftCheckpoint() async throws {
        let directory = try directory(), provider = HistoryProvider(), settings = settings(provider)
        let session = ReaderChatSession(directory: directory, conversation: "book-a")
        session.draft = "Explain this"; session.send(settings: settings) { self.context }
        try await eventually { provider.requests.count == 1 }
        provider.continuations[0].yield(.text("Partial reply"))
        try await eventually { session.messages.last?.text == "Partial reply" }
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
        try await eventually { provider.requests.count == 1 }
        XCTAssertTrue(provider.requests[0].turns.contains(where: { $0.content == "Message 59" }))
        XCTAssertFalse(provider.requests[0].turns.contains(where: { $0.content == "Message 20" }))
        XCTAssertLessThanOrEqual(provider.requests[0].turns.count, 12)
        complete(provider); try await eventually { !session.isSending }
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
        try await eventually { !session.isSending }
        XCTAssertTrue(provider.requests.isEmpty); XCTAssertTrue(session.messages.isEmpty)
        XCTAssertEqual(session.draft, "Preserve this question"); XCTAssertNotNil(session.historyError)
        history.fails = false; XCTAssertTrue(session.flush()); XCTAssertNil(session.historyError)
        session.send(settings: settings) { self.context }
        try await eventually { provider.requests.count == 1 }
        complete(provider); try await eventually { !session.isSending }
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
