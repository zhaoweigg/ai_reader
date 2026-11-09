import XCTest
import WebKit
@testable import LeafReader

private final class CatalogCredentials: ChatCredentialStore {
    var values: [String:String] = [:]
    var failWrites = false
    var failReads = false
    func read(account:String) throws -> String? { if failReads { throw ZLibraryError.file }; return values[account] }
    func write(_ key:String?,account:String) throws { if failWrites { throw ZLibraryError.file }; values[account] = key }
}
private final class CatalogTransport: ZLibraryTransport {
    var requests: [URLRequest] = []
    var handler: (URLRequest,Bool) throws -> ZLibraryPayload
    init(_ handler:@escaping (URLRequest,Bool) throws -> ZLibraryPayload) { self.handler = handler }
    func send(_ request:URLRequest,toFile:Bool,progress:@escaping @Sendable (Double?)->Void) async throws -> ZLibraryPayload {
        requests.append(request);return try handler(request,toFile)
    }
}
@MainActor private final class CatalogService: ZLibraryServing {
    var profileError: Error?
    var downloadError: Error?
    var profiles = 0
    var downloads = 0
    var suspendProfile = false
    var continuation: CheckedContinuation<ZLibraryProfile,Error>?
    var remaining: Int? = 3
    var file: URL?
    var suspendPopular = false
    var popularError: Error?
    var popularSessions: [ZLibrarySession?] = []
    var popularContinuation: CheckedContinuation<[ZLibraryBook],Error>?
    var popularBooks: [ZLibraryBook] = []
    var recommendedSessions: [ZLibrarySession] = []
    var recommendedBooks: [ZLibraryBook] = []
    var recommendedHandler: (() async throws -> [ZLibraryBook])?
    var detailCalls = 0
    var detailHandler: ((ZLibraryBook) async throws -> ZLibraryBook)?
    var searchCalls: [(String, Int, ZLibrarySession?, ZLibrarySearchOrder)] = []
    var searchHandler: ((String, Int) async throws -> ZLibrarySearchPage)?
    var orderedSearchHandler: ((String, Int, ZLibrarySearchOrder) async throws -> ZLibrarySearchPage)?
    func profile(origin:ZLibraryOrigin,session:ZLibrarySession) async throws -> ZLibraryProfile {
        profiles += 1
        if suspendProfile { return try await withCheckedThrowingContinuation { continuation = $0 } }
        if let profileError { throw profileError }
        return ZLibraryProfile(name:"Test reader",remaining:remaining)
    }
    func popular(origin:ZLibraryOrigin,session:ZLibrarySession?) async throws -> [ZLibraryBook] {
        popularSessions.append(session)
        if suspendPopular { return try await withCheckedThrowingContinuation { popularContinuation = $0 } }
        if let popularError { throw popularError }
        return popularBooks
    }
    func recommended(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> [ZLibraryBook] {
        recommendedSessions.append(session)
        return try await recommendedHandler?() ?? recommendedBooks
    }
    func details(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibraryBook {
        detailCalls += 1
        return try await detailHandler?(book) ?? book
    }
    func download(_ book:ZLibraryBook,origin:ZLibraryOrigin,session:ZLibrarySession,progress:@escaping @Sendable (Double?)->Void) async throws -> URL {
        downloads += 1;if let downloadError { throw downloadError };guard let file else { throw ZLibraryError.file };return file
    }
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage {
        searchCalls.append((query, page, session, order))
        if let orderedSearchHandler { return try await orderedSearchHandler(query,page,order) }
        return try await searchHandler?(query, page) ?? ZLibrarySearchPage(books: [], hasMore: false)
    }
}
private final class CatalogURLProtocol: URLProtocol {
    static var body = Data()
    static var expected: Int?
    static var remainOpen = false
    static var stopped = false
    static var onStop: (() -> Void)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        var headers = ["Content-Type":"application/octet-stream"]
        if let expected = Self.expected { headers["Content-Length"] = "\(expected)" }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed)
        for start in stride(from:0,to:Self.body.count,by:65536) {
            client?.urlProtocol(self,didLoad:Self.body.subdata(in:start..<min(start+65536,Self.body.count)))
        }
        if !Self.remainOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.stopped = true; Self.onStop?() }
}

