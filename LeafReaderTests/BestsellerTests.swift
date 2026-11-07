import XCTest
import WebKit
@testable import LeafReader

private final class BestsellerCredentials: ChatCredentialStore {
    var values: [String: String] = [:]
    var locked = false
    func read(account: String) throws -> String? { if locked { throw BestsellerFeedError.unavailable }; return values[account] }
    func write(_ key: String?, account: String) throws { if locked { throw BestsellerFeedError.unavailable }; values[account] = key }
}
private final class BestsellerURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw BestsellerFeedError.unavailable }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor BestsellerService: BestsellerServing {
    var calls = 0
    var fail = false
    var delay: UInt64 = 0
    func configure(fail: Bool = false, delay: UInt64 = 0) { self.fail = fail; self.delay = delay }
    func lists(source: BestsellerSource, apiKey: String?) async throws -> [BestsellerList] {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fail { throw BestsellerFeedError.unavailable }
        return BestsellerGenre.allCases.map { genre in
            BestsellerList(source: source, genre: genre, published: "2026-11-04", fetchedAt: Date(), books: [entry(source: source, genre: genre)])
        }
    }
}

private func entry(source: BestsellerSource = .indie, genre: BestsellerGenre = .nonfiction, title: String = "The Test Book", author: String = "Test Author", isbns: [String] = ["9780593234174"], rank: Int = 1) -> BestsellerBook {
    BestsellerBook(source: source, genre: genre, rank: rank, title: title, author: author, summary: "A source-supplied description.", isbns: isbns, sourceURL: URL(string: "https://www.indiebound.org/book/9780593234174")!)
}
private func edition(_ id: String = "one", title: String = "The Test Book", author: String = "Test Author", format: String = "epub", isbns: [String]? = nil) -> ZLibraryBook {
    ZLibraryBook(remoteID: id, hash: "hash" + id, title: title, author: author, fileExtension: format, size: "1 MB", language: "English", year: "2026", coverURL: nil, isbns: isbns)
}

