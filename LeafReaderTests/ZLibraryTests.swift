import XCTest
import WebKit
@testable import LeafReader

private final class CatalogCredentials: ChatCredentialStore {
    var values: [String:String] = [:]
    var failWrites = false
    func read(account:String) throws -> String? { values[account] }
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
        return []
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
    override func stopLoading() { Self.stopped = true }
}

@MainActor final class ZLibraryTests: XCTestCase {
    private let session = ZLibrarySession(userID:"42",userKey:"test-only-session")
    private var origin: ZLibraryOrigin { try! ZLibraryOrigin("https://catalog.example") }
    private var book: ZLibraryBook { ZLibraryBook(remoteID:"12",hash:"ab1234",title:"A test book",author:"Test author",fileExtension:"epub",size:"1 MB",language:"English",year:"1900",coverURL:nil) }
    private func response(_ value:Any,url:URL?=nil,status:Int=200) throws -> ZLibraryPayload {
        ZLibraryPayload(data:try JSONSerialization.data(withJSONObject:value),file:nil,response:HTTPURLResponse(url:url ?? origin.url,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
    }
    private func store(_ client:CatalogService? = nil) -> (ZLibraryStore,CatalogCredentials,UserDefaults) {
        let name = "LeafZLibraryTests.\(UUID())", defaults = UserDefaults(suiteName:name)!, credentials = CatalogCredentials()
        addTeardownBlock { defaults.removePersistentDomain(forName:name) }
        defaults.set(origin.url.absoluteString,forKey:"zlibrary.origin")
        return (ZLibraryStore(defaults:defaults,credentials:credentials,client:client ?? CatalogService()),credentials,defaults)
    }
    private func wait(_ predicate:()->Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(),Date()<deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(predicate())
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
        try await wait { pending != nil }
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
        await restored.disconnect();XCTAssertEqual(restored.searchOrder,.titleAscending)
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
        try await wait { started }
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
        try await wait { continuation != nil }
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
        XCTAssertEqual(store.activeQuery,"author query");XCTAssertTrue(store.books.isEmpty)
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
        try await wait { continuation != nil }
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
        let temp = try folder().appendingPathComponent("download.part");try Data([0x50,0x4b,0x03,0x04,1,2,3]).write(to:temp)
        let transport = CatalogTransport { [self] request,toFile in
            if !toFile { return try response(["success":1,"file":["downloadLink":"https://cdn.example/book?signature=abc"]]) }
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"));XCTAssertNil(request.value(forHTTPHeaderField:"remix-userkey"));XCTAssertEqual(request.url?.host,"cdn.example")
            return ZLibraryPayload(data:Data(),file:temp,response:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!)
        }
        let file = try await ZLibraryClient(transport:transport).download(book,origin:origin,session:session,progress:{_ in})
        XCTAssertEqual(file.pathExtension,"epub");XCTAssertFalse(FileManager.default.fileExists(atPath:temp.path));XCTAssertEqual(try Data(contentsOf:file).count,7)
    }
    func testSameOriginDownloadAuthenticatesAndHTTPLinkIsRejected() async throws {
        let temp = try folder().appendingPathComponent("download.part");try Data([0x50,0x4b,0x03,0x04]).write(to:temp)
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
        let temp = try folder().appendingPathComponent("download.part");try Data("<!DOCTYPE html><html>Please login</html>".utf8).write(to:temp)
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
        defer { CatalogURLProtocol.body = Data();CatalogURLProtocol.remainOpen = false }
        let transport = ZLibraryHTTPTransport(configuration:config)
        let task = Task { try await transport.send(URLRequest(url:origin.url),toFile:true,progress:{_ in}) }
        try await Task.sleep(for:.milliseconds(100));task.cancel()
        do { _ = try await task.value;XCTFail("Cancelled download completed") } catch {}
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
        try await wait { client.continuation != nil }
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
        await store.loadPopular()
        XCTAssertFalse(store.connected);XCTAssertFalse(store.websiteAccessNeeded)
    }
    func testAnonymousFeedFailureCannotUndoACompletedSignIn() async throws {
        let client = CatalogService(), (store,_,_) = store(client)
        client.suspendPopular = true
        let load = Task { await store.loadPopular() }
        try await wait { client.popularContinuation != nil }
        let connected = await store.connect(session);XCTAssertTrue(connected)
        client.popularContinuation?.resume(throwing:ZLibraryError.signInRequired)
        await load.value
        XCTAssertTrue(store.connected);XCTAssertNil(store.error);XCTAssertFalse(store.loading)
    }
    func testExistingFileImportIsLinkedWithoutLosingPassageBookmarksOrChatIdentity() async throws {
        let root = try folder(), file = root.appendingPathComponent("original.txt")
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
        let root = try folder()
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
        let library = LibraryStore(root:try folder(),seedSamples:false)
        store.add(book,library:library)
        try await wait { store.downloadingID == nil }
        XCTAssertEqual(client.downloads,0);XCTAssertNotNil(store.importError);XCTAssertTrue(library.books.isEmpty)
    }
}
