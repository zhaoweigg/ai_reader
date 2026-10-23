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
            var finished = false
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
    private func browser(_ server: CatalogLoopbackServer, data: WKWebsiteDataStore = .nonPersistent()) -> ZLibraryBrowserSession {
        let browser = ZLibraryBrowserSession(testOrigin: server.origin, dataStore: data)
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
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(predicate())
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
        try await wait { browser.webView.url?.host == server.origin.host && !browser.webView.isLoading }
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
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
            }
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

    func testBrowserRedirectDoesNotLoopOrLeakCredentialsAndKeepsCookieUpdate() async throws {
        let server = try await server { request in
            if request.headers["cookie"]?.contains("fixture_gate=updated") == true { return .init() }
            return .init(status: 307, headers: ["Location": request.path, "Set-Cookie": "fixture_gate=updated; Path=/; HttpOnly"], body: "Local browser access fixture")
        }
        let browser = browser(server)
        do { _ = try await send(request(server), through: browser); XCTFail("Browser redirect must require visible verification") }
        catch let error as ZLibraryRequestFailure {
            XCTAssertEqual(error.issue, .accessCheck)
            XCTAssertFalse(error.diagnostic.contains("test-account-key")); XCTAssertFalse(error.diagnostic.contains("updated"))
        }
        XCTAssertEqual(server.requests.count, 1, "No automatic redirect/retry, even when the server updates cookies")
        let second = try await send(request(server), through: browser)
        XCTAssertEqual(second.response.statusCode, 200)
        XCTAssertEqual(server.requests.count, 2)
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
        try await wait { server.requests.count == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testBrowserResponseIsBoundedToTwoMegabytes() async throws {
        let server = try await server { _ in .init(body: String(repeating: "x", count: 2 * 1024 * 1024 + 1)) }, browser = browser(server)
        do { _ = try await send(request(server), through: browser); XCTFail("Oversized result accepted") }
        catch { XCTAssertEqual(error as? ZLibraryError, .response) }
        XCTAssertEqual(server.requests.count, 1)
    }
}