@MainActor private final class BestsellerCatalog: ZLibraryServing {
    var query = ""
    var rows = [edition(isbns: ["9780593234174"])]
    var delay: UInt64 = 0
    var detailDelay: UInt64 = 0
    var active = 0
    var maxActive = 0
    var searches = 0
    var detailsStarted = false
    var allQueries: [String] = []
    func profile(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> ZLibraryProfile { ZLibraryProfile(name: "Fixture", remaining: 5) }
    func popular(origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> [ZLibraryBook] { rows }
    func recommended(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> [ZLibraryBook] { rows }
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage {
        searches += 1; allQueries.append(query); active += 1; maxActive = max(maxActive, active)
        defer { active -= 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let books = rows.filter { query == "visible query" || $0.isbns?.contains(query) == true || query.contains($0.title) }
        return ZLibrarySearchPage(books: books, hasMore: false)
    }
    func details(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibraryBook {
        detailsStarted = true
        if detailDelay > 0 { try? await Task.sleep(nanoseconds: detailDelay) }
        return edition(book.remoteID, title: book.title, author: book.author)
    }
    func download(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL { throw ZLibraryError.file }
}

final class BestsellerFeedTests: XCTestCase {
    private func client() -> BestsellerFeedClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BestsellerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); BestsellerURLProtocol.handler = nil }
        return BestsellerFeedClient(session: session)
    }
    private func indieHTML(missingLast: Bool = false) -> Data {
        let sections = BestsellerGenre.allCases.map { genre in
            let rows = (1...15).map { rank in
                let isbn = missingLast && rank == 15 ? "invalid" : "9780593234174"
                return "<tr><td><strong>\(rank)</strong></td><td><strong><a href='https://www.indiebound.org/buy-local/\(isbn)'>Book &amp; \(rank)</a></strong><br>Writer \(rank), Publisher, $20, 9780593234174<br>A reader&#39;s description.</td><td>1 / 2</td></tr>"
            }.joined()
            return "<table><caption>\(genre.caption)</caption><thead><tr><th>Rank</th></tr></thead><tbody>\(rows)</tbody></table>"
        }.joined()
        return Data("<strong>National \n Bestsellers for <time datetime='2026-11-04'>November 4, 2026</time></strong>\(sections)".utf8)
    }
    private func nytJSON(duplicate: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": "OK", "results": ["published_date": "2026-11-15", "books": (1...15).map { n in
            ["rank": duplicate && n == 15 ? 14 : n, "title": "Book \(n)", "author": "Writer \(n)", "primary_isbn13": "9780593234174", "description": "A description", "book_image": "https://static01.nyt.com/untrusted-image.jpg"] as [String: Any]
        }]])
    }
    func testIndieParsesBothCompleteChartsDateEntitiesAndPublisherLinks() throws {
        let lists = try BestsellerFeedClient.indie(indieHTML())
        XCTAssertEqual(lists.map(\.genre), [.fiction, .nonfiction])
        for list in lists {
            XCTAssertEqual(list.books.count, 15); XCTAssertEqual(list.published, "November 4, 2026")
            XCTAssertEqual(list.books.first?.title, "Book & 1"); XCTAssertEqual(list.books.first?.author, "Writer 1")
            XCTAssertEqual(list.books.last?.rank, 15); XCTAssertEqual(list.books.first?.summary, "A reader's description.")
            XCTAssertEqual(list.books.first?.sourceURL.host, "www.indiebound.org")
        }
    }
    func testChangedIndieMarkupCannotMasqueradeAsSuccessfulPartialList() {
        XCTAssertThrowsError(try BestsellerFeedClient.indie(indieHTML(missingLast: true)))
        XCTAssertThrowsError(try BestsellerFeedClient.indie(Data("<html>Access check</html>".utf8)))
    }
    func testIndieKeepsCoauthorsAndNameSuffixesBeforeThePublisher() throws {
        for (credits, expected) in [
            ("Writer One, Jr., Writer Two, Publisher", "Writer One, Jr., Writer Two"),
            ("Malcolm Gladwell, Little, Brown and Company", "Malcolm Gladwell"),
            ("Jacob Tierney, Rachel Reid, Little, Brown and Company", "Jacob Tierney, Rachel Reid"),
            ("Naomi Klein, Astra Taylor, Farrar, Straus and Giroux", "Naomi Klein, Astra Taylor")
        ] {
            let html = String(decoding: indieHTML(), as: UTF8.self).replacingOccurrences(of: "Writer 1, Publisher, $20", with: credits + ", $20")
            XCTAssertEqual(try BestsellerFeedClient.indie(Data(html.utf8)).first?.books.first?.author, expected)
        }
    }
    func testNYTUsesFullRankingAndPublisherArtworkAndRejectsDuplicateRanks() throws {
        let list = try BestsellerFeedClient.nyt(nytJSON(), genre: .nonfiction)
        XCTAssertEqual(list.books.count, 15); XCTAssertEqual(list.published, "2026-11-15")
        XCTAssertEqual(list.books.first?.coverURL?.host, "images.penguinrandomhouse.com")
        XCTAssertThrowsError(try BestsellerFeedClient.nyt(nytJSON(duplicate: true), genre: .fiction))
        XCTAssertThrowsError(try BestsellerFeedClient.nyt(Data("{}".utf8), genre: .fiction))
    }
    func testISBNChecksumsEquivalentEditionsAndUntrustedCoverIdentifiers() {
        XCTAssertEqual(BestsellerText.canonicalISBN("0-593-23417-0"), "9780593234174")
        XCTAssertNil(BestsellerText.isbn("9780593234175")); XCTAssertNil(BestsellerText.isbn("xxxxxxxxxx"))
        XCTAssertNil(entry(isbns: ["bad?token=private"]).coverURL)
        XCTAssertNotEqual(entry(rank: 1).id, entry(rank: 2).id)
    }
    func testOlderCatalogCachesDecodeWithoutISBNsAndDetailsPreserveThem() throws {
        let old = edition(), data = try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(ZLibraryBook.self, from: data).isbns)
        let full = edition(isbns: ["9780593234174"])
        XCTAssertEqual(old.fillingMissingDetails(from: full).isbns, full.isbns)
    }
    func testOfficialNYTRequestsUseBothCategoriesAndRequireAKeyBeforeNetworking() async throws {
        let data = try nytJSON(), client = client()
        BestsellerURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.nytimes.com")
            XCTAssertTrue(["hardcover-fiction.json", "hardcover-nonfiction.json"].contains(request.url!.lastPathComponent))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "api-key" })?.value, "fixture-key")
            return (200, data)
        }
        let lists = try await client.lists(source: .nyt, apiKey: "fixture-key")
        XCTAssertEqual(Set(lists.map(\.genre)), Set(BestsellerGenre.allCases))
        do { _ = try await client.lists(source: .nyt, apiKey: nil); XCTFail("A missing key must not send a request") }
        catch { XCTAssertEqual(error as? BestsellerFeedError, .nytKeyRequired) }
    }
    func testRejectedNYTKeysAndRateLimitsHaveCredentialFreeErrors() async throws {
        let client = client()
        for (status, expected) in [(403, BestsellerFeedError.nytKeyRejected), (429, .rateLimited)] {
            BestsellerURLProtocol.handler = { _ in (status, Data("{}".utf8)) }
            do { _ = try await client.lists(source: .nyt, apiKey: "fixture-secret"); XCTFail("Expected provider failure") }
            catch { XCTAssertEqual(error as? BestsellerFeedError, expected); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
        }
    }
}

