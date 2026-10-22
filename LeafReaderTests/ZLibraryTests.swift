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
private final class CatalogService: ZLibraryServing {
    var profileError: Error?
    var downloadError: Error?
    var profiles = 0
    var downloads = 0
    var suspendProfile = false
    var continuation: CheckedContinuation<ZLibraryProfile,Error>?
    var remaining: Int? = 3
    var file: URL?
    var suspendPopular = false
    var popularContinuation: CheckedContinuation<[ZLibraryBook],Error>?
    func profile(origin:ZLibraryOrigin,session:ZLibrarySession) async throws -> ZLibraryProfile {
        profiles += 1
        if suspendProfile { return try await withCheckedThrowingContinuation { continuation = $0 } }
        if let profileError { throw profileError }
        return ZLibraryProfile(name:"Test reader",remaining:remaining)
    }
    func popular(origin:ZLibraryOrigin,session:ZLibrarySession?) async throws -> [ZLibraryBook] {
        if suspendPopular { return try await withCheckedThrowingContinuation { popularContinuation = $0 } }
        return []
    }
    func download(_ book:ZLibraryBook,origin:ZLibraryOrigin,session:ZLibrarySession,progress:@escaping @Sendable (Double?)->Void) async throws -> URL {
        downloads += 1;if let downloadError { throw downloadError };guard let file else { throw ZLibraryError.file };return file
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
    private func store(_ client:CatalogService = CatalogService()) -> (ZLibraryStore,CatalogCredentials,UserDefaults) {
        let name = "LeafZLibraryTests.\(UUID())", defaults = UserDefaults(suiteName:name)!, credentials = CatalogCredentials()
        addTeardownBlock { defaults.removePersistentDomain(forName:name) }
        defaults.set(origin.url.absoluteString,forKey:"zlibrary.origin")
        return (ZLibraryStore(defaults:defaults,credentials:credentials,client:client),credentials,defaults)
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
