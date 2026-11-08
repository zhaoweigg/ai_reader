import XCTest
import WebKit
import Network
@testable import LeafReader

// Only loopback traffic. These tests exercise WebKit's actual HTTP/cookie behavior,
// not a replacement fetch function or the live book provider.
private final class CatalogLoopbackServer: @unchecked Sendable {
    struct Request { let path: String; let headers: [String: String]; let body: String }
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = "{\"success\":1}"
        var delay: TimeInterval = 0
        /// Closes the connection without answering, as a dropped request looks to WebKit.
        var drop = false
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Leaf.catalog.loopback")
    private let lock = NSLock()
    private var received: [Request] = []
    private var connections: [NWConnection] = []
    let handler: (Request) -> Reply
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return received }
    var origin: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    init(handler: @escaping (Request) -> Reply) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var finished = false
            listener.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; continuation.resume()
                case .failed(let error): finished = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
        for connection in active { connection.cancel() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var data = data; if let chunk { data.append(chunk) }
            guard data.count < 65536, error == nil else { connection.cancel(); return }
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete { self.receive(connection, data: data) }; return
            }
            let lines = String(decoding: data[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let fields = lines.first!.components(separatedBy: " ")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let index = line.firstIndex(of: ":") { headers[String(line[..<index]).lowercased()] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces) }
            }
            let body = data[separator.upperBound...]
            if body.count < (Int(headers["content-length"] ?? "0") ?? 0) { self.receive(connection, data: data); return }
            guard fields.count >= 2 else { connection.cancel(); return }
            let request = Request(path: fields[1], headers: headers, body: String(decoding: body, as: UTF8.self))
            self.lock.lock(); self.received.append(request); self.lock.unlock()
            let reply = self.handler(request), payload = Data(reply.body.utf8)
            if reply.drop { connection.cancel(); return }
            var responseHeaders = reply.headers
            responseHeaders["Content-Length"] = String(payload.count)
            responseHeaders["Content-Type"] = responseHeaders["Content-Type"] ?? "application/json"
            responseHeaders["Cache-Control"] = "no-store"
            responseHeaders["Connection"] = "close"
            let text = "HTTP/1.1 \(reply.status) Fixture\r\n" + responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n"
            self.queue.asyncAfter(deadline: .now() + reply.delay) {
                connection.send(content: Data(text.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

@MainActor final class ZLibraryBrowserTests: XCTestCase {
    private func server(_ handler: @escaping (CatalogLoopbackServer.Request) -> CatalogLoopbackServer.Reply) async throws -> CatalogLoopbackServer {
        let server = try CatalogLoopbackServer(handler: handler); try await server.start()
        addTeardownBlock { server.stop() }
        return server
    }
    private func browser(_ server: CatalogLoopbackServer, data: WKWebsiteDataStore? = nil) -> ZLibraryBrowserSession {
        let browser = ZLibraryBrowserSession(testOrigin: server.origin, dataStore: data ?? .nonPersistent())
        addTeardownBlock { await MainActor.run { browser.invalidate() } }
        return browser
    }
    private func request(_ server: CatalogLoopbackServer, _ path: String = "/eapi/book/most-popular") -> URLRequest {
        var request = URLRequest(url: server.origin.appendingPathComponent(path))
        request.setValue("test-account-key", forHTTPHeaderField: "remix-userkey")
        return request
    }
    private func send(_ request: URLRequest, through browser: ZLibraryBrowserSession) async throws -> ZLibraryPayload {
        try await browser.send(request, toFile: false, progress: { _ in })
    }
    func testHttpOnlyCookieRotationReachesNextRequestWithoutReopeningWebsite() async throws {
        let server = try await server { request in
            if request.path.contains("most-popular") { return .init(headers: ["Set-Cookie": "site_access=rotated; Path=/eapi; HttpOnly; SameSite=Lax"]) }
            return .init(status: request.headers["cookie"]?.contains("site_access=rotated") == true ? 200 : 401)
        }
        let browser = browser(server)
        var first = request(server)
        first.setValue("site_access=obsolete", forHTTPHeaderField: "Cookie")
        first.setValue("forged-agent", forHTTPHeaderField: "User-Agent")
        first.setValue("private-extra", forHTTPHeaderField: "X-Untrusted")
        _ = try await send(first, through: browser)
        var search = request(server, "/eapi/book/search")
        search.httpMethod = "POST"; search.httpBody = Data("message=%E5%9F%BA%E7%A1%80&page=1".utf8)
        search.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let result = try await send(search, through: browser)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests.last?.body, "message=%E5%9F%BA%E7%A1%80&page=1")
        XCTAssertEqual(server.requests.last?.headers["remix-userkey"], "test-account-key")
        XCTAssertFalse(server.requests.first?.headers["cookie"]?.contains("obsolete") == true)
        XCTAssertNotEqual(server.requests.first?.headers["user-agent"], "forged-agent")
        XCTAssertNil(server.requests.first?.headers["x-untrusted"])
        let cookies = try await browser.webView.callAsyncJavaScript("return document.cookie;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertFalse((cookies as? String)?.contains("rotated") == true, "HttpOnly cookies stay inside WebKit")
        let saved = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(saved.first { $0.name == "site_access" }?.isHTTPOnly, true)
    }

    func testClosingWebsiteRetainsDocumentAndUpdatedCookieJar() async throws {
        let server = try await server { request in
            if request.path == "/" {
                return .init(headers: ["Content-Type": "text/html", "Set-Cookie": "site_access=website; Path=/; HttpOnly"],
                             body: "<html><body>Local sign-in fixture<script>window.leafFixtureDraft='keep this browser';</script></body></html>")
            }
            return .init(status: request.headers["cookie"]?.contains("site_access=website") == true ? 200 : 401)
        }
        let browser = browser(server)
        browser.presentWebsite()
        try await eventually(timeout: 8, interval: 0.025) { browser.webView.url?.host == server.origin.host && !browser.webView.isLoading }
        browser.dismissWebsite()
        let result = try await send(request(server), through: browser)
        XCTAssertEqual(result.response.statusCode, 200)
        browser.presentWebsite()
        let draft = try await browser.webView.callAsyncJavaScript("return window.leafFixtureDraft;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(draft as? String, "keep this browser")
        XCTAssertEqual(server.requests.filter { $0.path == "/" }.count, 1)
    }

    func testPersistedBrowserCookiesSurviveNewBrowserInstance() async throws {
        let id = UUID(), data = WKWebsiteDataStore(forIdentifier: id)
        addTeardownBlock {
            await Task { @MainActor in
                await withCheckedContinuation { continuation in
                    WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
                }
            }.value
        }
        let server = try await server { request in
            .init(headers: ["Set-Cookie": "site_access=persistent; Path=/; Max-Age=3600; HttpOnly"])
        }
        let first = browser(server, data: data)
        _ = try await send(request(server), through: first)
        first.invalidate()
        let second = browser(server, data: data)
        _ = try await send(request(server), through: second)
        XCTAssertTrue(server.requests.last?.headers["cookie"]?.contains("site_access=persistent") == true)
        await data.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // The live provider answers a bare API request with a 307 to the same URL that only
    // hands out a short-lived cookie. A browser stores it and repeats the request.
    func testCookieChallengeRedirectIsRepeatedOnceWithStoredCookie() async throws {
        let server = try await server { request in
            if request.headers["cookie"]?.contains("fixture_gate=updated") == true { return .init() }
            return .init(status: 307, headers: ["Location": request.path, "Set-Cookie": "fixture_gate=updated; Path=/; HttpOnly"], body: "Local browser access fixture")
        }
        let browser = browser(server)
        var search = request(server, "/eapi/book/search")
        search.httpMethod = "POST"; search.httpBody = Data("message=private%20query&page=1".utf8)
        search.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let result = try await send(search, through: browser)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(server.requests.count, 2, "Exactly one repeat, no website load")
        XCTAssertEqual(server.requests.map(\.path), ["/eapi/book/search", "/eapi/book/search"])
        XCTAssertEqual(server.requests.last?.body, "message=private%20query&page=1", "307 keeps the POST body")
        XCTAssertEqual(server.requests.last?.headers["remix-userkey"], "test-account-key")
        XCTAssertTrue(server.requests.last?.headers["cookie"]?.contains("fixture_gate=updated") == true)
    }

    // The second stage is a small HTML page (HTTP 517) whose script sets another cookie.
    // Loading the website document in the retained browser passes it without the sheet.
    func testAccessCheckPageIsPassedByLoadingTheWebsiteDocument() async throws {
        let server = try await server { request in
            if request.path == "/" {
                return .init(headers: ["Content-Type": "text/html"],
                             body: "<html><body><script>document.cookie='fixture_dwid=set-by-script; path=/';</script>Local website fixture</body></html>")
            }
            if request.headers["cookie"]?.contains("fixture_dwid=set-by-script") == true { return .init() }
            return .init(status: 517, headers: ["Content-Type": "text/html"], body: "<html><head><title>Access Denied | DiamWall</title></head><body>private-body</body></html>")
        }
        let browser = browser(server)
        let result = try await send(request(server), through: browser)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(server.requests.map(\.path), ["/eapi/book/most-popular", "/eapi/book/most-popular", "/", "/eapi/book/most-popular"])
        XCTAssertEqual(browser.webView.url?.path, "/", "The website document stays loaded for the sheet")
        browser.presentWebsite()
        XCTAssertEqual(server.requests.filter { $0.path == "/" }.count, 1, "Open website reuses the loaded document")
    }

    func testPersistentRedirectStaysBoundedAndLeaksNothing() async throws {
        let server = try await server { request in
            if request.path == "/" { return .init(headers: ["Content-Type": "text/html"], body: "<html><body>Still checking</body></html>") }
            return .init(status: 307, headers: ["Location": request.path, "Set-Cookie": "fixture_gate=private-value; Path=/"], body: "private-body")
        }
        let browser = browser(server)
        do { _ = try await send(request(server), through: browser); XCTFail("Persistent redirect must surface the access check") }
        catch let error as ZLibraryRequestFailure {
            XCTAssertEqual(error.issue, .accessCheck)
            XCTAssertTrue(error.diagnostic.contains("retries: 3/3"), error.diagnostic)
            XCTAssertTrue(error.diagnostic.contains("website reload: completed"), error.diagnostic)
            for secret in ["test-account-key", "private-", "fixture_gate", "127.0.0.1"] { XCTAssertFalse(error.diagnostic.contains(secret), secret) }
        }
        XCTAssertEqual(server.requests.filter { $0.path.hasPrefix("/eapi/") }.count, 1 + ZLibraryBrowserSession.challengeRetries)
        XCTAssertEqual(server.requests.filter { $0.path == "/" }.count, 1)
    }

    func testSignInPageInsteadOfJSONIsNotRetried() async throws {
        let server = try await server { _ in .init(status: 200, headers: ["Content-Type": "text/html"], body: "<html><body>Please sign in</body></html>") }
        let browser = browser(server)
        let result = try await send(request(server), through: browser)
        XCTAssertEqual(result.response.mimeType, "text/html")
        XCTAssertEqual(server.requests.count, 1)
    }

    func testWebsiteSheetIsNotReloadedUnderTheUser() async throws {
        let server = try await server { request in
            if request.path == "/" { return .init(headers: ["Content-Type": "text/html"], body: "<html><body>Signing in</body></html>") }
            return .init(status: 307, headers: ["Location": request.path, "Set-Cookie": "fixture_gate=still-checking; Path=/"])
        }
        let browser = browser(server)
        browser.presentWebsite()
        try await eventually(timeout: 8, interval: 0.025) { browser.webView.url?.path == "/" && !browser.webView.isLoading }
        do { _ = try await send(request(server), through: browser); XCTFail("Persistent redirect must surface the access check") }
        catch let error as ZLibraryRequestFailure { XCTAssertTrue(error.diagnostic.contains("website reload: skipped"), error.diagnostic) }
        XCTAssertEqual(server.requests.filter { $0.path == "/" }.count, 1, "The presented document is left alone")
    }

    func testForeignOriginAndNonCatalogRequestsNeverReachTheNetwork() async throws {
        let server = try await server { _ in .init() }, browser = browser(server)
        for text in ["http://127.0.0.1:1/eapi/book/search", server.origin.absoluteString + "/account", "https://untrusted.example/eapi/book/search"] {
            do { _ = try await send(URLRequest(url: URL(string: text)!), through: browser); XCTFail("Unexpected request") }
            catch { XCTAssertEqual(error as? ZLibraryError, .address) }
        }
        var invalid = request(server); invalid.httpMethod = "DELETE"
        do { _ = try await send(invalid, through: browser); XCTFail("Unexpected method") }
        catch { XCTAssertEqual(error as? ZLibraryError, .address) }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testCancellationAbortsAnActiveBrowserRequest() async throws {
        let server = try await server { _ in .init(delay: 2) }, browser = browser(server)
        let request = request(server)
        let task = Task { try await self.send(request, through: browser) }
        try await eventually(timeout: 8, interval: 0.025) { server.requests.count == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(server.requests.count, 1)
    }

    private final class Counter: @unchecked Sendable { var value = 0 }
    private func search(_ server: CatalogLoopbackServer) -> URLRequest {
        var search = request(server, "/eapi/book/search")
        search.httpMethod = "POST"; search.httpBody = Data("message=private%20query&page=1".utf8)
        search.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return search
    }

    func testDroppedRequestIsRepeatedWithoutTheReaderSeeingIt() async throws {
        let seen = Counter()
        let server = try await server { _ in seen.value += 1; return .init(drop: seen.value == 1) }
        let browser = browser(server)
        let result = try await send(search(server), through: browser)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertGreaterThanOrEqual(server.requests.count, 2)
        XCTAssertEqual(Set(server.requests.map(\.body)), ["message=private%20query&page=1"], "The repeat is the same request")
    }

    func testRequestThatKeepsDroppingEndsInAReadableBoundedFailure() async throws {
        let server = try await server { _ in .init(drop: true) }, browser = browser(server)
        do {
            _ = try await send(search(server), through: browser); XCTFail("Dropped request succeeded")
        } catch let failure as ZLibraryRequestFailure {
            XCTAssertEqual(failure.issue, .unreachable)
            XCTAssertEqual(failure.errorDescription, "Couldn’t reach Z-Library. Check your connection and try again.")
            XCTAssertTrue(failure.diagnostic.hasPrefix("POST /eapi/book/search · no response · attempts: 3"), failure.diagnostic)
            XCTAssertTrue(failure.diagnostic.contains("browser online: "), failure.diagnostic)
            XCTAssertFalse(failure.diagnostic.contains("private"), "The query never reaches the diagnostic")
        }
        XCTAssertGreaterThanOrEqual(server.requests.count, 1 + ZLibraryBrowserSession.networkRetryDelays.count)
    }

    func testDroppedDiagnosticKeepsOnlyFixedFields() {
        let text = ZLibraryBrowserSession.droppedDiagnostic("GET /eapi/book/request", attempts: 3,
            result: ["kind": "network", "error": "Type<Error>\nhttps://private", "online": false], background: true)
        XCTAssertEqual(text, "GET /eapi/book/request · no response · attempts: 3 · error: TypeErrorhttpsprivate · browser online: no · app: background")
        XCTAssertTrue(ZLibraryBrowserSession.droppedDiagnostic("GET x", attempts: 1, result: [:], background: false).hasSuffix("error: unknown · browser online: unknown · app: foreground"))
        XCTAssertFalse((ZLibraryError.unreachable.errorDescription ?? "").contains("NSURLError"))
    }

    func testBrowserResponseIsBoundedToTwoMegabytes() async throws {
        let server = try await server { _ in .init(body: String(repeating: "x", count: 2 * 1024 * 1024 + 1)) }, browser = browser(server)
        do { _ = try await send(request(server), through: browser); XCTFail("Oversized result accepted") }
        catch { XCTAssertEqual(error as? ZLibraryError, .response) }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testStreamedDownloadUsesCurrentBrowserCookiesAndSavesResponseUpdates() async throws {
        let server = try await server { request in
            if request.path.contains("most-popular") { return .init(headers: ["Set-Cookie": "site_access=latest; Path=/eapi; HttpOnly"]) }
            let accepted = request.headers["cookie"]?.contains("site_access=latest") == true
            return .init(status: accepted ? 200 : 401,
                         headers: ["Content-Type": "application/octet-stream", "Set-Cookie": "site_access=after-download; Path=/eapi; HttpOnly"], body: "%PDF-fixture")
        }
        let browser = browser(server)
        _ = try await send(request(server), through: browser)
        var download = request(server, "/eapi/book/download")
        download.setValue("site_access=obsolete", forHTTPHeaderField: "Cookie")
        let result = try await browser.send(download, toFile: true, progress: { _ in })
        let file = try XCTUnwrap(result.file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("%PDF-fixture".utf8))
        XCTAssertEqual(result.response.statusCode, 200)
        let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.first { $0.name == "site_access" }?.value, "after-download")
        XCTAssertEqual(server.requests.count, 2)
    }

    func testStreamedDownloadRepeatsCookieChallengeRedirectOnceAndSavesItsCookie() async throws {
        let server = try await server { request in
            if request.headers["cookie"]?.contains("fixture_gate=download") == true {
                return .init(headers: ["Content-Type": "application/octet-stream"], body: "%PDF-fixture")
            }
            return .init(status: 307, headers: ["Location": request.path, "Set-Cookie": "fixture_gate=download; Path=/"], body: "DiamWall")
        }
        let browser = browser(server)
        // The download reads the browser jar, never the request's own Cookie header.
        let kept = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "site_access", .value: "kept"]))
        await browser.webView.configuration.websiteDataStore.httpCookieStore.setCookie(kept)
        let result = try await browser.send(request(server, "/eapi/book/download"), toFile: true, progress: { _ in })
        let file = try XCTUnwrap(result.file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("%PDF-fixture".utf8))
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(server.requests.last?.headers["cookie"], "site_access=kept; fixture_gate=download", "Jar cookie kept, challenge cookie added")
        let cookies = await browser.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(cookies.first { $0.name == "fixture_gate" }?.value, "download")
    }

    func testStreamedDownloadStillRefusesSameURLRedirectWithoutCookies() async throws {
        let server = try await server { request in .init(status: 307, headers: ["Location": request.path]) }
        let browser = browser(server)
        do { _ = try await browser.send(request(server, "/eapi/book/download"), toFile: true, progress: { _ in }); XCTFail("Loop followed") }
        catch { XCTAssertEqual(ZLibraryRequestFailure.issue(error), .challenge) }
        XCTAssertEqual(server.requests.count, 1)
    }
}