@MainActor final class ZLibraryTests: XCTestCase {
    private let session = ZLibrarySession(userID:"42",userKey:"test-only-session")
    private var origin: ZLibraryOrigin { try! ZLibraryOrigin("https://catalog.example") }
    private var book: ZLibraryBook { ZLibraryBook(remoteID:"12",hash:"ab1234",title:"A test book",author:"Test author",fileExtension:"epub",size:"1 MB",language:"English",year:"1900",coverURL:nil) }
    private func response(_ value:Any,url:URL?=nil,status:Int=200) throws -> ZLibraryPayload {
        ZLibraryPayload(data:try JSONSerialization.data(withJSONObject:value),file:nil,response:HTTPURLResponse(url:url ?? origin.url,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
    private func store(_ client:(any ZLibraryServing)? = nil) -> (ZLibraryStore,CatalogCredentials,UserDefaults) {
        let name = "LeafZLibraryTests.\(UUID())", credentials = CatalogCredentials()
        nonisolated(unsafe) let defaults = UserDefaults(suiteName:name)!
        addTeardownBlock {
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("zlibrary.websiteData.") {
                if let raw = value as? String, let id = UUID(uuidString: raw) {
                    await Task { @MainActor in
                        await withCheckedContinuation { continuation in
                            WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
                        }
                    }.value
                }
            }
            defaults.removePersistentDomain(forName:name)
        }
        defaults.set(origin.url.absoluteString,forKey:"zlibrary.origin")
        return (ZLibraryStore(defaults:defaults,credentials:credentials,client:client ?? CatalogService()),credentials,defaults)
    }
    func testAddressesAndSessionValuesRejectCredentialInjection() throws {
        XCTAssertEqual(try ZLibraryOrigin(" https://CATALOG.example/ ").url.absoluteString,"https://catalog.example")
        for value in ["http://catalog.example","https://user:pass@catalog.example","https://catalog.example/login","https://catalog.example?a=b","https://127.0.0.1","https://localhost","https://catalog.local","https://catalog.example:443","https://catalog.example/#token"] {
            XCTAssertThrowsError(try ZLibraryOrigin(value),value)
        }
        XCTAssertFalse(ZLibrarySession(userID:"42",userKey:"secret; other=token").valid)
        XCTAssertFalse(ZLibrarySession(userID:"42\r\nHeader",userKey:"secret").valid)
        XCTAssertTrue(session.valid)
    }
    func testMostPopularUsesGETAndParsesDeduplicatedEditionsWithoutSearch() async throws {
        let row: [String:Any] = ["id":12,"hash":"ab1234","title":"A book","author":"Author","extension":"EPUB","filesizeString":"1 MB","language":"English","cover":"https://images.example/cover.jpg"]
        let transport = CatalogTransport { [self] request,toFile in
            XCTAssertFalse(toFile);XCTAssertEqual(request.httpMethod,"GET")
            XCTAssertEqual(request.url?.path,"/eapi/book/most-popular");XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField:"remix-userkey"),session.userKey)
            return try response(["success":1,"books":[row,row,["id":"../evil","hash":"a","title":"Bad"]]])
        }
        let books = try await ZLibraryClient(transport:transport).popular(origin:origin,session:session)
        XCTAssertEqual(books.count,1);XCTAssertEqual(books[0].format,.epub);XCTAssertEqual(books[0].size,"1 MB")
        XCTAssertEqual(books[0].coverURL?.host,"images.example")
    }
    func testRecommendationsUseAuthenticatedGETAndKeepProviderOrderAndMetadataBounded() async throws {
        let rows: [[String: Any]] = (1...205).map { ["id": $0, "hash": "abc123", "title": "Book \($0)", "extension": "epub", "filesizeString": "2 MB", "rating": 4.5] }
        let transport = CatalogTransport { [self] request, toFile in
            XCTAssertFalse(toFile); XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/eapi/user/book/recommended")
            XCTAssertNil(request.url?.query); XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "remix-userkey"), session.userKey)
            return try response(["success": 1, "books": [rows[0]] + rows])
        }
        let client = ZLibraryClient(transport: transport)
        let books = try await client.recommended(origin: origin, session: session)
        XCTAssertEqual(books.count, 199) // Only the first 200 rows are parsed, including the duplicate.
        XCTAssertEqual(books.last?.remoteID, "199")
        XCTAssertEqual(books.prefix(2).map(\.remoteID), ["1", "2"])
        XCTAssertEqual(books.first?.size, "2 MB"); XCTAssertEqual(books.first?.rating, 4.5)
        do {
            _ = try await client.recommended(origin: origin, session: ZLibrarySession(userID: "", userKey: ""))
            XCTFail("Invalid accounts must not request personalized data")
        } catch { XCTAssertEqual(error as? ZLibraryError, .signInRequired) }
        XCTAssertEqual(transport.requests.count, 1)
        transport.handler = { [self] _, _ in try response(["success": 1, "books": "invalid"]) }
        do { _ = try await client.recommended(origin: origin, session: session); XCTFail("Malformed recommendations are not an empty feed") }
        catch { XCTAssertEqual(error as? ZLibraryError, .response) }
    }
    func testRecommendationsRequireConnectionAndRestoreSelectedFeedAfterRelaunch() async throws {
        let client = CatalogService(), (store, credentials, defaults) = store(client)
        client.recommendedBooks = [book]
        await store.browse(.recommended)
        XCTAssertEqual(store.feed, .recommended); XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(store.error); XCTAssertTrue(store.recommendationConnectionRequired)
        XCTAssertTrue(client.recommendedSessions.isEmpty); XCTAssertTrue(client.popularSessions.isEmpty)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        await store.reload()
        XCTAssertEqual(store.books, [book]); XCTAssertNil(store.error)
        XCTAssertEqual(client.recommendedSessions, [session])
        let reopened = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        XCTAssertEqual(reopened.feed, .recommended)
        await reopened.search("")
        XCTAssertEqual(reopened.books, [book]); XCTAssertTrue(reopened.connected)
        XCTAssertEqual(client.recommendedSessions.count, 2); XCTAssertTrue(client.popularSessions.isEmpty)
    }
    func testShelfShowsPopularWithoutAccountRecommendationsWithOneAndRestoresOnlyForThatAccount() async throws {
        let client = CatalogService(), (store, credentials, defaults) = store(client)
        let other = ZLibraryBook(remoteID:"77",hash:"cd5678",title:"Recommended book",author:"",fileExtension:"epub",size:"",language:"",year:"",coverURL:nil)
        client.popularBooks = [book]; client.recommendedBooks = [other]
        await store.loadShelf()
        XCTAssertEqual(store.shelf, [book]); XCTAssertEqual(store.shelfFeed, .popular)
        await store.loadShelf() // Reopening the library reuses the shelf.
        XCTAssertEqual(client.popularSessions.count, 1)
        XCTAssertEqual(store.books, []); XCTAssertEqual(store.activeQuery, "")
        let connected = await store.connect(session); XCTAssertTrue(connected)
        XCTAssertTrue(store.shelf.isEmpty)
        await store.loadShelf()
        XCTAssertEqual(store.shelf, [other]); XCTAssertEqual(store.shelfFeed, .recommended)
        XCTAssertEqual(client.recommendedSessions, [session])
        let reopened = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        XCTAssertEqual(reopened.shelf, [other]); XCTAssertEqual(reopened.shelfFeed, .recommended)
        try await store.disconnect()
        XCTAssertTrue(store.shelf.isEmpty)
        XCTAssertTrue(ZLibraryStore(defaults: defaults, credentials: credentials, client: client).shelf.isEmpty)
    }
    /// The Library loads a saved account's recommendations without visiting
    /// Discover, so `connected` is still false. An empty answer must still count
    /// as a finished recommendations load, or the Library hides the empty state.
    func testEmptyRecommendationsFromASavedSessionCountAsLoaded() async throws {
        let client = CatalogService(), (store, credentials, defaults) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.recommendedBooks = []
        let reopened = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        XCTAssertFalse(reopened.hasCurrentRecommendations)
        await reopened.loadShelf()
        XCTAssertTrue(reopened.shelf.isEmpty); XCTAssertNil(reopened.shelfError); XCTAssertFalse(reopened.shelfLoading)
        XCTAssertEqual(reopened.shelfFeed, .recommended); XCTAssertFalse(reopened.connected)
        XCTAssertTrue(reopened.hasCurrentRecommendations)
        let (anonymous, _, _) = self.store(client)
        client.popularBooks = []
        await anonymous.loadShelf()
        XCTAssertEqual(anonymous.shelfFeed, .popular); XCTAssertFalse(anonymous.hasCurrentRecommendations, "An empty public feed is not a recommendations answer")
        try await reopened.disconnect()
        XCTAssertFalse(reopened.hasCurrentRecommendations, "Disconnecting forgets the finished load")
    }
    func testShelfReusesDiscoverListAndShowsThrottledFailure() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        client.popularBooks = [book]
        await store.loadPopular(); await store.loadShelf()
        XCTAssertEqual(store.shelf, [book]); XCTAssertEqual(client.popularSessions.count, 1)
        let (failing, _, _) = self.store(client)
        client.popularError = ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        await failing.loadShelf(); await failing.loadShelf()
        XCTAssertTrue(failing.shelf.isEmpty); XCTAssertNil(failing.error); XCTAssertNotNil(failing.shelfError)
        XCTAssertFalse(failing.shelfLoading)
        XCTAssertEqual(client.popularSessions.count, 2)
    }
    func testShelfContextChangesForReconnectAndOriginEvenWhenConnectedFlagIsUnchanged() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        client.recommendedBooks = [book]
        let first = await store.connect(session); XCTAssertTrue(first)
        await store.loadShelf(); let before = store.shelfContext
        let again = await store.connect(session); XCTAssertTrue(again); XCTAssertTrue(store.connected)
        XCTAssertNotEqual(store.shelfContext, before); XCTAssertTrue(store.shelf.isEmpty)
        await store.loadShelf(); XCTAssertEqual(store.shelf, [book]); XCTAssertEqual(client.recommendedSessions.count, 2)
        let accountContext = store.shelfContext
        try await store.changeAddress("https://other.example")
        XCTAssertNotEqual(store.shelfContext, accountContext); XCTAssertEqual(store.shelfContext.origin.host, "other.example")
        XCTAssertTrue(store.shelf.isEmpty); XCTAssertNil(store.shelfError)
    }
    func testFailedShelfCanRetryImmediatelyWithoutChangingTheVisibleDiscoverSearch() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.searchHandler = { [self] _, _ in ZLibrarySearchPage(books: [book], hasMore: true) }
        await store.search("keep this query")
        client.recommendedHandler = { throw ZLibraryError.response }
        await store.loadShelf(); await store.loadShelf()
        XCTAssertNotNil(store.shelfError); XCTAssertNil(store.error); XCTAssertTrue(store.connected)
        XCTAssertEqual(client.recommendedSessions.count, 1); XCTAssertFalse(store.shelfLoading)
        client.recommendedHandler = nil; client.recommendedBooks = [book]
        await store.loadShelf(force: true)
        XCTAssertEqual(store.shelf, [book]); XCTAssertNil(store.shelfError); XCTAssertEqual(client.recommendedSessions.count, 2)
        XCTAssertEqual(store.activeQuery, "keep this query"); XCTAssertEqual(store.books, [book]); XCTAssertTrue(store.canLoadMore)
    }
    func testFailedShelfKeepsCachedBooksAndRetriesAfterCooldown() async throws {
        let client = CatalogService(), (_, credentials, defaults) = store(client)
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ZLibraryStore(defaults: defaults, credentials: credentials, client: client, now: { time })
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.recommendedBooks = [book]; await store.loadShelf()
        client.recommendedHandler = { throw ZLibraryError.response }
        await store.loadShelf(force: true)
        XCTAssertEqual(store.shelf, [book]); XCTAssertNotNil(store.shelfError)
        await store.loadShelf(); XCTAssertEqual(client.recommendedSessions.count, 2)
        let newer = ZLibraryBook(remoteID: "fresh", hash: "fresh", title: "Fresh recommendations", author: "Author", fileExtension: "epub", size: "", language: "", year: "", coverURL: nil)
        time = time.addingTimeInterval(31); client.recommendedHandler = nil; client.recommendedBooks = [newer]
        await store.loadShelf()
        XCTAssertEqual(store.shelf, [newer]); XCTAssertNil(store.shelfError); XCTAssertEqual(client.recommendedSessions.count, 3)
        XCTAssertFalse(store.shelfLoading)
    }
    func testExplicitShelfRefreshBypassesDiscoverSnapshotWithoutReplacingIt() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.recommendedBooks = [book]; await store.browse(.recommended)
        XCTAssertEqual(store.shelf, [book])
        let newer = ZLibraryBook(remoteID: "fresh", hash: "fresh", title: "Fresh recommendations", author: "Author", fileExtension: "epub", size: "", language: "", year: "", coverURL: nil)
        client.recommendedBooks = [newer]; await store.loadShelf(force: true)
        XCTAssertEqual(store.shelf, [newer]); XCTAssertEqual(store.books, [book]); XCTAssertEqual(client.recommendedSessions.count, 2)
        await store.browse(.recommended)
        XCTAssertEqual(store.books, [book]); XCTAssertEqual(store.shelf, [newer]); XCTAssertEqual(client.recommendedSessions.count, 2)
    }
    func testSuccessfulDiscoverRefreshRepairsShelfAndRejectsAnOlderShelfResponse() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.recommendedHandler = { throw ZLibraryError.response }; await store.loadShelf()
        XCTAssertNotNil(store.shelfError)
        var held: CheckedContinuation<[ZLibraryBook], Error>?
        let requested = expectation(description: "Shelf request started")
        client.recommendedHandler = { try await withCheckedThrowingContinuation { held = $0; requested.fulfill() } }
        let pending = Task { await store.loadShelf(force: true) }
        await fulfillment(of: [requested], timeout: 10)
        let response = try XCTUnwrap(held)
        let newer = ZLibraryBook(remoteID: "fresh", hash: "fresh", title: "Fresh recommendations", author: "Author", fileExtension: "epub", size: "", language: "", year: "", coverURL: nil)
        client.recommendedHandler = nil; client.recommendedBooks = [newer]
        await store.browse(.recommended)
        XCTAssertEqual(store.shelf, [newer]); XCTAssertNil(store.shelfError); XCTAssertFalse(store.shelfLoading)
        response.resume(returning: [book]); await pending.value
        XCTAssertEqual(store.shelf, [newer]); XCTAssertEqual(store.books, [newer]); XCTAssertFalse(store.shelfLoading)
    }
    func testReconnectionRejectsLateShelfDataFromPreviousAccount() async throws {
        let client = CatalogService(), (store, _, defaults) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        var held: CheckedContinuation<[ZLibraryBook], Error>?
        let requested = expectation(description: "Previous account shelf started")
        client.recommendedHandler = { try await withCheckedThrowingContinuation { held = $0; requested.fulfill() } }
        let pending = Task { await store.loadShelf() }
        await fulfillment(of: [requested], timeout: 10)
        let response = try XCTUnwrap(held)
        let other = ZLibrarySession(userID: "other", userKey: "other-key")
        let switched = await store.connect(other); XCTAssertTrue(switched)
        client.recommendedHandler = nil; client.recommendedBooks = []
        await store.loadShelf(); response.resume(returning: [book]); await pending.value
        XCTAssertTrue(store.shelf.isEmpty); XCTAssertNil(store.shelfError); XCTAssertFalse(store.shelfLoading)
        XCTAssertEqual(client.recommendedSessions.last?.userID, "other")
        let data = try XCTUnwrap(defaults.data(forKey: "zlibrary.shelf"))
        let cache = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(cache["account"] as? String, "other")
    }
    func testConcurrentShelfRefreshCallersShareARequestEvenWhenOneCallerIsCancelled() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        var held: CheckedContinuation<[ZLibraryBook], Error>?
        let requested = expectation(description: "Shared shelf request started")
        client.recommendedHandler = { try await withCheckedThrowingContinuation { held = $0; requested.fulfill() } }
        let first = Task { await store.loadShelf(force: true) }
        await fulfillment(of: [requested], timeout: 10)
        let joined = expectation(description: "Second caller joined")
        let second = Task { joined.fulfill(); await store.loadShelf(force: true) }
        await fulfillment(of: [joined], timeout: 10)
        first.cancel()
        let response = try XCTUnwrap(held); response.resume(returning: [book])
        await first.value; await second.value
        XCTAssertEqual(client.recommendedSessions.count, 1); XCTAssertEqual(store.shelf, [book]); XCTAssertFalse(store.shelfLoading)
    }
    func testRejectedShelfConnectionShowsReconnectWithoutARepeatedRequestLoop() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.recommendedHandler = { throw ZLibraryError.signInRequired }
        await store.loadShelf(); XCTAssertFalse(store.connected)
        XCTAssertTrue(store.shelfError?.contains("Reconnect") == true); XCTAssertNil(store.error)
        await store.loadShelf(); XCTAssertEqual(client.recommendedSessions.count, 1); XCTAssertFalse(store.shelfLoading)
    }
    func testDiscoveryOffMakesNoLibraryRequestsAndPreviewLeavesDiscoverUnchanged() async throws {
        let client = CatalogService(), (store, credentials, defaults) = store(client)
        client.popularBooks = [book]
        client.searchHandler = { [self] _, _ in ZLibrarySearchPage(books: [book], hasMore: true) }
        let matches = await store.searchPreview("  test  ")
        XCTAssertEqual(matches, [book]); XCTAssertEqual(client.searchCalls.map(\.0), ["test"])
        XCTAssertEqual(store.books, []); XCTAssertEqual(store.activeQuery, ""); XCTAssertFalse(store.canLoadMore)
        store.show(query: " test "); XCTAssertEqual(store.activeQuery, "test")
        store.show(.recommended); XCTAssertEqual(store.activeQuery, ""); XCTAssertEqual(store.feed, .recommended)
        let quiet = ZLibraryStore(defaults: defaults, credentials: credentials, client: client, discoversFromLibrary: false)
        await quiet.loadShelf()
        let none = await quiet.searchPreview("test")
        XCTAssertTrue(quiet.shelf.isEmpty); XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(client.popularSessions.isEmpty); XCTAssertEqual(client.searchCalls.count, 1)
    }
    func testRecommendationPopularAndSearchCachesStaySeparateAndClearReturnsToSelectedFeed() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.popularBooks = [book]
        client.recommendedBooks = [] // An empty recommendation feed must also be cached.
        client.searchHandler = { [self] _, _ in ZLibrarySearchPage(books: [book], hasMore: false) }
        await store.loadPopular(); await store.browse(.recommended)
        XCTAssertTrue(store.books.isEmpty); XCTAssertFalse(store.canLoadMore)
        await store.search("title"); await store.setSearchOrder(.year)
        await store.search("")
        XCTAssertEqual(store.feed, .recommended); XCTAssertTrue(store.books.isEmpty)
        XCTAssertEqual(client.recommendedSessions.count, 1); XCTAssertTrue(store.showingSavedResults)
        await store.loadPopular(); XCTAssertEqual(store.books, [book])
        await store.search("title"); await store.browse(.recommended)
        XCTAssertTrue(store.books.isEmpty); XCTAssertEqual(client.popularSessions.count, 1)
        XCTAssertEqual(client.recommendedSessions.count, 1); XCTAssertEqual(client.searchCalls.count, 2)
    }
    func testLateRecommendationCannotReplaceAnotherFeedOrResurrectDisconnectedAccount() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        var continuation: CheckedContinuation<[ZLibraryBook], Error>?
        client.recommendedHandler = { try await withCheckedThrowingContinuation { continuation = $0 } }
        let pending = Task { await store.browse(.recommended) }
        try await eventually { continuation != nil }
        await store.loadPopular()
        continuation?.resume(returning: [book]); await pending.value
        XCTAssertEqual(store.feed, .popular); XCTAssertTrue(store.books.isEmpty); XCTAssertNil(store.error)
        continuation = nil
        let disconnected = Task { await store.browse(.recommended) }
        try await eventually { continuation != nil }
        try await store.disconnect()
        continuation?.resume(returning: [book]); await disconnected.value
        XCTAssertFalse(store.connected); XCTAssertTrue(store.books.isEmpty)
        XCTAssertFalse(store.loading); XCTAssertNil(store.error)
        client.recommendedHandler = nil
        await store.browse(.recommended)
        XCTAssertEqual(client.recommendedSessions.count, 2)
    }
    func testRecommendationRefreshFailureKeepsSavedBooksAndNeverFallsBackToPopular() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.recommendedBooks = [book]
        await store.browse(.recommended)
        client.recommendedHandler = { throw ZLibraryRequestFailure(issue: .accessCheck, diagnostic: "GET /eapi/user/book/recommended · browser redirect") }
        await store.reload()
        XCTAssertEqual(store.books, [book]); XCTAssertTrue(store.showingSavedResults)
        XCTAssertTrue(store.connected); XCTAssertTrue(store.websiteAccessNeeded)
        XCTAssertTrue(store.requestDiagnostic?.contains("/eapi/user/book/recommended") == true)
        XCTAssertTrue(client.popularSessions.isEmpty)
        client.recommendedHandler = nil
        await store.retry()
        XCTAssertNil(store.error); XCTAssertFalse(store.showingSavedResults)
        XCTAssertEqual(client.recommendedSessions.count, 3)
    }
    func testRecommendationsAreIsolatedAcrossAccountsAndReuseResolvedEditionDetails() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        let sparse = ZLibraryBook(remoteID: book.remoteID, hash: book.hash, title: book.title, author: "", fileExtension: "", size: "", language: "", year: "", coverURL: nil)
        client.recommendedBooks = [sparse]; client.detailHandler = { [self] _ in book }
        await store.browse(.recommended)
        let resolved = try await store.details(sparse); XCTAssertEqual(resolved, book)
        await store.loadPopular(); await store.browse(.recommended)
        XCTAssertEqual(store.books, [book]); XCTAssertEqual(client.detailCalls, 1)
        client.recommendedBooks = []
        let changed = await store.connect(ZLibrarySession(userID: "other", userKey: "other-test-account"))
        XCTAssertTrue(changed); XCTAssertTrue(store.books.isEmpty)
        await store.reload()
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertEqual(client.recommendedSessions.map(\.userID), ["42", "other"])
    }
    func testSparsePopularBookLoadsOnlySelectedEditionWithSavedWebsiteContext() async throws {
        let browser = ZLibrarySession(userID:"42",userKey:"test-only",websiteCookies:[ZLibraryWebsiteCookie(name:"access",value:"context",path:"/eapi/book/12",expires:nil)],userAgent:"Saved browser")
        let transport = CatalogTransport { [self] request,_ in
            if request.url?.path == "/eapi/book/most-popular" {
                return try response(["success":1,"books":[["id":12,"hash":"ab1234","title":"A test book","author":"Test author","cover":"https://images.example/cover.jpg"]]])
            }
            XCTAssertEqual(request.url?.path,"/eapi/book/12/ab1234")
            XCTAssertEqual(request.httpMethod,"GET");XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),browser.userAgent)
            XCTAssertTrue(request.value(forHTTPHeaderField:"Cookie")?.contains("access=context") == true)
            return try response(["success":1,"book":["id":12,"hash":"ab1234","extension":" EPUB \n","filesizeString":"2 MB","language":"English","year":2026]])
        }
        let client = ZLibraryClient(transport:transport)
        let books = try await client.popular(origin:origin,session:browser)
        XCTAssertEqual(transport.requests.count,1,"Feed must not fan out into detail requests")
        var summary = try XCTUnwrap(books.first)
        summary.rating = 4.5; summary.ratingCount = 10; summary.qualityScore = 4
        XCTAssertNil(summary.format)
        let details = try await client.details(summary,origin:origin,session:browser)
        XCTAssertEqual(details.format,.epub);XCTAssertEqual(details.size,"2 MB")
        XCTAssertEqual(details.sourceID,summary.sourceID);XCTAssertEqual(details.title,summary.title)
        XCTAssertEqual(details.coverURL,summary.coverURL);XCTAssertEqual(details.year,"2026")
        XCTAssertEqual(details.rating,4.5);XCTAssertEqual(details.ratingCount,10);XCTAssertEqual(details.qualityScore,4)
        XCTAssertEqual(transport.requests.count,2)
    }
    func testMissingFormatIsRetryableAndDetailsCannotSwitchEditions() async throws {
        for row: [String:Any] in [["extension":"  "],["id":"other","extension":"epub"],["hash":"other","extension":"epub"]] {
            let transport = CatalogTransport { [self] _,_ in try response(["success":1,"book":row]) }
            let sparse = ZLibraryBook(remoteID:"12",hash:"ab1234",title:"A test book",author:"Test",fileExtension:"",size:"",language:"",year:"",coverURL:nil)
            do {
                _ = try await ZLibraryClient(transport:transport).details(sparse,origin:origin,session:nil)
                XCTFail("Invalid details accepted")
            } catch { XCTAssertEqual(error as? ZLibraryError,row["extension"] as? String == "  " ? .metadata : .response) }
        }
    }
    func testDownloadHydratesSparseEditionBeforeFileRequestAndValidatesBytes() async throws {
        let sparse = ZLibraryBook(remoteID:"12",hash:"ab1234",title:"A test book",author:"Test",fileExtension:"",size:"",language:"",year:"",coverURL:nil)
        let temp = try temporaryFolder("LeafZLibraryTests").appendingPathComponent("download.part")
        try Data([0x50,0x4b,0x03,0x04]).write(to:temp)
        let transport = CatalogTransport { [self] request,toFile in
            switch request.url?.path {
            case "/eapi/book/12/ab1234": return try response(["success":1,"book":["extension":"epub"]])
            case "/eapi/book/12/ab1234/file": return try response(["success":1,"file":["downloadLink":"https://cdn.example/file"]])
            default:
                XCTAssertTrue(toFile);XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
                return ZLibraryPayload(data:Data(),file:temp,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }
        }
        let file = try await ZLibraryClient(transport:transport).download(sparse,origin:origin,session:session,progress:{_ in})
        XCTAssertEqual(file.pathExtension,"epub");XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        XCTAssertEqual(transport.requests.map { $0.url!.path },["/eapi/book/12/ab1234","/eapi/book/12/ab1234/file","/file"])
    }
    func testUnsupportedResolvedFormatNeverRequestsDownloadLink() async throws {
        let sparse = ZLibraryBook(remoteID:"12",hash:"ab1234",title:"A test book",author:"Test",fileExtension:"",size:"",language:"",year:"",coverURL:nil)
        let transport = CatalogTransport { [self] request,_ in
            XCTAssertEqual(request.url?.path,"/eapi/book/12/ab1234")
            return try response(["success":1,"book":["extension":"djvu"]])
        }
        do { _ = try await ZLibraryClient(transport:transport).download(sparse,origin:origin,session:session,progress:{_ in});XCTFail("Unsupported file downloaded") }
        catch { XCTAssertEqual(error as? ZLibraryError,.file) }
        XCTAssertEqual(transport.requests.count,1)
    }
    func testCatalogDescriptionDecodesMarkupAndKeepsEditionMetadata() async throws {
        let transport = CatalogTransport { [self] _,_ in
            try response(["success":1,"book":["description":"<p>Olive &amp; Adam <b>meet</b>.</p><p>第二段<br>Fin.</p>"]])
        }
        let details = try await ZLibraryClient(transport:transport).details(book,origin:origin,session:nil)
        XCTAssertEqual(details.summary,"Olive & Adam meet.\n\n第二段\nFin.")
        XCTAssertEqual(details.fileSummary,book.fileSummary)
        XCTAssertEqual(details.editionSummary,book.editionSummary)
        XCTAssertEqual(transport.requests.count,1)
    }
    func testDescriptionFetchCachesMissingAndPresentTextWithoutReplacingListedEdition() async throws {
        let descriptions: [String?] = [nil,"","A short description.","这是一段中文简介。"]
        for text in descriptions {
            let client = CatalogService(), (store,_,_) = store(client)
            client.popularBooks = [book]
            let incoming = ZLibraryBook(remoteID:book.remoteID,hash:book.hash,title:"Other metadata",author:"Other author",fileExtension:"pdf",size:"8 MB",language:"French",year:"2026",coverURL:nil,summary:text)
            client.detailHandler = { _ in incoming }
            await store.loadPopular()
            let first = try await store.details(book,description:true)
            let second = try await store.details(book,description:true)
            XCTAssertEqual(first.summary,text ?? "")
            XCTAssertEqual(first.fileSummary,book.fileSummary)
            XCTAssertEqual(first.editionSummary,book.editionSummary)
            XCTAssertEqual(first.title,book.title)
            XCTAssertEqual(second,first)
            XCTAssertEqual(client.detailCalls,1,"Reopening a fetched description, including a missing one, must reuse its result")
        }
    }
    func testResolvedDetailsUpdateFeedAndAreReusedWithoutAnotherRequest() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        let sparse = ZLibraryBook(remoteID:book.remoteID,hash:book.hash,title:book.title,author:book.author,fileExtension:"",size:"",language:"",year:"",coverURL:nil)
        client.popularBooks = [sparse];client.detailHandler = { [self] _ in book }
        await store.loadPopular()
        let first = try await store.details(sparse)
        let second = try await store.details(sparse)
        XCTAssertEqual(first,book);XCTAssertEqual(second,book);XCTAssertEqual(store.books,[book])
        XCTAssertEqual(client.detailCalls,1)
    }
    func testVisibleCardsHydrateWithoutOpeningAndReuseDetailsAcrossFeedRefreshAndSearch() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let sparse = ZLibraryBook(remoteID: book.remoteID, hash: book.hash, title: book.title, author: "", fileExtension: "", size: "", language: "", year: "", coverURL: nil)
        var rich = book; rich.rating = 4.8; rich.ratingCount = 42; rich.summary = "A description."
        let resolved = rich
        client.popularBooks = [sparse]; client.detailHandler = { _ in resolved }
        client.searchHandler = { _, _ in ZLibrarySearchPage(books: [sparse], hasMore: false) }
        await store.loadPopular()
        XCTAssertEqual(client.detailCalls, 0, "Fetching the feed must not hydrate every off-screen book")
        XCTAssertTrue(store.cardDetailsPending(sparse))
        await store.loadCardDetails(sparse)
        XCTAssertEqual(store.books, [resolved]); XCTAssertFalse(store.cardDetailsPending(resolved))
        let selected = try await store.details(sparse, description: true)
        XCTAssertEqual(selected, resolved)
        await store.reload(); XCTAssertEqual(store.books, [resolved])
        await store.search("title"); XCTAssertEqual(store.books, [resolved])
        await store.loadCardDetails(store.books[0]); XCTAssertEqual(client.detailCalls, 1)
    }
    func testBackgroundDetailsFillGapsWithoutChangingKnownEditionFields() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let listed = ZLibraryBook(remoteID: book.remoteID, hash: book.hash, title: "Listed title", author: "Listed author", fileExtension: "pdf", size: "2 MB", language: "Chinese", year: "2000", coverURL: nil)
        var rich = book; rich.rating = 4.8; rich.ratingCount = 42
        client.popularBooks = [listed]; client.detailHandler = { _ in rich }
        await store.loadPopular(); await store.loadCardDetails(listed)
        let updated = try XCTUnwrap(store.books.first)
        XCTAssertEqual(updated.title, listed.title); XCTAssertEqual(updated.author, listed.author)
        XCTAssertEqual(updated.fileExtension, "pdf"); XCTAssertEqual(updated.size, "2 MB")
        XCTAssertEqual(updated.language, "Chinese"); XCTAssertEqual(updated.year, "2000")
        XCTAssertEqual(updated.rating, 4.8); XCTAssertEqual(updated.ratingCount, 42)
        await store.reload(); XCTAssertEqual(store.books.first, updated)
    }
    func testVisibleAndSelectedBookShareOneRequestAndCancellingCellKeepsSelectionAlive() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let listed = book
        var pending: CheckedContinuation<ZLibraryBook, Error>?
        client.detailHandler = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        client.popularBooks = [listed]; await store.loadPopular()
        let card = Task { await store.loadCardDetails(listed) }
        try await eventually { pending != nil }
        let page = Task { try await store.details(listed, description: true) }
        // Give the selected-page subscription time to join the already running fetch.
        for _ in 0..<10 { await Task.yield() }
        card.cancel(); pending?.resume(returning: listed)
        let result = try await page.value; await card.value
        XCTAssertEqual(result.fileExtension, listed.fileExtension)
        XCTAssertEqual(result.summary, ""); XCTAssertEqual(client.detailCalls, 1)
        XCTAssertFalse(store.cardDetailsFailed(listed))
    }
    func testMetadataQueueLimitsTransfersAndDropsCancelledOffscreenCards() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let rows = (0..<6).map { ZLibraryBook(remoteID: "\($0)", hash: "abc", title: "Book \($0)", author: "", fileExtension: "", size: "", language: "", year: "", coverURL: nil) }
        var pending: [String: CheckedContinuation<ZLibraryBook, Error>] = [:]
        var requested: [String] = [], active = 0, peak = 0
        client.detailHandler = { book in
            active += 1; peak = max(peak, active); requested.append(book.id)
            defer { active -= 1 }
            return try await withCheckedThrowingContinuation { pending[book.id] = $0 }
        }
        client.popularBooks = rows; await store.loadPopular()
        let tasks = rows.map { row in Task { await store.loadCardDetails(row) } }
        try await eventually { client.detailCalls == 2 }
        XCTAssertEqual(active, 2)
        for task in tasks { task.cancel() }
        // The fake transport ignores cancellation, so complete only the two calls it received.
        for (id, continuation) in pending { continuation.resume(returning: rows.first { $0.id == id }!) }
        for task in tasks { await task.value }
        XCTAssertEqual(client.detailCalls, 2); XCTAssertEqual(peak, 2)
        XCTAssertEqual(requested.count, 2); XCTAssertTrue(store.books.allSatisfy { $0.fileExtension.isEmpty })
        client.detailHandler = { [self] _ in book }
        await store.loadCardDetails(rows[0])
        XCTAssertEqual(client.detailCalls, 3, "Cancelled work must release its transfer slot")
    }
    func testMissingRatingsAreFetchedOnceAndFailuresWaitForExplicitRefresh() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let listed = book
        client.popularBooks = [listed]; client.detailHandler = { _ in throw ZLibraryError.unreachable }
        await store.loadPopular(); await store.loadCardDetails(listed); await store.loadCardDetails(listed)
        XCTAssertEqual(client.detailCalls, 1); XCTAssertTrue(store.cardDetailsFailed(listed))
        XCTAssertFalse(store.cardDetailsPending(listed)); XCTAssertNil(store.error)
        client.detailHandler = { _ in listed }
        let selected = try await store.details(listed, description: true)
        XCTAssertEqual(selected.summary, ""); XCTAssertFalse(store.cardDetailsFailed(listed))
        await store.reload(); await store.loadCardDetails(listed)
        XCTAssertEqual(client.detailCalls, 2); XCTAssertFalse(store.cardDetailsFailed(listed))
        XCTAssertNil(store.books.first?.rating)
        await store.loadCardDetails(store.books[0]); XCTAssertEqual(client.detailCalls, 2)
        XCTAssertFalse(store.cardDetailsPending(store.books[0]), "An absent rating after a successful request is final")
    }
    func testLateCardSubscribersCannotGrowMetadataCachePastItsCapacity() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let rows = (1...240).map { ZLibraryBook(remoteID: "\($0)", hash: "abc", title: "Book \($0)", author: "", fileExtension: "", size: "", language: "", year: "", coverURL: nil) }
        client.popularBooks = rows
        client.detailHandler = { row in
            ZLibraryBook(remoteID: row.remoteID, hash: row.hash, title: row.title, author: "Author", fileExtension: "epub", size: "1 MB", language: "English", year: "2026", coverURL: nil)
        }
        await store.loadPopular()
        await withTaskGroup(of: Void.self) { group in
            for row in rows { group.addTask { await store.loadCardDetails(row) } }
        }
        XCTAssertEqual(client.detailCalls, 240)
        XCTAssertLessThanOrEqual(store.cachedDetailCount, 200)
        XCTAssertEqual(store.books.count, 240, "Evicting expendable metadata must not remove listed books")
        XCTAssertTrue(store.books.allSatisfy { $0.fileExtension == "epub" })
    }
    func testAccountChangeCancelsBackgroundDetailsAndDoesNotReusePreviousAccountsCache() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let listed = book
        var pending: CheckedContinuation<ZLibraryBook, Error>?
        client.detailHandler = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        client.popularBooks = [listed]; await store.loadPopular()
        let card = Task { await store.loadCardDetails(listed) }
        try await eventually { pending != nil }
        try await store.disconnect(); pending?.resume(returning: listed); await card.value
        XCTAssertTrue(store.books.isEmpty); XCTAssertFalse(store.cardDetailsFailed(listed))
        client.detailHandler = { _ in listed }
        await store.loadPopular(); await store.loadCardDetails(listed)
        XCTAssertEqual(client.detailCalls, 2)
    }
    func testLateDetailsAfterDisconnectCannotRestoreFeedOrAccount() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        var pending: CheckedContinuation<ZLibraryBook,Error>?
        client.detailHandler = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let task = Task { try await store.details(book) }
        try await eventually { pending != nil }
        try await store.disconnect()
        pending?.resume(returning:book)
        do { _ = try await task.value;XCTFail("Stale details escaped") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.books.isEmpty);XCTAssertFalse(store.connected)
    }
    func testSearchPOSTEncodesUnicodeReservedCharactersAndKeepsSessionOutOfURL() async throws {
        let query = "十日终焉 + C++ & author=王 #978"
        let browser = ZLibrarySession(userID:"42",userKey:"private-key",websiteCookies:[ZLibraryWebsiteCookie(name:"site_access",value:"opaque",path:"/",expires:nil)],userAgent:"Signed-in browser")
        let transport = CatalogTransport { [self] request,toFile in
            XCTAssertFalse(toFile);XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.url?.absoluteString,"https://catalog.example/eapi/book/search")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"),"application/x-www-form-urlencoded; charset=utf-8")
            XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),browser.userAgent)
            XCTAssertTrue(request.value(forHTTPHeaderField:"Cookie")?.contains("site_access=opaque") == true)
            let body = try XCTUnwrap(String(data:try XCTUnwrap(request.httpBody),encoding:.utf8))
            let fields = URLComponents(string:"https://example.test/?\(body)")!.queryItems!
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:fields.map { ($0.name,$0.value ?? "") }),["message":query,"page":"2","limit":"30","order":"popular"])
            XCTAssertFalse(body.contains("private-key"));XCTAssertFalse(body.contains("site_access"))
            return try response(["success":1,"books":[["id":12,"hash":"ab","title":"A matching edition","extension":"epub"]]])
        }
        let page = try await ZLibraryClient(transport:transport).search(" \(query)\n",page:2,origin:origin,session:browser)
        XCTAssertEqual(page.books.count,1);XCTAssertFalse(page.hasMore)
    }
    func testCatalogMetadataSurvivesBothFeedsWithoutDetailRequestFanout() async throws {
        let row: [String:Any] = ["id":12,"hash":"ab","title":"墓碑","extension":"pdf","filesizeString":"18.7 MB","filesize":1,
                                 "language":"Chinese","year":2008,"interestScore":"4.6","ratingCount":"52","qualityScore":4.2]
        let transport = CatalogTransport { [self] _,_ in try response(["success":1,"books":[row]]) }
        let client = ZLibraryClient(transport:transport)
        let popular = try await client.popular(origin:origin,session:session)
        let search = try await client.search("墓碑",page:1,origin:origin,session:session)
        XCTAssertEqual(popular,search.books)
        let book = try XCTUnwrap(popular.first)
        XCTAssertEqual(book.fileSummary,"PDF · 18.7 MB")
        XCTAssertEqual(book.editionSummary,"Chinese · 2008")
        XCTAssertEqual(book.rating,4.6);XCTAssertEqual(book.ratingCount,52);XCTAssertEqual(book.qualityScore,4.2)
        XCTAssertTrue(book.ratingSummary.contains("52 ratings"))
        XCTAssertEqual(transport.requests.map { $0.url!.path },["/eapi/book/most-popular","/eapi/book/search"])
    }
    func testCatalogMetadataSupportsByteSizesAndIndependentBookAndFileScores() throws {
        let row: [String:Any] = ["id":12,"hash":"ab","title":"Edition","filesize":"2400000","rating":"4.7","interestScore":3,"qualityScore":"2.5","ratingCount":1]
        let book = try XCTUnwrap(ZLibraryClient.book(row,origin:origin))
        XCTAssertEqual(book.size,ByteCountFormatter.string(fromByteCount:2400000,countStyle:.file))
        XCTAssertEqual(book.rating,4.7);XCTAssertEqual(book.qualityScore,2.5)
        XCTAssertTrue(book.ratingSummary.hasSuffix("1 rating"))
        var qualityOnly = row;qualityOnly.removeValue(forKey:"rating");qualityOnly.removeValue(forKey:"interestScore")
        let missing = try XCTUnwrap(ZLibraryClient.book(qualityOnly,origin:origin))
        XCTAssertNil(missing.rating);XCTAssertEqual(missing.ratingSummary,"No rating provided")
        XCTAssertEqual(missing.qualityScore,2.5)
    }
    func testMalformedOrMissingMetadataDoesNotInventScoresCountsOrSizes() throws {
        let base: [String:Any] = ["id":12,"hash":"ab","title":"Sparse edition"]
        let sparse = try XCTUnwrap(ZLibraryClient.book(base,origin:origin))
        XCTAssertEqual(sparse.fileSummary,"Size unavailable");XCTAssertEqual(sparse.ratingSummary,"No rating provided")
        for value: Any in [NSNull(),true,false,"NaN","Infinity","-1",0,11,["value":4]] {
            var row = base;row["rating"] = value;row["qualityScore"] = value
            let book = try XCTUnwrap(ZLibraryClient.book(row,origin:origin))
            XCTAssertNil(book.rating,"\(value)");XCTAssertNil(book.qualityScore,"\(value)")
        }
        for value: Any in [NSNull(),true,-1,0,"1.5","99999999999999999999999999"] {
            var row = base;row["filesize"] = value;row["ratingCount"] = value
            let book = try XCTUnwrap(ZLibraryClient.book(row,origin:origin))
            XCTAssertTrue(book.size.isEmpty,"\(value)");XCTAssertNil(book.ratingCount,"\(value)")
        }
        for value in ["0 MB","-2 MB","unknown",String(repeating:"9",count:50)+" MB"] {
            var row = base;row["filesizeString"] = value;row["filesize"] = 1024
            XCTAssertEqual(ZLibraryClient.book(row,origin:origin)?.size,ByteCountFormatter.string(fromByteCount:1024,countStyle:.file))
        }
    }
    func testSearchValidatesQueryAndPageBeforeNetworkAndDetectsMoreResults() async throws {
        let rows = (1...30).map { ["id":String($0),"hash":"ab","title":"Edition \($0)","extension":"epub"] }
        let transport = CatalogTransport { [self] _,_ in try response(["success":1,"books":rows]) }
        let client = ZLibraryClient(transport:transport)
        for query in [" \n",String(repeating:"字",count:501)] {
            do { _ = try await client.search(query,page:1,origin:origin,session:nil);XCTFail("Invalid query sent") }
            catch { XCTAssertEqual(error as? ZLibraryError,.query) }
        }
        for page in [0,11] {
            do { _ = try await client.search("ISBN",page:page,origin:origin,session:nil);XCTFail("Invalid page sent") }
            catch { XCTAssertEqual(error as? ZLibraryError,.query) }
        }
        XCTAssertTrue(transport.requests.isEmpty)
        let page = try await client.search("9780000000000",page:1,origin:origin,session:nil)
        XCTAssertEqual(page.books.count,30);XCTAssertTrue(page.hasMore)
    }
    func testEverySearchOrderUsesTheProviderParameterAndPreservesResponseOrder() async throws {
        let options: [(ZLibrarySearchOrder,String)] = [(.popular,"popular"),(.bestMatch,"bestmatch"),(.recentlyAdded,"date"),(.titleAscending,"titleA"),(.titleDescending,"title"),(.year,"year"),(.fileSizeDescending,"filesize"),(.fileSizeAscending,"filesizeA")]
        for (order,wire) in options {
            let transport = CatalogTransport { [self] request,_ in
                let body = String(decoding:try XCTUnwrap(request.httpBody),as:UTF8.self)
                let fields = URLComponents(string:"https://example.test/?\(body)")!.queryItems!
                let values = Dictionary(uniqueKeysWithValues:fields.map { ($0.name,$0.value ?? "") })
                XCTAssertEqual(values,["message":"墓碑 + author","page":"3","limit":"30","order":wire])
                XCTAssertNil(request.url?.query)
                return try response(["success":1,"books":[["id":2,"hash":"ab","title":"Z last"],["id":1,"hash":"cd","title":"A first"]]])
            }
            let result = try await ZLibraryClient(transport:transport).search("墓碑 + author",page:3,order:order,origin:origin,session:session)
            XCTAssertEqual(result.books.map(\.remoteID),["2","1"],"Provider performs sorting, not this partial page")
            XCTAssertEqual(transport.requests.count,1)
        }
    }
    func testChangingOrderCancelsSameQueryAndRejectsItsLateResults() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        var pending: CheckedContinuation<ZLibrarySearchPage,Error>?
        client.orderedSearchHandler = { [self] _,_,order in
            if order == .popular { return try await withCheckedThrowingContinuation { pending = $0 } }
            return ZLibrarySearchPage(books:[book],hasMore:false)
        }
        let first = Task { await store.search("same query") }
        try await eventually { pending != nil }
        await store.setSearchOrder(.fileSizeAscending)
        XCTAssertEqual(store.books,[book]);XCTAssertFalse(store.loading)
        pending?.resume(returning:ZLibrarySearchPage(books:[],hasMore:true));await first.value
        XCTAssertEqual(store.books,[book]);XCTAssertFalse(store.canLoadMore)
        XCTAssertEqual(client.searchCalls.map { $0.3 },[.popular,.fileSizeAscending])
        XCTAssertEqual(client.searchCalls.map { $0.1 },[1,1])
    }
    func testOrderChangeResetsPaginationAndSurvivesRetryRefreshAndReconnect() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        var failNext = true
        client.orderedSearchHandler = { _,page,order in
            if order == .year && page == 2 && failNext { failNext = false;throw ZLibraryError.response }
            let book = ZLibraryBook(remoteID:"\(order.rawValue)-\(page)",hash:"ab",title:"Edition",author:"A",fileExtension:"epub",size:"1 MB",language:"English",year:"2026",coverURL:nil)
            return ZLibrarySearchPage(books:[book],hasMore:page == 1)
        }
        await store.search("title");await store.loadMore()
        XCTAssertEqual(store.books.count,2)
        await store.setSearchOrder(.year)
        XCTAssertEqual(store.books.map(\.remoteID),["year-1"])
        await store.loadMore();XCTAssertNotNil(store.error);XCTAssertEqual(store.books.count,1)
        await store.retry();XCTAssertNil(store.error);XCTAssertEqual(store.books.map(\.remoteID),["year-1","year-2"])
        await store.reload()
        let connected = await store.connect(session);XCTAssertTrue(connected)
        await store.reload()
        XCTAssertEqual(store.activeQuery,"title");XCTAssertEqual(store.searchOrder,.year)
        XCTAssertEqual(client.searchCalls.map { $0.1 },[1,2,1,2,2,1,1])
        XCTAssertTrue(client.searchCalls.dropFirst(2).allSatisfy { $0.3 == .year })
    }
    func testSearchOrderPreferenceDoesNotReorderPopularFeedOrStoreSearchText() async throws {
        let client = CatalogService(), (store,credentials,defaults) = store(client)
        XCTAssertEqual(store.searchOrder,.popular)
        await store.loadPopular();let calls = client.popularSessions.count
        await store.setSearchOrder(.titleAscending)
        await store.setSearchOrder(.titleAscending)
        XCTAssertEqual(client.popularSessions.count,calls);XCTAssertTrue(client.searchCalls.isEmpty)
        let restored = ZLibraryStore(defaults:defaults,credentials:credentials,client:client)
        XCTAssertEqual(restored.searchOrder,.titleAscending);XCTAssertTrue(restored.activeQuery.isEmpty)
        try await restored.disconnect();XCTAssertEqual(restored.searchOrder,.titleAscending)
        defaults.set("invalid-sort",forKey:"zlibrary.searchOrder")
        XCTAssertEqual(ZLibraryStore(defaults:defaults,credentials:credentials,client:client).searchOrder,.popular)
    }
    func testSearchRedirectPreservesPOSTBodyOnlyFor307And308AndDiagnosticsRedactQuery() async throws {
        for status in [302,307,308] {
            var calls = 0, originalBody: Data?
            let transport = CatalogTransport { [self] request,_ in
                calls += 1
                if calls == 1 {
                    originalBody = request.httpBody
                    return ZLibraryPayload(data:Data(),file:nil,response:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Location":"/eapi/book/search/?language=en"])!)
                }
                XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.httpBody,originalBody)
                return try response(["success":1,"books":[]])
            }
            do {
                _ = try await ZLibraryClient(transport:transport).search("private search",page:1,origin:origin,session:session)
                XCTAssertNotEqual(status,302)
            } catch {
                XCTAssertEqual(status,302)
                let failure = try XCTUnwrap(error as? ZLibraryRequestFailure)
                XCTAssertTrue(failure.diagnostic.hasPrefix("POST /eapi/book/search"))
                XCTAssertFalse(failure.diagnostic.contains("private search"));XCTAssertFalse(failure.diagnostic.contains("language"))
            }
            XCTAssertEqual(calls,status == 302 ? 1 : 2)
        }
    }
    func testSearchSupersedesSlowQueryAndCancelsPreviousNetworkTask() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        var started = false, cancelled = false
        client.searchHandler = { [self] query,_ in
            if query == "old" {
                started = true
                do { try await Task.sleep(for:.seconds(30)) }
                catch { cancelled = true;throw error }
            }
            return ZLibrarySearchPage(books:[book],hasMore:false)
        }
        let old = Task { await store.search("old") }
        try await eventually { started }
        await store.search("latest")
        await old.value
        XCTAssertTrue(cancelled);XCTAssertEqual(store.activeQuery,"latest")
        XCTAssertEqual(store.books,[book]);XCTAssertNil(store.error);XCTAssertFalse(store.loading)
    }
    func testLateUncooperativeSearchCannotReplacePopularListOrNewQuery() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        var continuation: CheckedContinuation<ZLibrarySearchPage,Error>?
        client.searchHandler = { _,_ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let pending = Task { await store.search("old") }
        try await eventually { continuation != nil }
        await store.loadPopular()
        continuation?.resume(returning:ZLibrarySearchPage(books:[book],hasMore:true))
        await pending.value
        XCTAssertEqual(store.activeQuery,"");XCTAssertTrue(store.books.isEmpty)
        XCTAssertFalse(store.canLoadMore);XCTAssertNil(store.error);XCTAssertFalse(store.loading)
    }
    func testSearchPaginationDeduplicatesAndRetryRetainsQueryAndPriorResults() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        _ = await store.connect(session)
        var failSecond = true
        let second = ZLibraryBook(remoteID:"13",hash:"next",title:"Second",author:"Author",fileExtension:"pdf",size:"1 MB",language:"English",year:"2000",coverURL:nil)
        client.searchHandler = { [self] _,page in
            if page == 2 && failSecond { throw ZLibraryError.service("Temporary search failure") }
            return ZLibrarySearchPage(books:page == 1 ? [book] : [book,second],hasMore:page == 1)
        }
        await store.search("  author name  ")
        XCTAssertEqual(store.activeQuery,"author name");XCTAssertEqual(store.books,[book]);XCTAssertTrue(store.canLoadMore)
        await store.loadMore()
        XCTAssertEqual(store.books,[book]);XCTAssertTrue(store.connected);XCTAssertNotNil(store.error)
        failSecond = false;await store.retry()
        XCTAssertEqual(store.books,[book,second]);XCTAssertFalse(store.canLoadMore);XCTAssertNil(store.error)
        XCTAssertEqual(client.searchCalls.map { $0.1 },[1,2,2])
        XCTAssertTrue(client.searchCalls.allSatisfy { $0.0 == "author name" && $0.2 == session })
        await store.loadMore();XCTAssertEqual(client.searchCalls.count,3)
    }
    func testSearchStopsAtResultBoundAndDoesNotRequestRepeatedPages() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        client.searchHandler = { query,page in
            let books = (1...30).map { ZLibraryBook(remoteID:"\(page)-\($0)",hash:"ab",title:query,author:"A",fileExtension:"epub",size:"",language:"",year:"",coverURL:nil) }
            return ZLibrarySearchPage(books:books,hasMore:true)
        }
        await store.search("broad query")
        for _ in 1...12 { await store.loadMore() }
        XCTAssertEqual(store.books.count,300);XCTAssertEqual(client.searchCalls.count,10)
        XCTAssertTrue(store.searchLimitReached);XCTAssertFalse(store.canLoadMore)
        await store.search(" \n")
        XCTAssertEqual(store.activeQuery,"");XCTAssertFalse(store.searchLimitReached);XCTAssertFalse(store.canLoadMore)
        await store.search("broad query")
        XCTAssertEqual(store.books.count, 300); XCTAssertTrue(store.searchLimitReached)
        XCTAssertFalse(store.canLoadMore); XCTAssertEqual(client.searchCalls.count, 10)
    }
    func testSearchRefreshReconnectAndFailureKeepTheSubmittedQuery() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        _ = await store.connect(session)
        client.searchHandler = { [self] _,_ in ZLibrarySearchPage(books:[book],hasMore:false) }
        await store.search("author query");await store.reload()
        let replacement = ZLibrarySession(userID:"42",userKey:"replacement-key")
        _ = await store.connect(replacement);await store.reload()
        XCTAssertEqual(client.searchCalls.count,3);XCTAssertTrue(client.popularSessions.isEmpty)
        XCTAssertEqual(client.searchCalls.last?.2,replacement);XCTAssertEqual(store.activeQuery,"author query")
        client.searchHandler = { _,_ in throw ZLibraryRequestFailure(issue:.challenge,diagnostic:"POST /eapi/book/search · HTTP 403 · HTML instead of JSON") }
        await store.reload()
        XCTAssertTrue(store.connected);XCTAssertTrue(store.websiteAccessNeeded)
        XCTAssertTrue(store.error?.contains("search results") == true)
        XCTAssertEqual(store.activeQuery,"author query");XCTAssertEqual(store.books,[book])
        XCTAssertTrue(store.showingSavedResults)
        client.searchHandler = { _,_ in throw ZLibraryRequestFailure(issue:.signInRequired,diagnostic:"POST /eapi/book/search · HTTP 401 · JSON/API response") }
        await store.retry()
        XCTAssertFalse(store.connected);XCTAssertEqual(store.activeQuery,"author query")
    }
    func testDisconnectDuringSearchCannotRestoreAccountOrResults() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        _ = await store.connect(session)
        var continuation: CheckedContinuation<ZLibrarySearchPage,Error>?
        client.searchHandler = { _,_ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let task = Task { await store.search("pending") }
        try await eventually { continuation != nil }
        try await store.disconnect()
        continuation?.resume(returning:ZLibrarySearchPage(books:[book],hasMore:true));await task.value
        XCTAssertFalse(store.connected);XCTAssertTrue(store.books.isEmpty);XCTAssertEqual(store.activeQuery,"")
        XCTAssertFalse(store.loading);XCTAssertFalse(store.canLoadMore);XCTAssertNil(store.error)
    }
    func testSearchStopsPagingIfServiceRepeatsTheSameBooks() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        client.searchHandler = { [self] _,_ in ZLibrarySearchPage(books:[book],hasMore:true) }
        await store.search("repeated results");await store.loadMore();await store.loadMore()
        XCTAssertEqual(store.books,[book]);XCTAssertFalse(store.canLoadMore)
        XCTAssertEqual(client.searchCalls.map { $0.1 },[1,2])
    }
    func testWebsiteSessionIsBackwardCompatibleAndCookiesRespectPathExpiryAndHeaderSafety() throws {
        let legacy = try JSONDecoder().decode(ZLibrarySession.self, from: Data("{\"userID\":\"42\",\"userKey\":\"old-key\"}".utf8))
        XCTAssertTrue(legacy.valid); XCTAssertNil(legacy.websiteCookies); XCTAssertNil(legacy.userAgent)
        let cookies = [
            ZLibraryWebsiteCookie(name:"site_access",value:"opaque",path:"/",expires:Date().addingTimeInterval(60)),
            ZLibraryWebsiteCookie(name:"catalog_mode",value:"books",path:"/eapi/book",expires:nil),
            ZLibraryWebsiteCookie(name:"login_only",value:"private",path:"/login",expires:nil),
            ZLibraryWebsiteCookie(name:"old_access",value:"expired",path:"/",expires:Date().addingTimeInterval(-60))
        ]
        let saved = ZLibrarySession(userID:"42",userKey:"test-only-session",websiteCookies:cookies,userAgent:"Browser session test/1.0")
        XCTAssertTrue(saved.valid)
        let request = ZLibraryClient().request("book/most-popular",origin:origin,session:saved)
        XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),saved.userAgent)
        let header = try XCTUnwrap(request.value(forHTTPHeaderField:"Cookie"))
        XCTAssertTrue(header.contains("site_access=opaque"));XCTAssertTrue(header.contains("catalog_mode=books"))
        XCTAssertFalse(header.contains("login_only"));XCTAssertFalse(header.contains("old_access"))
        XCTAssertFalse(saved.cookieHeader(for:origin.url.appendingPathComponent("eapi/bookmark")).contains("catalog_mode"))
        XCTAssertEqual(try JSONDecoder().decode(ZLibrarySession.self,from:JSONEncoder().encode(saved)),saved)
        XCTAssertFalse(ZLibrarySession(userID:"42",userKey:"key",userAgent:"x\r\nCookie: injected").valid)
        XCTAssertFalse(ZLibraryWebsiteCookie(name:"site_access",value:"x; stolen=key",path:"/",expires:nil).valid)
        XCTAssertFalse(ZLibraryWebsiteCookie(name:"bad\r\nheader",value:"x",path:"/",expires:nil).valid)
    }
    func testAPIRedirectCanonicalizationPreservesSessionWithoutFollowingWebsiteOrCrossOrigin() async throws {
        let browser = ZLibrarySession(userID:"42",userKey:"key",websiteCookies:[ZLibraryWebsiteCookie(name:"site_access",value:"opaque",path:"/",expires:nil)],userAgent:"Browser identity")
        var count = 0
        let transport = CatalogTransport { [self] request,_ in
            count += 1
            XCTAssertEqual(request.value(forHTTPHeaderField:"Cookie"),"remix_userid=42; remix_userkey=key; site_access=opaque")
            XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),"Browser identity")
            if count == 1 { return ZLibraryPayload(data:Data(),file:nil,response:HTTPURLResponse(url:request.url!,statusCode:302,httpVersion:nil,headerFields:["Location":"/eapi/book/most-popular/?language=en"])!) }
            XCTAssertEqual(request.url?.absoluteString,"https://catalog.example/eapi/book/most-popular/?language=en")
            return try response(["success":1,"books":[]])
        }
        _ = try await ZLibraryClient(transport:transport).popular(origin:origin,session:browser)
        XCTAssertEqual(count,2)
        for location in ["https://other.example/eapi/book/most-popular", "/verification?secret=not-for-diagnostics", "http://catalog.example/eapi/book/most-popular", "/eapi/book/most-popular"] {
            let rejected = CatalogTransport { request,_ in
                ZLibraryPayload(data:Data(),file:nil,response:HTTPURLResponse(url:request.url!,statusCode:307,httpVersion:nil,headerFields:["Location":location])!)
            }
            do { _ = try await ZLibraryClient(transport:rejected).popular(origin:origin,session:browser);XCTFail("Unsafe or looping redirect followed") }
            catch { XCTAssertEqual(ZLibraryRequestFailure.issue(error),.challenge) }
            XCTAssertEqual(rejected.requests.count,1)
        }
    }
    func testRedirectsAreBoundedAndRebuildPathScopedCookieHeaders() async throws {
        let browser = ZLibrarySession(userID:"42",userKey:"key",websiteCookies:[ZLibraryWebsiteCookie(name:"popular_only",value:"private",path:"/eapi/book/most-popular",expires:nil)])
        var count = 0
        let transport = CatalogTransport { request,_ in
            count += 1
            if count > 1 { XCTAssertFalse(request.value(forHTTPHeaderField:"Cookie")?.contains("popular_only") ?? true) }
            return ZLibraryPayload(data:Data(),file:nil,response:HTTPURLResponse(url:request.url!,statusCode:302,httpVersion:nil,headerFields:["Location":"/eapi/other/\(count)"])!)
        }
        do { _ = try await ZLibraryClient(transport:transport).popular(origin:origin,session:browser);XCTFail("Unbounded redirects") }
        catch { XCTAssertEqual(ZLibraryRequestFailure.issue(error),.challenge) }
        XCTAssertEqual(count,4)
    }
    func testRedirectDiagnosticsExplainPolicyWithoutExposingTargetOrResponse() async throws {
        let cases: [(String?, String, String)] = [
            (nil, "missing Location", "missing"),
            ("https://[", "invalid Location", "invalid"),
            ("/eapi/book/most-popular", "same URL refused", "same URL"),
            ("/verify/private-path?token=private-query#private-fragment", "outside API refused", "same-origin website"),
            ("https://private-host.example/eapi/private-path?token=private-query", "different API origin refused", "different origin"),
            ("http://catalog.example/eapi/private-path", "HTTPS required", "non-HTTPS"),
            ("https://private-user:private-password@catalog.example/eapi/private-path", "credentials in target", "same-origin API"),
            ("https://catalog.example:443/eapi/private-path", "explicit port refused", "different origin")
        ]
        for (location, reason, target) in cases {
            let transport = CatalogTransport { request, _ in
                var headers = ["Content-Type": "text/html", "Set-Cookie": "__diamwall=private-cookie; Path=/; Secure"]
                headers["Location"] = location
                return ZLibraryPayload(data: Data("<html>private-body reader@private.example</html>".utf8), file: nil,
                    response: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: headers)!)
            }
            do { _ = try await ZLibraryClient(transport: transport).popular(origin: origin, session: session); XCTFail("Rejected redirect followed") }
            catch let failure as ZLibraryRequestFailure {
                XCTAssertEqual(failure.issue, .accessCheck)
                XCTAssertTrue(failure.diagnostic.contains("HTTP 307 · redirect not followed"))
                XCTAssertTrue(failure.diagnostic.contains("reason: " + reason))
                XCTAssertTrue(failure.diagnostic.contains("Redirect target: " + target))
                XCTAssertTrue(failure.diagnostic.contains("Redirects followed: 0/3"))
                XCTAssertTrue(failure.diagnostic.contains("response cookie update: present"))
                XCTAssertTrue(failure.diagnostic.contains("access-check marker: DiamWall"))
                for secret in ["private-", "reader@", "token=", "__diamwall=", "test-only-session", "catalog.example"] {
                    XCTAssertFalse(failure.diagnostic.contains(secret), secret)
                }
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }
    func testRedirectLoopAndHopLimitDiagnosticsStayBounded() async throws {
        for looping in [true, false] {
            var count = 0
            let transport = CatalogTransport { request, _ in
                count += 1
                let target = looping ? "/eapi/next" : "/eapi/next/\(count)?token=not-for-diagnostic"
                return ZLibraryPayload(data: Data(), file: nil,
                    response: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": target])!)
            }
            do { _ = try await ZLibraryClient(transport: transport).popular(origin: origin, session: session); XCTFail("Unbounded redirect") }
            catch let failure as ZLibraryRequestFailure {
                XCTAssertTrue(failure.diagnostic.contains(looping ? "reason: redirect loop" : "reason: redirect limit reached"))
                XCTAssertTrue(failure.diagnostic.contains(looping ? "Redirects followed: 1/3" : "Redirects followed: 3/3"))
                XCTAssertTrue(failure.diagnostic.contains("response cookie update: absent"))
                XCTAssertFalse(failure.diagnostic.contains("not-for-diagnostic"))
            }
            XCTAssertEqual(count, looping ? 2 : 4)
        }
    }
    func testRepeatedNavigationReusesListsIncludingEmptyResultsAndAllPaginationState() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        client.popularBooks = [book]
        client.searchHandler = { query, page in
            let rows = query == "empty" ? [] : [ZLibraryBook(remoteID: "\(page)", hash: "ab", title: query, author: "", fileExtension: "epub", size: "", language: "", year: "", coverURL: nil)]
            return ZLibrarySearchPage(books: rows, hasMore: query != "empty")
        }
        await store.loadPopular(); await store.search("books"); await store.loadMore()
        let pages = store.books
        for _ in 0..<20 {
            await store.loadPopular(); XCTAssertEqual(store.books, [book])
            await store.search("books"); XCTAssertEqual(store.books, pages)
            XCTAssertTrue(store.canLoadMore); XCTAssertTrue(store.showingSavedResults)
        }
        XCTAssertEqual(client.popularSessions.count, 1); XCTAssertEqual(client.searchCalls.count, 2)
        await store.loadMore(); XCTAssertEqual(client.searchCalls.last?.1, 3)
        await store.search("empty"); await store.loadPopular(); await store.search("empty")
        XCTAssertTrue(store.books.isEmpty); XCTAssertFalse(store.canLoadMore)
        XCTAssertEqual(client.searchCalls.filter { $0.0 == "empty" }.count, 1)
    }
    func testSavedSearchesAreBoundedAndIsolatedByOrderAndAccount() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        client.searchHandler = { [self] _, _ in ZLibrarySearchPage(books: [book], hasMore: false) }
        await store.loadPopular()
        for query in ["one", "two", "three", "four"] { await store.search(query) }
        await store.search("one"); XCTAssertEqual(client.searchCalls.count, 5) // LRU eviction
        await store.setSearchOrder(.year); XCTAssertEqual(client.searchCalls.count, 6)
        await store.setSearchOrder(.popular); XCTAssertEqual(client.searchCalls.count, 7) // Explicit sort restarts
        let connected = await store.connect(session); XCTAssertTrue(connected)
        await store.search("one"); XCTAssertEqual(client.searchCalls.count, 8)
        try await store.disconnect(); await store.search("one"); XCTAssertEqual(client.searchCalls.count, 9)
        try await store.changeAddress("https://another.example"); await store.search("one")
        XCTAssertEqual(client.searchCalls.count, 10)
    }
    func testCachedNavigationCancelsPendingNetworkAndRejectsLateResults() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        client.popularBooks = [book]; await store.loadPopular()
        var pending: CheckedContinuation<ZLibrarySearchPage, Error>?
        client.searchHandler = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let task = Task { await store.search("pending") }; try await eventually { pending != nil }
        await store.loadPopular(); XCTAssertEqual(store.books, [book]); XCTAssertFalse(store.loading)
        pending?.resume(returning: ZLibrarySearchPage(books: [], hasMore: false)); await task.value
        XCTAssertEqual(store.books, [book]); XCTAssertTrue(store.activeQuery.isEmpty)
        XCTAssertEqual(client.popularSessions.count, 1); XCTAssertNil(store.error)
    }
    func testAccessCheckRefreshKeepsSavedResultsAndDoesNotRetryAutomatically() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let connected = await store.connect(session); XCTAssertTrue(connected)
        client.popularBooks = [book]; await store.loadPopular()
        client.popularError = ZLibraryRequestFailure(issue: .accessCheck, diagnostic: "GET /eapi/book/most-popular · HTTP 307")
        await store.reload()
        XCTAssertEqual(store.books, [book]); XCTAssertTrue(store.showingSavedResults)
        XCTAssertTrue(store.websiteAccessNeeded); XCTAssertTrue(store.connected)
        XCTAssertTrue(store.error?.contains("browser access check") == true)
        XCTAssertEqual(client.popularSessions.count, 2)
        await store.search("different"); await store.loadPopular()
        XCTAssertEqual(client.popularSessions.count, 2); XCTAssertEqual(store.books, [book])
        XCTAssertNil(store.error); XCTAssertTrue(store.showingSavedResults)
        client.popularError = nil; await store.reload()
        XCTAssertEqual(client.popularSessions.count, 3); XCTAssertFalse(store.showingSavedResults)
    }
    func testResolvedDetailsSurviveReturningToSavedSearch() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let sparse = ZLibraryBook(remoteID: book.remoteID, hash: book.hash, title: book.title, author: "", fileExtension: "", size: "", language: "", year: "", coverURL: nil)
        client.searchHandler = { _, _ in ZLibrarySearchPage(books: [sparse], hasMore: false) }
        client.detailHandler = { [self] _ in book }
        await store.search("sparse")
        let resolved = try await store.details(sparse); XCTAssertEqual(resolved, book)
        await store.loadPopular(); await store.search("sparse")
        XCTAssertEqual(store.books, [book]); XCTAssertEqual(client.detailCalls, 1)
        XCTAssertEqual(client.searchCalls.count, 1)
    }
    func testLiveShapedPOSTAccessCheckMakesOnlyOneRequestAndPreservesAccount() async throws {
        let transport = CatalogTransport { [self] request, _ in
            if request.url!.path == "/eapi/user/profile" { return try response(["success": 1, "user": ["id": 42]]) }
            XCTAssertEqual(request.httpMethod, "POST")
            return ZLibraryPayload(data: Data(), file: nil, response: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: ["Location": request.url!.absoluteString, "Set-Cookie": "__diamwall=private-value; Path=/"])!)
        }
        let (store, _, _) = store(ZLibraryClient(transport: transport))
        let connected = await store.connect(session); XCTAssertTrue(connected)
        await store.search("private query")
        XCTAssertTrue(store.websiteAccessNeeded); XCTAssertTrue(store.connected)
        XCTAssertTrue(store.error?.contains("browser access check") == true)
        XCTAssertTrue(store.requestDiagnostic?.contains("access-check marker: DiamWall") == true)
        XCTAssertEqual(transport.requests.count, 2) // Profile plus exactly one search, no loop.
        XCTAssertFalse(store.requestDiagnostic?.contains("private-") ?? true)
    }
    func testSearchSuccessThenClearReportsIndependentPopular307WithoutSigningOut() async throws {
        var popularCalls = 0
        let row: [String: Any] = ["id": 12, "hash": "ab1234", "title": "A test book", "author": "Test author", "extension": "epub"]
        let transport = CatalogTransport { [self] request, _ in
            switch request.url!.path {
            case "/eapi/user/profile": return try response(["success": 1, "user": ["id": 42, "name": "Test reader"]])
            case "/eapi/book/search":
                XCTAssertEqual(request.httpMethod, "POST")
                return try response(["success": 1, "books": [row]])
            default:
                popularCalls += 1
                XCTAssertEqual(request.url!.path, "/eapi/book/most-popular")
                XCTAssertEqual(request.httpMethod, "GET")
                if popularCalls == 1 { return try response(["success": 1, "books": [row]]) }
                return ZLibraryPayload(data: Data(), file: nil,
                    response: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                        headerFields: ["Location": request.url!.absoluteString, "Set-Cookie": "__diamwall=fixture-only; Path=/"])!)
            }
        }
        let (store, _, _) = store(ZLibraryClient(transport: transport))
        let connected = await store.connect(session); XCTAssertTrue(connected)
        await store.loadPopular(); XCTAssertEqual(store.books.count, 1)
        await store.search("test book"); XCTAssertEqual(store.books.count, 1); XCTAssertNil(store.error)
        await store.loadPopular()
        XCTAssertEqual(popularCalls, 1); XCTAssertTrue(store.showingSavedResults)
        await store.reload() // Explicit refresh still surfaces the real access check.
        XCTAssertTrue(store.activeQuery.isEmpty); XCTAssertTrue(store.connected)
        XCTAssertTrue(store.websiteAccessNeeded); XCTAssertEqual(store.books.count, 1)
        XCTAssertTrue(store.requestDiagnostic?.contains("HTTP 307") == true)
        XCTAssertTrue(store.requestDiagnostic?.contains("same URL refused") == true)
        await store.search("test book")
        XCTAssertEqual(store.books.count, 1); XCTAssertNil(store.error); XCTAssertNil(store.requestDiagnostic)
    }
    func testFailureDiagnosticsExcludeBodiesCookiesQueriesAndAccountDetails() async throws {
        let transport = CatalogTransport { request,_ in
            ZLibraryPayload(data:Data("<html>reader@example.test account-secret</html>".utf8),file:nil,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/html","Set-Cookie":"private=secret"])!)
        }
        do { _ = try await ZLibraryClient(transport:transport).popular(origin:origin,session:session);XCTFail("HTML accepted") }
        catch {
            let failure = try XCTUnwrap(error as? ZLibraryRequestFailure)
            XCTAssertEqual(failure.issue,.challenge)
            XCTAssertEqual(failure.diagnostic,"GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
            for value in ["reader@", "account-secret", "private", "test-only-session"] { XCTAssertFalse(failure.diagnostic.contains(value)) }
        }
    }
    func testHTMLAndRedirectsAreChallengesAndExpiredSessionIsDistinct() throws {
        let html = ZLibraryPayload(data:Data("<!DOCTYPE html><html>Verification</html>".utf8),file:nil,response:HTTPURLResponse(url:origin.url,statusCode:200,httpVersion:nil,headerFields:[:])!)
        XCTAssertThrowsError(try ZLibraryClient.decode(html)) { XCTAssertEqual($0 as? ZLibraryError,.challenge) }
        XCTAssertThrowsError(try ZLibraryClient.decode(response(["success":0,"error":"Please login"],status:400))) { XCTAssertEqual($0 as? ZLibraryError,.signInRequired) }
        XCTAssertThrowsError(try ZLibraryClient.decode(response(["success":0,"error":"Daily download limit reached"],status:400))) { XCTAssertEqual($0 as? ZLibraryError,.service("Daily download limit reached")) }
        XCTAssertThrowsError(try ZLibraryClient.decode(response(["success":1],status:307))) { XCTAssertEqual($0 as? ZLibraryError,.challenge) }
    }
    func testProfileValidatesIdentityAndBothQuotaSchemas() async throws {
        let transport = CatalogTransport { [self] _,_ in try response(["success":1,"user":["id":42,"email":"reader@example.test","dailyDownloadsCount":"2","dailyDownloadLimit":5]]) }
        let profile = try await ZLibraryClient(transport:transport).profile(origin:origin,session:session)
        XCTAssertEqual(profile.remaining,3)
        transport.handler = { [self] _,_ in try response(["success":1,"user":["id":99]]) }
        do { _ = try await ZLibraryClient(transport:transport).profile(origin:origin,session:session);XCTFail("Wrong account accepted") } catch { XCTAssertEqual(error as? ZLibraryError,.response) }
    }
    func testSignedCDNDownloadHasNoAccountHeadersAndKeepsBookOnDisk() async throws {
        let temp = try temporaryFolder("LeafZLibraryTests").appendingPathComponent("download.part");try Data([0x50,0x4b,0x03,0x04,1,2,3]).write(to:temp)
        let transport = CatalogTransport { [self] request,toFile in
            if !toFile { return try response(["success":1,"file":["downloadLink":"https://cdn.example/book?signature=abc"]]) }
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(request.value(forHTTPHeaderField:"remix-userkey"));XCTAssertEqual(request.url?.host,"cdn.example")
            return ZLibraryPayload(data:Data(),file:temp,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        }
        let file = try await ZLibraryClient(transport:transport).download(book,origin:origin,session:session,progress:{_ in})
        XCTAssertEqual(file.pathExtension,"epub");XCTAssertFalse(FileManager.default.fileExists(atPath:temp.path));XCTAssertEqual(try Data(contentsOf:file).count,7)
    }
    func testSameOriginDownloadAuthenticatesAndHTTPLinkIsRejected() async throws {
        let temp = try temporaryFolder("LeafZLibraryTests").appendingPathComponent("download.part");try Data([0x50,0x4b,0x03,0x04]).write(to:temp)
        let transport = CatalogTransport { [self] request,toFile in
            if !toFile { return try response(["success":1,"downloadLink":"/download/file"]) }
            XCTAssertEqual(request.value(forHTTPHeaderField:"remix-userkey"),session.userKey)
            return ZLibraryPayload(data:Data(),file:temp,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        }
        _ = try await ZLibraryClient(transport:transport).download(book,origin:origin,session:session,progress:{_ in})
        transport.handler = { [self] _,_ in try response(["success":1,"downloadLink":"http://cdn.example/book"]) }
        do { _ = try await ZLibraryClient(transport:transport).download(book,origin:origin,session:session,progress:{_ in});XCTFail("HTTP download accepted") } catch { XCTAssertEqual(error as? ZLibraryError,.response) }
    }
    func testRedirectPolicyNeverCarriesCredentialsToCDNOrHTTP() throws {
        var request = URLRequest(url:URL(string:"https://cdn.example/file")!)
        for name in ["Cookie","Authorization","remix-userid","remix-userkey"] { request.setValue("secret",forHTTPHeaderField:name) }
        let forwarded = try XCTUnwrap(ZLibraryHTTPTransport.redirect(request,original:origin.url,toFile:true))
        for name in ["Cookie","Authorization","remix-userid","remix-userkey"] { XCTAssertNil(forwarded.value(forHTTPHeaderField:name)) }
        XCTAssertNil(ZLibraryHTTPTransport.redirect(request,original:origin.url,toFile:false))
        request.url = URL(string:"http://catalog.example/file")
        XCTAssertNil(ZLibraryHTTPTransport.redirect(request,original:origin.url,toFile:true))
    }
    func testRejectedDownloadRemovesTemporaryFile() async throws {
        let temp = try temporaryFolder("LeafZLibraryTests").appendingPathComponent("download.part");try Data("<!DOCTYPE html><html>Please login</html>".utf8).write(to:temp)
        let transport = CatalogTransport { [self] request,toFile in
            if !toFile { return try response(["success":1,"downloadLink":"https://cdn.example/file"]) }
            return ZLibraryPayload(data:Data(),file:temp,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        }
        do { _ = try await ZLibraryClient(transport:transport).download(book,origin:origin,session:session,progress:{_ in});XCTFail("HTML accepted as EPUB") } catch { XCTAssertEqual(error as? ZLibraryError,.challenge) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:temp.path))
    }
    func testTransportBoundsJSONAndRejectsOversizedFileHeader() async throws {
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [CatalogURLProtocol.self]
        CatalogURLProtocol.expected = nil;CatalogURLProtocol.remainOpen = false;CatalogURLProtocol.body = Data(repeating:1,count:2*1024*1024+1)
        defer { CatalogURLProtocol.body = Data();CatalogURLProtocol.expected = nil }
        let transport = ZLibraryHTTPTransport(configuration:config)
        do { _ = try await transport.send(URLRequest(url:origin.url),toFile:false,progress:{_ in});XCTFail("Unbounded response accepted") } catch { XCTAssertEqual(error as? ZLibraryError,.response) }
        CatalogURLProtocol.body = Data();CatalogURLProtocol.expected = 101*1024*1024
        do { _ = try await transport.send(URLRequest(url:origin.url),toFile:true,progress:{_ in});XCTFail("Oversized book accepted") } catch { XCTAssertEqual(error as? ZLibraryError,.size) }
    }
    func testCancellingTransportStopsRequestAndRemovesPartialFile() async throws {
        let files = { Set((try? FileManager.default.contentsOfDirectory(atPath:FileManager.default.temporaryDirectory.path)) ?? []) }
        let before = files(), config = URLSessionConfiguration.ephemeral;config.protocolClasses = [CatalogURLProtocol.self]
        CatalogURLProtocol.body = Data([0x50,0x4b,0x03,0x04]);CatalogURLProtocol.expected = nil;CatalogURLProtocol.remainOpen = true;CatalogURLProtocol.stopped = false
        let received = expectation(description: "Partial file received before cancellation")
        let stopped = expectation(description: "URL protocol stopped after cancellation")
        CatalogURLProtocol.onStop = { stopped.fulfill() }
        defer { CatalogURLProtocol.body = Data();CatalogURLProtocol.remainOpen = false;CatalogURLProtocol.onStop = nil }
        let transport = ZLibraryHTTPTransport(configuration:config)
        let task = Task { try await transport.send(URLRequest(url:origin.url),toFile:true,progress:{_ in received.fulfill()}) }
        await fulfillment(of: [received], timeout: 3)
        task.cancel()
        do { _ = try await task.value;XCTFail("Cancelled download completed") } catch {}
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(CatalogURLProtocol.stopped)
        XCTAssertTrue(files().subtracting(before).filter { $0.hasPrefix("LeafDownload-") }.isEmpty)
    }
    func testConnectionSurvivesRelaunchButIsRevalidated() async throws {
        let client = CatalogService(), (store,credentials,defaults) = store(client)
        XCTAssertFalse(store.connected)
        let connected = await store.connect(session);XCTAssertTrue(connected)
        XCTAssertEqual(store.remaining,3)
        let restored = ZLibraryStore(defaults:defaults,credentials:credentials,client:client)
        XCTAssertFalse(restored.connected)
        await restored.loadPopular();XCTAssertTrue(restored.connected);XCTAssertEqual(client.profiles,2)
        XCTAssertFalse(credentials.values.values.contains { $0.contains("password") })
    }
    func testRejectedReconnectPreservesExistingConnectionAndKeychainFailureIsNotSuccess() async throws {
        let client = CatalogService(), (store,credentials,_) = store(client)
        _ = await store.connect(session);let saved = credentials.values
        client.profileError = CancellationError()
        let connected = await store.connect(ZLibrarySession(userID:"42",userKey:"replacement"))
        XCTAssertFalse(connected);XCTAssertTrue(store.connected);XCTAssertEqual(credentials.values,saved)
        XCTAssertNil(store.connectionError)
        client.profileError = nil;credentials.failWrites = true
        let next = await store.connect(ZLibrarySession(userID:"42",userKey:"other"))
        XCTAssertFalse(next);XCTAssertEqual(credentials.values,saved)
    }
    func testDisconnectWhileConnectionPendingCannotResurrectSession() async throws {
        let client = CatalogService(), (store,credentials,_) = store(client)
        client.suspendProfile = true
        let task = Task { await store.connect(session) }
        try await eventually { client.continuation != nil }
        try await store.disconnect()
        client.continuation?.resume(returning:ZLibraryProfile(name:"Old response",remaining:2))
        let connected = await task.value;XCTAssertFalse(connected);XCTAssertFalse(store.connected);XCTAssertTrue(credentials.values.isEmpty)
    }
    func testOnlyConfiguredWebsiteCookiesCanConnectAndSecureFlagIsNotAssumed() throws {
        let (store,_,_) = store()
        func cookie(_ name:String,_ domain:String,_ secure:Bool = true)->HTTPCookie {
            var properties: [HTTPCookiePropertyKey:Any] = [.domain:domain,.path:"/",.name:name,.value:name == "remix_userid" ? "42":"secret"]
            if secure { properties[.secure] = "TRUE" }
            return HTTPCookie(properties:properties)!
        }
        XCTAssertNotNil(store.cookieCandidate([cookie("remix_userid","catalog.example"),cookie("remix_userkey",".catalog.example")]))
        XCTAssertNil(store.cookieCandidate([cookie("remix_userid","evil.example"),cookie("remix_userkey","evil.example")]))
        XCTAssertNotNil(store.cookieCandidate([cookie("remix_userid","catalog.example"),cookie("remix_userkey","catalog.example",false)]))
    }
    func testVerifiedWebsiteContextIsCapturedForOnlyConfiguredHostAndSurvivesRelaunch() async throws {
        let client = CatalogService(), (store,credentials,defaults) = store(client)
        func cookie(_ name: String,_ value: String,_ domain: String = "catalog.example",_ path: String = "/") -> HTTPCookie {
            HTTPCookie(properties:[.domain:domain,.path:path,.name:name,.value:value,.secure:"TRUE"])!
        }
        store.captureWebsiteUserAgent("Browser identity/1.0")
        let candidate = try XCTUnwrap(store.cookieCandidate([
            cookie("remix_userid","42"),cookie("remix_userkey","key"),cookie("site_access","opaque"),cookie("other_account","private","other.example")
        ]))
        XCTAssertEqual(candidate.websiteCookies?.map(\.name),["site_access"])
        XCTAssertEqual(candidate.userAgent,"Browser identity/1.0")
        let connected = await store.connect(candidate);XCTAssertTrue(connected)
        let restored = ZLibraryStore(defaults:defaults,credentials:credentials,client:client)
        await restored.loadPopular()
        XCTAssertTrue(restored.connected)
        XCTAssertEqual(client.popularSessions.last!,candidate)
        await restored.seedWebsite()
        let seeded = await restored.websiteData.httpCookieStore.allCookies()
        XCTAssertEqual(seeded.first { $0.name == "site_access" }?.value,"opaque")
        XCTAssertTrue(seeded.allSatisfy { $0.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")) == "catalog.example" })
    }
    func testNewStoreRestoresNewerBrowserCookiesWithoutOpeningWebsiteOrCheckingConnection() async throws {
        let client = CatalogService(), (first, credentials, defaults) = store(client)
        let old = ZLibrarySession(userID: "42", userKey: "key", websiteCookies: [
            ZLibraryWebsiteCookie(name: "site_access", value: "old", path: "/", expires: nil)
        ], userAgent: "Browser identity/1.0")
        let connected = await first.connect(old); XCTAssertTrue(connected)
        await first.seedWebsite()
        let fresh = try XCTUnwrap(HTTPCookie(properties: [.domain: "catalog.example", .path: "/", .name: "site_access", .value: "refreshed", .secure: "TRUE"]))
        await first.websiteData.httpCookieStore.setCookie(fresh)
        // Restore an independently-created Store without opening the website.
        let restored = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        XCTAssertTrue(restored.websiteData.isPersistent)
        await restored.seedWebsite() // Opening the website must not clobber fresher cookies either.
        let browserCookies = await restored.websiteData.httpCookieStore.allCookies()
        XCTAssertEqual(browserCookies.first { $0.name == "site_access" }?.value, "refreshed")
        await restored.loadPopular()
        let request = try XCTUnwrap(client.popularSessions.last ?? nil)
        XCTAssertEqual(request.websiteCookies?.first?.value, "refreshed")
        XCTAssertEqual(request.userAgent, "Browser identity/1.0")
        XCTAssertTrue(restored.connected); XCTAssertNil(restored.error)
        let third = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        await third.loadPopular()
        XCTAssertEqual(client.popularSessions.last!, request)
        try await third.disconnect()
        let remaining = await third.websiteData.httpCookieStore.allCookies()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(credentials.values[origin.url.absoluteString])
    }
    func testRestorationNeverAdoptsDifferentBrowserAccountAndKeepsOriginIsolation() async throws {
        let client = CatalogService(), (first, credentials, defaults) = store(client)
        _ = await first.connect(session)
        await first.seedWebsite()
        for (name, value) in [("remix_userid", "different"), ("remix_userkey", "other-key")] {
            await first.websiteData.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [.domain: "catalog.example", .path: "/", .name: name, .value: value])))
        }
        let restored = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        await restored.loadPopular()
        XCTAssertEqual(client.popularSessions.last!, session)
        await restored.seedWebsite()
        let cookies = await restored.websiteData.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.first { $0.name == "remix_userid" }?.value, "42")
        let firstID = defaults.string(forKey: "zlibrary.websiteData.https://catalog.example")
        try await restored.changeAddress("https://other.example")
        let otherCookies = await restored.websiteData.httpCookieStore.allCookies()
        XCTAssertTrue(otherCookies.isEmpty)
        XCTAssertNotEqual(firstID, defaults.string(forKey: "zlibrary.websiteData.https://other.example"))
    }
    func testDisconnectClearsPersistedWebsiteEvenBeforeItIsOpenedOnThisLaunch() async throws {
        let client = CatalogService(), (first, credentials, defaults) = store(client)
        _ = await first.connect(session)
        await first.seedWebsite()
        let restored = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        try await restored.disconnect()
        let cookies = await restored.websiteData.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
        let relaunched = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        await relaunched.loadPopular()
        XCTAssertFalse(relaunched.connected)
        XCTAssertNil(client.popularSessions.last!)
    }
    func testLockedKeychainAtLaunchRetriesSavedConnectionOnUse() async throws {
        let client = CatalogService(), (_, credentials, defaults) = store(client)
        credentials.values[origin.url.absoluteString] = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        credentials.failReads = true
        let restored = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        XCTAssertNotNil(restored.connectionError)
        credentials.failReads = false
        await restored.loadPopular()
        XCTAssertTrue(restored.connected); XCTAssertNil(restored.connectionError)
        XCTAssertEqual(client.popularSessions.last!, session)
    }
    func testNewBrowserIdentityIsNotOverwrittenByOlderSavedSnapshotDuringReload() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let saved = ZLibrarySession(userID: "42", userKey: "key", userAgent: "Older browser")
        _ = await store.connect(saved)
        store.captureWebsiteUserAgent("Current browser")
        await store.loadPopular()
        XCTAssertEqual((client.popularSessions.last ?? nil)?.userAgent, "Current browser")
    }
    func testFailedBrowserSnapshotPreservesSavedSessionForNextAttempt() async throws {
        let client = CatalogService(), (store, credentials, _) = store(client)
        _ = await store.connect(session)
        await store.seedWebsite()
        let saved = credentials.values
        credentials.failWrites = true
        await store.websiteData.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [.domain: "catalog.example", .path: "/", .name: "site_access", .value: "new"])))
        do { try await store.saveWebsiteContext(); XCTFail("Snapshot write should fail") } catch {}
        XCTAssertEqual(credentials.values, saved)
        credentials.failWrites = false
        await store.loadPopular()
        XCTAssertEqual((client.popularSessions.last ?? nil)?.websiteCookies?.first?.value, "new")
    }
    func testConnectedFeedFailureKeepsAccountAndWebsiteRefreshDoesNotRequireAnotherLogin() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        _ = await store.connect(session)
        client.popularError = ZLibraryRequestFailure(issue:.challenge,diagnostic:"GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        await store.loadPopular()
        XCTAssertTrue(store.connected);XCTAssertTrue(store.websiteAccessNeeded)
        XCTAssertTrue(store.error?.hasPrefix("Your account is connected") == true)
        XCTAssertNotNil(store.requestDiagnostic)
        await store.seedWebsite()
        await store.websiteData.httpCookieStore.setCookie(HTTPCookie(properties:[.domain:"catalog.example",.path:"/",.name:"site_access",.value:"fresh",.secure:"TRUE"])!)
        store.captureWebsiteUserAgent("Browser identity")
        client.popularError = nil
        await store.loadPopular()
        XCTAssertTrue(store.connected);XCTAssertNil(store.error);XCTAssertNil(store.requestDiagnostic);XCTAssertFalse(store.websiteAccessNeeded)
        XCTAssertEqual(client.profiles,1,"Refreshing browser context must not make the user sign in again")
        let refreshed = try XCTUnwrap(client.popularSessions.last ?? nil)
        XCTAssertEqual(refreshed.websiteCookies?.first?.value,"fresh")
        let expired = ZLibraryRequestFailure(issue:.signInRequired,diagnostic:"GET /eapi/book/most-popular · HTTP 401 · JSON/API response")
        client.popularError = expired
        await store.reload() // Explicit refresh, rather than restoring navigation state.
        XCTAssertFalse(store.connected);XCTAssertFalse(store.websiteAccessNeeded)
    }
    func testCancelledRefreshCallerCannotEmptyTheCatalogOrHideItsError() async throws {
        let client = CatalogService(), (store, _, _) = store(client)
        let failure = ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        client.popularError = failure
        await store.loadPopular()
        XCTAssertNotNil(store.error)
        client.popularError = nil; client.suspendPopular = true
        // SwiftUI cancels a refresh task when the content it shows changes (QA76-002).
        let refresh = Task { await store.reload() }
        try await eventually { client.popularContinuation != nil }
        refresh.cancel()
        client.popularContinuation?.resume(throwing: failure)
        await refresh.value
        XCTAssertNotNil(store.error, "The refreshed failure must be shown, not an empty catalog")
        XCTAssertEqual(store.requestDiagnostic, failure.diagnostic)
        XCTAssertFalse(store.loading)
        client.suspendPopular = false; client.popularBooks = [book]
        let again = Task { await store.reload() }
        again.cancel(); await again.value
        XCTAssertEqual(store.books, [book]); XCTAssertNil(store.error)
    }
    func testAnonymousFeedFailureCannotUndoACompletedSignIn() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        client.suspendPopular = true
        let load = Task { await store.loadPopular() }
        try await eventually { client.popularContinuation != nil }
        let connected = await store.connect(session);XCTAssertTrue(connected)
        client.popularContinuation?.resume(throwing:ZLibraryError.signInRequired)
        await load.value
        XCTAssertTrue(store.connected);XCTAssertNil(store.error);XCTAssertFalse(store.loading)
    }
    func testExistingFileImportIsLinkedWithoutLosingPassageBookmarksOrChatIdentity() async throws {
        let root = try temporaryFolder("LeafZLibraryTests"), file = root.appendingPathComponent("original.txt")
        try Data("A passage to keep.".utf8).write(to:file)
        let library = LibraryStore(root:root.appendingPathComponent("Library"),seedSamples:false)
        await library.importBooks([file]);let original = try XCTUnwrap(library.books.first)
        library.setPosition(original.id,locator:"saved-passage",fraction:0.4)
        library.toggleBookmark(original.id,locator:"saved-passage",fraction:0.4,label:"Here")
        let linked = try await library.importCatalogBook(file,catalogID:"zlibrary:12:hash",title:"Other title",author:"Other author")
        XCTAssertEqual(library.books.count,1);XCTAssertEqual(linked.id,original.id);XCTAssertEqual(linked.fingerprint,original.fingerprint)
        XCTAssertEqual(linked.locator,"saved-passage");XCTAssertEqual(linked.bookmarks.count,1)
        let reopened = LibraryStore(root:root.appendingPathComponent("Library"),seedSamples:false)
        XCTAssertEqual(reopened.books.first?.catalogSource,"zlibrary:12:hash")
    }
    func testNewCatalogBookExtractsCoverAndPersistsSourceBeforeSuccess() async throws {
        let root = try temporaryFolder("LeafZLibraryTests")
        let source = try XCTUnwrap(Bundle(for:type(of:self)).url(forResource:"Covered.epub",withExtension:nil,subdirectory:"Fixtures"))
        let library = LibraryStore(root:root,seedSamples:false)
        let imported = try await library.importCatalogBook(source,catalogID:"zlibrary:new:edition",title:"Catalog title",author:"Catalog author")
        XCTAssertEqual(library.books.count,1)
        XCTAssertEqual(imported.title,"书封面 · Imported")
        XCTAssertEqual(imported.author,"林海")
        XCTAssertEqual(imported.catalogSource,"zlibrary:new:edition")
        XCTAssertNil(imported.lastOpenedAt);XCTAssertEqual(imported.locator,"")
        let cover = try XCTUnwrap(library.coverURL(imported))
        XCTAssertTrue(FileManager.default.fileExists(atPath:cover.path))
        let restored = LibraryStore(root:root,seedSamples:false)
        XCTAssertEqual(restored.books.first?.catalogSource,imported.catalogSource)
        XCTAssertEqual(restored.books.first?.coverFileName,imported.coverFileName)
    }
    func testQuotaStopsDownloadBeforeFileRequest() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        _ = await store.connect(session);client.remaining = 0
        let library = LibraryStore(root:try temporaryFolder("LeafZLibraryTests"),seedSamples:false)
        store.add(book,library:library)
        try await eventually { store.downloadingID == nil }
        XCTAssertEqual(client.downloads,0);XCTAssertNotNil(store.importError);XCTAssertTrue(library.books.isEmpty)
    }
}