@MainActor final class BestsellerStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "LeafBestsellers.\(UUID())", d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }; return d
    }
    func testSourceSelectionCacheAndFailedRefreshRetainTheDatedList() async {
        let d = defaults(), service = BestsellerService(), c = BestsellerCredentials()
        let store = BestsellerStore(defaults: d, credentials: c, service: service)
        await store.load(); XCTAssertEqual(store.books.count, 1)
        let first = store.selected
        await service.configure(fail: true); await store.load(force: true)
        XCTAssertEqual(store.selected, first); XCTAssertNotNil(store.error)
        store.genre = .fiction
        let reopened = BestsellerStore(defaults: d, credentials: c, service: service)
        XCTAssertEqual(reopened.genre, .fiction); XCTAssertEqual(reopened.books.count, 1)
    }
    func testKeysStayOutOfDefaultsAndDisconnectOnlyClearsNYTMetadata() async throws {
        let d = defaults(), c = BestsellerCredentials(), service = BestsellerService()
        let store = BestsellerStore(defaults: d, credentials: c, service: service)
        await store.load(); try store.saveNYTKey("fixture-private-key")
        await store.load(source: .nyt, force: true)
        XCTAssertTrue(store.nytConnected); XCTAssertEqual(store.lists.count, 4)
        XCTAssertFalse(String(describing: d.dictionaryRepresentation()).contains("fixture-private-key"))
        try store.saveNYTKey(""); XCTAssertFalse(store.nytConnected)
        XCTAssertTrue(store.lists.allSatisfy { $0.source == .indie }); XCTAssertNil(c.values["nyt-books"])
    }
    func testFutureDatedCacheIsRefreshedAndSourceSwitchCannotShowOtherChart() async {
        let d = defaults(), c = BestsellerCredentials(), service = BestsellerService()
        let cached = BestsellerList(source: .indie, genre: .nonfiction, published: "future", fetchedAt: Date().addingTimeInterval(3600), books: [entry()])
        d.set(try? JSONEncoder().encode([cached]), forKey: "bestsellers.cache.v1")
        let store = BestsellerStore(defaults: d, credentials: c, service: service)
        await store.load(); XCTAssertNotEqual(store.selected?.published, "future")
        await service.configure(delay: 80_000_000)
        let task = Task { await store.load(source: .indie, force: true) }; store.source = .nyt
        await task.value; XCTAssertTrue(store.books.isEmpty)
    }
    func testLockedKeychainDoesNotLeakAnErrorOrEraseOtherSourceCache() async {
        let d = defaults(), c = BestsellerCredentials(), service = BestsellerService()
        let store = BestsellerStore(defaults: d, credentials: c, service: service); await store.load()
        c.locked = true; await store.load(source: .nyt, force: true)
        XCTAssertNotNil(store.errors[.nyt]); XCTAssertFalse(store.lists.isEmpty)
    }
    func testExistingLibraryWorkIsRecognizedAcrossSourcesAndSubtitleDifferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let disk = try LibraryDisk(root: root)
        let owned = Book(id: UUID(), title: "The Test Book: Another subtitle", author: "Test Author", fileName: "fixture.txt", format: .txt, fingerprint: "fixture")
        try disk.save([owned]); let library = LibraryStore(root: root, seedSamples: false)
        let store = BestsellerStore(defaults: defaults(), credentials: BestsellerCredentials(), service: BestsellerService())
        XCTAssertEqual(store.existing(entry(source: .nyt), in: library)?.id, owned.id)
        XCTAssertNil(store.existing(entry(author: "Other Author"), in: library))
        XCTAssertNil(store.existing(entry(title: "The Test Book: A different volume"), in: library))
    }
    func testAskLeafReadsIndependentSearchThenReturnsToTheListOrSelectedEdition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root, seedSamples: false), d = defaults(), credentials = BestsellerCredentials()
        let store = BestsellerStore(defaults: d, credentials: credentials, service: BestsellerService())
        let catalog = ZLibraryStore(defaults: d, credentials: credentials, client: BestsellerCatalog(), discoversFromLibrary: false)
        store.showingBestsellers = true; await store.load()
        catalog.show(query: "Unrelated global search")
        store.catalogSearch = BestsellerSearchContext(query: "The Rush", books: [edition(title: "The Rush")], status: [])
        let screen = ChatScreen.discover(catalog, library: library, bestsellers: store)
        let view = screen.view(5, true)
        XCTAssertEqual(view["list"] as? String, "Search results"); XCTAssertEqual(view["search"] as? String, "The Rush")
        XCTAssertEqual((view["items"] as? [[String: Any]])?.first?["title"] as? String, "The Rush")
        let missing = try await screen.details(2, true); XCTAssertNil(missing)
        let selected = edition(title: "A selected edition"); catalog.beginViewing(selected)
        XCTAssertEqual((screen.view(5, true)["open_book"] as? [String: Any])?["title"] as? String, "A selected edition")
        catalog.endViewing(selected); store.catalogSearch = nil; catalog.show(.popular)
        XCTAssertEqual(screen.view(5, true)["list"] as? String, "Bestsellers")
    }
}

