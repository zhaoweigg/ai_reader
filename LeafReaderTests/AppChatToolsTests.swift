import XCTest
@testable import LeafReader

private final class SavedTextSource: BookTextSource {
    let sections: [BookTextSection]
    init(_ sections: [BookTextSection]) { self.sections = sections }
    func bookSectionCount() async throws -> Int { sections.count }
    func bookSectionText(_ index: Int) async throws -> BookTextSection { sections[index] }
    func bookBoundary(for locator: String) async throws -> BookTextBoundary? { nil }
}

private actor ChartService: BestsellerServing {
    var calls = 0
    func lists(source: BestsellerSource, apiKey: String?) async throws -> [BestsellerList] {
        calls += 1
        return BestsellerGenre.allCases.map { genre in
            BestsellerList(source: source, genre: genre, published: "2026-11-08", fetchedAt: Date(), books: [
                BestsellerBook(source: source, genre: genre, rank: 1, title: "Chart \(genre.title)", author: "Writer", summary: "A charted book.",
                               isbns: [], sourceURL: URL(string: "https://example.org/chart")!)])
        }
    }
}

@MainActor final class AppChatToolsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "LeafAppTools.\(UUID())", d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }; return d
    }
    private func credentials() -> KeychainChatCredentials { KeychainChatCredentials(service: "com.leafreader.tests.\(UUID())") }
    private func object(_ output: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
    /// Prepares and saves a book's text the way the reader does when Ask Leaf opens in it.
    private func save(_ sections: [String], for book: Book, root: URL, boundary: BookTextBoundary, progress: Double) async throws {
        let source = SavedTextSource(sections.enumerated().map { BookTextSection(label: "第\($0 + 1)章", text: $1) })
        let index = BookTextIndex(source: source, directory: root.appendingPathComponent("ChatIndex/\(book.fingerprint)/v1", isDirectory: true))
        _ = try await index.prepare(through: boundary, deadline: .distantFuture)
        index.savePosition(locator: book.locator, progress: progress, boundary: boundary)
    }
    private func app() async throws -> (ChatAppData, ChartService, open: Book) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        func book(_ title: String, _ fingerprint: String, locator: String, progress: Double, opened: Double?) -> Book {
            var book = Book(id: UUID(), title: title, author: "Author \(title)", fileName: "\(fingerprint).epub", format: .epub, fingerprint: fingerprint)
            book.locator = locator; book.progress = progress; book.lastOpenedAt = opened.map(Date.init(timeIntervalSince1970:))
            return book
        }
        let open = book("Open", "fp-open", locator: "loc-open", progress: 0.5, opened: 400)
        var read = book("Read", "fp-read", locator: "loc-read", progress: 0.4, opened: 300)
        read.isFavorite = true
        read.annotations = [BookAnnotation(text: "白虎守着城门。", locator: "a1", chapter: "第一章", fraction: 0.1)]
        read.bookmarks = [BookBookmark(label: "The gate", locator: "b1", fraction: 0.2)]
        var moved = book("Moved back", "fp-moved", locator: "loc-moved-earlier", progress: 0.1, opened: 200)
        let fresh = book("Unopened", "fp-fresh", locator: "", progress: 0, opened: nil)
        var finished = book("Finished", "fp-done", locator: "loc-done", progress: 1, opened: 100)
        finished.annotations = [BookAnnotation(text: "Another passage", locator: "a2", chapter: "End", fraction: 0.9, note: "Private thought")]
        try disk.save([open, read, moved, fresh, finished])
        try await save(["白虎守门。", "白虎回来了。FUTURE 白虎秘密"], for: read, root: root, boundary: BookTextBoundary(section: 1, offset: 6), progress: 0.4)
        // Saved when the reader was further on; they have since gone back to 10%.
        moved.locator = "loc-moved-later"
        try await save(["白虎很远。"], for: moved, root: root, boundary: BookTextBoundary(section: 0, offset: 5), progress: 0.3)
        try await save(["白虎在开着的书里。"], for: open, root: root, boundary: BookTextBoundary(section: 0, offset: 9), progress: 0.5)
        let library = LibraryStore(root: root, seedSamples: false)
        let service = ChartService()
        let bestsellers = BestsellerStore(defaults: defaults(), credentials: credentials(), service: service, allowsAutomaticShelf: false)
        let catalog = ZLibraryStore(defaults: defaults(), credentials: credentials(), client: UITestZLibraryClient(), discoversFromLibrary: false)
        return (ChatAppData(catalog: catalog, bestsellers: bestsellers, library: library, openBook: open.id), service, open)
    }

    func testOtherBooksAreSearchedOnlyUpToWhereTheReaderStopped() async throws {
        let (data, _, _) = try await app()
        let toolbox = ReadingAgentToolbox(book: nil, app: data) { _ in "{}" }
        XCTAssertTrue(toolbox.tools.contains { $0.name == "search_my_books" })
        let body = try object(try await toolbox.run(AgentToolCall(id: "1", name: "search_my_books", arguments: #"{"terms":["白虎"]}"#)))
        let results = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["book"] as? String }, ["Read", "Read"], "The open book is search_book's; a moved-back book is not searched")
        XCTAssertFalse(results.contains { ($0["text"] as? String ?? "").contains("FUTURE") || ($0["text"] as? String ?? "").contains("秘密") })
        XCTAssertEqual(body["books_not_searchable"] as? [String], ["Moved back", "Finished"])
        XCTAssertEqual((body["books_searched"] as? [[String: Any]])?.first?["searched_to_percent"] as? Int, 40)
        XCTAssertEqual(toolbox.steps, ["searched your books for “白虎” (2)"])

        // Book text needs passage sharing; the tool is not offered without it.
        toolbox.sharePassages = false
        XCTAssertFalse(toolbox.tools.contains { $0.name == "search_my_books" })
        let refused = try await toolbox.run(AgentToolCall(id: "2", name: "search_my_books", arguments: #"{"terms":["白虎"]}"#))
        XCTAssertTrue(refused.contains("passage sharing"))
    }

    func testLibraryAndSavedPlacesAreListedAndPassagesFollowSharing() async throws {
        let (data, _, _) = try await app()
        let toolbox = ReadingAgentToolbox(book: nil, app: data) { _ in "{}" }
        let reading = try object(try await toolbox.run(AgentToolCall(id: "1", name: "list_library", arguments: #"{"status":"reading"}"#)))
        XCTAssertEqual((reading["items"] as? [[String: Any]])?.map { $0["title"] as? String }, ["Open", "Read", "Moved back"])
        let favorites = try object(try await toolbox.run(AgentToolCall(id: "2", name: "list_library", arguments: #"{"status":"favorites"}"#)))
        XCTAssertEqual((favorites["items"] as? [[String: Any]])?.first?["title"] as? String, "Read")

        let found = try object(try await toolbox.run(AgentToolCall(id: "3", name: "search_saved", arguments: #"{"terms":["城门"]}"#)))
        XCTAssertEqual((found["items"] as? [[String: Any]])?.map { $0["text"] as? String }, ["白虎守着城门。"])
        let notes = try object(try await toolbox.run(AgentToolCall(id: "4", name: "search_saved", arguments: #"{"kind":"notes"}"#)))
        XCTAssertEqual((notes["items"] as? [[String: Any]])?.first?["note"] as? String, "Private thought")

        toolbox.sharePassages = false
        let hidden = try await toolbox.run(AgentToolCall(id: "5", name: "search_saved", arguments: #"{"terms":["城门"]}"#))
        XCTAssertEqual(try object(hidden)["total_items"] as? Int, 0, "Highlighted text is not searched when it may not be shared")
        let listed = try await toolbox.run(AgentToolCall(id: "6", name: "search_saved", arguments: "{}"))
        XCTAssertFalse(listed.contains("Private thought") || listed.contains("白虎守着城门"))
        XCTAssertTrue(listed.contains("The gate"))
    }

    func testBestsellersLoadWhenTheScreenNeverDid() async throws {
        let (data, service, _) = try await app()
        XCTAssertTrue(data.bestsellers.lists.isEmpty, "Nothing is loaded before the question")
        let toolbox = ReadingAgentToolbox(book: nil, app: data) { _ in "{}" }
        let body = try object(try await toolbox.run(AgentToolCall(id: "1", name: "get_bestsellers", arguments: #"{"source":"nyt","category":"fiction"}"#)))
        XCTAssertEqual((body["items"] as? [[String: Any]])?.first?["title"] as? String, "Chart Fiction")
        XCTAssertEqual(body["list_date"] as? String, "2026-11-08")
        _ = try await toolbox.run(AgentToolCall(id: "2", name: "get_bestsellers", arguments: #"{"source":"nyt","category":"nonfiction"}"#))
        let calls = await service.calls
        XCTAssertEqual(calls, 1, "A list loaded once is reused")
        let unknown = try await toolbox.run(AgentToolCall(id: "3", name: "get_catalog_book", arguments: #"{"book_id":"nope"}"#))
        XCTAssertTrue(unknown.contains("Unknown book_id"))
    }

    func testEveryChatOffersAppToolsAndDescribesThem() async throws {
        let (data, _, _) = try await app()
        let screen = ChatScreen(name: "Library", view: { _, _ in [:] }, details: { _, _ in nil })
        let names = ReadingAgentToolbox(book: nil, screen: screen, app: data) { _ in "{}" }.tools.map(\.name)
        XCTAssertEqual(names, ["search_conversation", "get_current_view", "get_item_details"] + AgentTool.app.map(\.name))
        let request = ChatRequest.conversation([ReaderChatMessage(isUser: true, text: "What is popular?")], appTools: true, screen: "Library")
        XCTAssertTrue(request.system.contains("get_catalog_feed") && request.system.contains("search_my_books"))
    }
}