/// These two phases can also be run in separate xcodebuild invocations with an
/// in-place simctl install between them, exercising a real app-container upgrade.
@MainActor final class ZLibrarySessionUpgradeTests: XCTestCase {
    private let suite = "com.leafreader.tests.catalogUpgrade"
    private let credentials = KeychainChatCredentials(service: "com.leafreader.tests.catalogUpgrade")
    private let source = try! ZLibraryOrigin("https://upgrade.example")
    func test01PrepareSavedConnectionAndLifecycleSnapshot() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        let oldStore = ZLibraryStore(defaults: defaults, credentials: credentials, client: CatalogService())
        try await oldStore.disconnect()
        defaults.removePersistentDomain(forName: suite)
        defaults.set(source.url.absoluteString, forKey: "zlibrary.origin")
        let store = ZLibraryStore(defaults: defaults, credentials: credentials, client: CatalogService())
        let session = ZLibrarySession(userID: "42", userKey: "upgrade-fixture", websiteCookies: [
            ZLibraryWebsiteCookie(name: "site_access", value: "older-snapshot", path: "/", expires: nil)
        ], userAgent: "Upgrade fixture browser/1.0")
        let connected = await store.connect(session); XCTAssertTrue(connected)
        await store.seedWebsite()
        await store.websiteData.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [
            .domain: "upgrade.example", .path: "/", .name: "site_access", .value: "latest-browser-context", .secure: "TRUE"
        ])))
        // The same hook runs on website finish, dismissal, and scene backgrounding.
        // It must persist session-only cookies without an explicit Check connection.
        try await store.saveWebsiteContext()
        await store.websiteData.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [
            .domain: "upgrade.example", .path: "/", .name: "persistent_only", .value: "website-storage", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)
        ])))
        defaults.synchronize()
        let saved = try XCTUnwrap(credentials.read(account: source.url.absoluteString))
        XCTAssertTrue(saved.contains("latest-browser-context"), "Lifecycle snapshot must save refreshed cookies without Check connection")
        XCTAssertFalse(saved.contains("persistent_only"), "This cookie must be recovered from WebKit, not Keychain")
    }
    func test02RestoreAfterAppReplacementWithoutWebsiteOrCheckConnection() async throws {
        let defaults = UserDefaults(suiteName: suite)!, client = CatalogService()
        XCTAssertEqual(defaults.string(forKey: "zlibrary.origin"), source.url.absoluteString)
        let store = ZLibraryStore(defaults: defaults, credentials: credentials, client: client)
        await store.loadPopular()
        let restored = try XCTUnwrap(client.popularSessions.last ?? nil)
        XCTAssertEqual(restored.websiteCookies?.first { $0.name == "site_access" }?.value, "latest-browser-context")
        XCTAssertEqual(restored.websiteCookies?.first { $0.name == "persistent_only" }?.value, "website-storage")
        XCTAssertEqual(restored.userAgent, "Upgrade fixture browser/1.0")
        XCTAssertTrue(store.connected); XCTAssertNil(store.error)
        try await store.disconnect()
        let empty = await store.websiteData.httpCookieStore.allCookies()
        XCTAssertTrue(empty.isEmpty)
    }
}