@MainActor final class BestsellerMatchingTests: XCTestCase {
    private func catalog(_ client: BestsellerCatalog) async -> ZLibraryStore {
        let name = "LeafBestsellerMatch.\(UUID())", d = UserDefaults(suiteName: name)!, c = BestsellerCredentials()
        d.set("https://catalog.example", forKey: "zlibrary.origin")
        let store = ZLibraryStore(defaults: d, credentials: c, client: client, discoversFromLibrary: false)
        let connected = await store.connect(ZLibrarySession(userID: "fixture", userKey: "test-only")); XCTAssertTrue(connected)
        addTeardownBlock {
            await Task { @MainActor in
                let saved = UserDefaults(suiteName: name)!
                for (key, value) in saved.dictionaryRepresentation() where key.hasPrefix("zlibrary.websiteData.") {
                    if let raw = value as? String, let id = UUID(uuidString: raw) {
                        await withCheckedContinuation { continuation in WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() } }
                    }
                }
                saved.removePersistentDomain(forName: name)
            }.value
        }
        return store
    }
    func testWrongAuthorsAreRejectedAndEquivalentISBNsArePreferred() {
        XCTAssertTrue(BestsellerMatching.rank(entry(), editions: [edition(author: "Other Writer")]).isEmpty)
        let ranked = BestsellerMatching.rank(entry(), editions: [edition(isbns: ["0593234170"]), edition("uncertain", author: "")])
        XCTAssertEqual(ranked.first?.confidence, .isbn)
        XCTAssertEqual(ranked.last?.confidence, .possible)
        XCTAssertNil(BestsellerMatchState.ready(ranked).automatic)
        XCTAssertNotNil(BestsellerMatchState.ready(Array(ranked.prefix(1))).automatic)
    }
    func testDuplicateEditionsCollapseButUnsupportedFilesCannotQuickAdd() {
        let book = edition(), values = BestsellerMatching.rank(entry(), editions: [book, book])
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(BestsellerMatchState.ready(BestsellerMatching.rank(entry(), editions: [edition(format: "djvu")])).automatic)
    }
    func testDifferentVolumesCannotMatchAndOmittedSubtitlesRequireInspection() {
        let work = entry(title: "A Series: The First Story", isbns: [])
        XCTAssertTrue(BestsellerMatching.rank(work, editions: [edition(title: "A Series: The Second Story")]).isEmpty)
        let partial = BestsellerMatching.rank(work, editions: [edition(title: "A Series")])
        XCTAssertEqual(partial.first?.confidence, .possible)
        XCTAssertNil(BestsellerMatchState.ready(partial).automatic)
        let exact = BestsellerMatching.rank(work, editions: [edition(title: "A SERIES: THE FIRST STORY")])
        XCTAssertNotNil(BestsellerMatchState.ready(exact).automatic)
    }
    func testMatchingDoesNotReplaceVisibleSearchOrSelectedFeed() async {
        let client = BestsellerCatalog(), store = await catalog(client)
        await store.browse(.recommended); await store.search("visible query")
        let rows = store.books, feed = store.feed, query = store.activeQuery
        let matcher = BestsellerMatching(); await matcher.resolve(entry(), catalog: store)
        XCTAssertEqual(matcher.state(for: entry())?.editions.count, 1)
        XCTAssertEqual(store.books, rows); XCTAssertEqual(store.feed, feed); XCTAssertEqual(store.activeQuery, query)
    }
    func testOneCancelledObserverDoesNotCancelAnotherObserverOfTheSameBook() async throws {
        let client = BestsellerCatalog(); client.delay = 100_000_000
        let store = await catalog(client), matcher = BestsellerMatching(), book = entry()
        let first = Task { await matcher.resolve(book, catalog: store) }
        let second = Task { await matcher.resolve(book, catalog: store) }
        try await Task.sleep(for: .milliseconds(30)); first.cancel()
        await first.value; await second.value
        XCTAssertNotNil(matcher.state(for: book)?.automatic); XCTAssertEqual(client.searches, 1)
    }
    func testDisconnectDuringSparseDetailsCannotPublishAnOldAccountMatch() async throws {
        let client = BestsellerCatalog(); client.rows = [edition(format: "", isbns: ["9780593234174"])]; client.detailDelay = 200_000_000
        let store = await catalog(client), matcher = BestsellerMatching(), book = entry()
        let task = Task { await matcher.resolve(book, catalog: store) }
        let deadline = Date().addingTimeInterval(3)
        while !client.detailsStarted && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(client.detailsStarted); try await store.disconnect(); await task.value
        XCTAssertNil(matcher.state(for: book)?.automatic); XCTAssertFalse(store.connected)
    }
    func testConcurrentVisibleBooksUseAtMostTwoLookupSlots() async {
        let client = BestsellerCatalog(); client.delay = 30_000_000
        let records = (1...8).map { entry(title: "Book \($0)", isbns: [], rank: $0) }
        client.rows = records.map { edition("book\($0.rank)", title: $0.title) }
        let store = await catalog(client), matcher = BestsellerMatching()
        await withTaskGroup(of: Void.self) { group in
            for book in records { group.addTask { await matcher.resolve(book, catalog: store) } }
            await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(client.maxActive, 2)
        XCTAssertTrue(records.allSatisfy { matcher.state(for: $0)?.automatic != nil })
    }
}
