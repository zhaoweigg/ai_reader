import Foundation
import WebKit

// Sign-in and catalog JSON share one WebKit cookie jar and browser context.
// A redirect is handed back to the visible website; it is never replayed here.
@MainActor final class ZLibraryBrowserSession: NSObject, ZLibraryTransport, WKNavigationDelegate {
    let webView: WKWebView
    private let origin: URL
    private var ready = false
    private var navigationFailed = false
    private var neutralDocument = true
    private var presented = false
    var stateChanged: ((Bool, String?) -> Void)?
    var contextChanged: ((String?) async -> Void)?

    init(origin: ZLibraryOrigin, dataStore: WKWebsiteDataStore) {
        self.origin = origin.url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.isInspectable = false
    }

    #if DEBUG
    // Real WebKit network/cookie tests use an ephemeral loopback HTTP server.
    init(testOrigin: URL, dataStore: WKWebsiteDataStore) {
        precondition(testOrigin.scheme == "http" && testOrigin.host == "127.0.0.1")
        origin = testOrigin
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    #endif

    private func contains(_ url: URL) -> Bool {
        url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
            && url.user == nil && url.password == nil
    }

    func presentWebsite(fixture: Bool = false) {
        presented = true
        stateChanged?(ready, nil)
        guard neutralDocument || webView.url == nil else { return }
        neutralDocument = false
        #if DEBUG
        if fixture {
            webView.loadHTMLString("""
                <html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head>
                <body style='font:17px -apple-system;color:#111;background:white;padding:16px'>
                <h1 style='font-size:24px'>Offline connection fixture</h1>
                <input aria-label='Website draft' style='font-size:17px;width:100%;box-sizing:border-box'>
                <script>document.cookie='site_access=refreshed-preview; path=/; Secure';</script></body></html>
                """, baseURL: origin)
            return
        }
        #endif
        webView.load(URLRequest(url: origin))
    }

    func dismissWebsite() {
        presented = false
        stateChanged = nil
        // Retain the document and its browser session after the sheet closes.
    }

    func invalidate() {
        stateChanged = nil; contextChanged = nil
        webView.stopLoading(); webView.navigationDelegate = nil
        ready = false; navigationFailed = true
    }

    private func prepare() async throws {
        if !ready && !webView.isLoading && !presented {
            neutralDocument = true; navigationFailed = false
            webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: origin)
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while !ready {
            try Task.checkCancellation()
            if navigationFailed || ContinuousClock.now >= deadline {
                throw ZLibraryRequestFailure(issue: .unreachable, diagnostic: "website document \(navigationFailed ? "failed to load" : "timed out after 15 s")")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let url = webView.url, contains(url) else { throw ZLibraryError.address }
    }

    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        guard let url = request.url else { throw ZLibraryError.address }
        if toFile {
            var download = request
            if contains(url) {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                let matching = cookies.filter { cookie in
                    cookie.hostDomain == origin.host
                        && (cookie.expiresDate.map { $0 > Date() } ?? true)
                        && (!cookie.isSecure || url.scheme == "https")
                        && ZLibraryWebsiteCookie.pathMatches(cookiePath: cookie.path, url: url)
                }.sorted { $0.path.count > $1.path.count }
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
                guard matching.count <= 64, (header?.utf8.count ?? 0) <= 16384 else { throw ZLibraryError.response }
                download.setValue(header, forHTTPHeaderField: "Cookie")
            } else {
                for name in ["Cookie", "Authorization", "remix-userid", "remix-userkey"] { download.setValue(nil, forHTTPHeaderField: name) }
            }
            let payload = try await ZLibraryHTTPTransport().send(download, toFile: true, progress: progress)
            if let responseURL = payload.response.url, contains(responseURL) {
                let fields = payload.response.allHeaderFields.reduce(into: [String: String]()) { result, item in
                    if let key = item.key as? String, let value = item.value as? String { result[key] = value }
                }
                for cookie in payload.challengeCookies + HTTPCookie.cookies(withResponseHeaderFields: fields, for: responseURL)
                    where cookie.hostDomain == origin.host {
                    await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
                await contextChanged?(nil)
            }
            return payload
        }
        // The app API, and the website's search page when the app search is refused.
        let website = url.path.hasPrefix("/s/") && (request.httpMethod ?? "GET") == "GET"
        guard contains(url), url.path.hasPrefix("/eapi/") || website, ["GET", "POST"].contains(request.httpMethod ?? "GET") else { throw ZLibraryError.address }
        try await prepare()
        // Cookie/User-Agent/Origin are browser-managed. Credentials only reach this exact origin.
        let headers = (request.allHTTPHeaderFields ?? [:]).filter {
            ["accept", "content-type", "remix-userid", "remix-userkey", "source"].contains($0.key.lowercased())
        }
        let arguments: [String: Any] = ["target": url.absoluteString, "method": request.httpMethod ?? "GET",
                                        "headers": headers, "body": request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""]
        // The provider's access check answers an API request with a redirect to the same
        // URL that only hands out a cookie, then with a small page whose script sets a second
        // one. A browser passes both on its own: it repeats the request once the cookie is
        // stored, and it renders the page. Do the same with fixed bounds: one plain retry,
        // one retry after loading the website document, one delayed retry for its scripts.
        var retries = 0, reload = "not needed", attempts = 0
        var result = try await repeatingDrops(arguments, attempts: &attempts)
        while retries < Self.challengeRetries, Self.isAccessChallenge(result, website: website) {
            retries += 1
            if retries == 2 { reload = try await reloadWebsite() ? "completed" : (presented ? "skipped" : "failed") }
            if retries == 3 { try await Task.sleep(for: .seconds(3)) }
            result = try await repeatingDrops(arguments, attempts: &attempts)
        }
        await contextChanged?(nil)
        guard let result = result as? [String: Any], let kind = result["kind"] as? String else { throw ZLibraryError.response }
        let path = Self.diagnosticPath(url.path)
        if kind == "redirect" {
            throw ZLibraryRequestFailure(issue: .accessCheck, diagnostic: "\(request.httpMethod ?? "GET") \(path) · browser redirect · retries: \(retries)/\(Self.challengeRetries) · website reload: \(reload) · website verification required")
        }
        let attempt = "\(request.httpMethod ?? "GET") \(path)"
        if kind == "timeout" { throw ZLibraryRequestFailure(issue: .unreachable, diagnostic: "\(attempt) · no response after 30 s") }
        if kind == "network" {
            throw ZLibraryRequestFailure(issue: .unreachable, diagnostic: Self.droppedDiagnostic(attempt, attempts: attempts, result: result,
                background: UIApplication.shared.applicationState == .background))
        }
        if kind == "size" { throw ZLibraryError.response }
        guard kind == "response", let status = result["status"] as? Int,
              let text = result["text"] as? String, text.utf8.count <= 2 * 1024 * 1024,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": result["contentType"] as? String ?? ""]) else {
            throw ZLibraryRequestFailure(issue: .response, diagnostic: "\(attempt) · unreadable browser result")
        }
        return ZLibraryPayload(data: Data(text.utf8), file: nil, response: response)
    }

    static let challengeRetries = 3
    /// Pauses before repeating a request that got no response at all. Every catalog request
    /// only reads: book/search is the one POST, so repeating one changes nothing.
    static let networkRetryDelays: [Double] = [0.6, 1.5]
    private func repeatingDrops(_ arguments: [String: Any], attempts: inout Int) async throws -> Any? {
        attempts += 1
        var result = try await fetch(arguments)
        for delay in Self.networkRetryDelays where Self.isDropped(result) {
            try await Task.sleep(for: .seconds(delay))
            // The document may have gone with the connection, for example after the app was suspended.
            try await prepare()
            attempts += 1
            result = try await fetch(arguments)
        }
        return result
    }
    private static func isDropped(_ result: Any?) -> Bool { (result as? [String: Any])?["kind"] as? String == "network" }
    // Fixed fields only: WebKit reports a failed fetch as a bare TypeError, so the name is all
    // there is to keep. Never the URL query, the request body or anything from the website.
    static func droppedDiagnostic(_ attempt: String, attempts: Int, result: [String: Any], background: Bool) -> String {
        let name = String((result["error"] as? String ?? "unknown").filter { $0.isLetter || $0.isNumber || $0 == " " }.prefix(40))
        let online = (result["online"] as? Bool).map { $0 ? "yes" : "no" } ?? "unknown"
        return "\(attempt) · no response · attempts: \(attempts) · error: \(name) · browser online: \(online) · app: \(background ? "background" : "foreground")"
    }
    private func fetch(_ arguments: [String: Any]) async throws -> Any? {
        try Task.checkCancellation()
        let id = UUID().uuidString
        var arguments = arguments; arguments["id"] = id
        do {
            let result = try await withTaskCancellationHandler {
                try await webView.callAsyncJavaScript(Self.fetchScript, arguments: arguments, in: nil, contentWorld: .defaultClient)
            } onCancel: { [weak self] in
                Task { @MainActor in
                    _ = try? await self?.webView.callAsyncJavaScript("globalThis.leafCatalogRequests?.get(id)?.abort();", arguments: ["id": id], in: nil, contentWorld: .defaultClient)
                }
            }
            try Task.checkCancellation()
            return result
        } catch {
            // The script itself was lost, for example when its page was replaced or its process ended.
            try Task.checkCancellation()
            return ["kind": "network", "error": "web view"]
        }
    }
    // A redirect, or a recognized access-check page in place of JSON. Other HTML (for
    // example a sign-in page) is not retried: reloading the website cannot change it.
    private static func isAccessChallenge(_ result: Any?, website: Bool = false) -> Bool {
        guard let result = result as? [String: Any], let kind = result["kind"] as? String else { return false }
        if kind == "redirect" { return true }
        guard kind == "response", let status = result["status"] as? Int, let text = result["text"] as? String else { return false }
        // Ordinary website pages may load the check's own scripts; only a refused page counts.
        if website && (200...299).contains(status) { return false }
        let body = text.prefix(4096).lowercased()
        return status == 517 || body.contains("diamwall") || body.contains("/cdn-cgi/challenge") || body.contains("__cf_chl")
    }
    // Load the same document the Open website sheet shows, without presenting it.
    private func reloadWebsite() async throws -> Bool {
        guard !presented else { return false }
        neutralDocument = false; ready = false; navigationFailed = false
        webView.load(URLRequest(url: origin))
        let deadline = ContinuousClock.now + .seconds(15)
        while !ready && !navigationFailed && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        return ready
    }

    private static func diagnosticPath(_ path: String) -> String {
        // Never expose book IDs, hashes, queries, website response bodies or credentials.
        if ["/eapi/book/most-popular", "/eapi/book/search", "/eapi/user/book/recommended", "/eapi/user/profile"].contains(path) { return path }
        if path.hasPrefix("/s/") { return "/s/ (website search)" }
        return "/eapi/book/request"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" || contains(url) || (action.targetFrame?.isMainFrame == false && url.scheme == "https" && url.user == nil && url.password == nil) {
            decisionHandler(.allow)
        } else {
            stateChanged?(false, "This link opens another website. Set its trusted address in Connection first.")
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        ready = false; navigationFailed = false; stateChanged?(false, nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, contains(url) else { return }
        ready = true; navigationFailed = false; stateChanged?(true, nil)
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
            Task { @MainActor in await self?.contextChanged?(value as? String) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        ready = false; navigationFailed = true
        stateChanged?(false, "The website could not be loaded. Check its address and your connection.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; navigationFailed = true
        stateChanged?(false, "The website stopped responding. Close it and try again.")
    }

    private static let fetchScript = """
    const controller = new AbortController();
    globalThis.leafCatalogRequests ??= new Map();
    globalThis.leafCatalogRequests.set(id, controller);
    const timer = setTimeout(() => controller.abort(), 30000);
    try {
        const response = await fetch(target, {method, headers, body: method === 'POST' ? body : undefined,
            credentials: 'same-origin', mode: 'same-origin', redirect: 'manual', cache: 'no-store', signal: controller.signal});
        if (response.type === 'opaqueredirect' || response.status === 0) return {kind: 'redirect'};
        if (Number(response.headers.get('Content-Length')) > 2097152) { await response.body?.cancel(); return {kind: 'size'}; }
        const reader = response.body?.getReader(), decoder = new TextDecoder();
        let size = 0, text = '';
        if (reader) {
            while (true) {
                const {done, value} = await reader.read();
                if (done) break;
                size += value.byteLength;
                if (size > 2097152) { await reader.cancel(); return {kind: 'size'}; }
                text += decoder.decode(value, {stream: true});
            }
            text += decoder.decode();
        }
        return {kind: 'response', status: response.status, contentType: response.headers.get('Content-Type') || '', text};
    } catch (error) {
        return controller.signal.aborted ? {kind: 'timeout'} : {kind: 'network', error: String(error?.name || 'Error').slice(0, 40), online: navigator.onLine};
    }
    finally { clearTimeout(timer); globalThis.leafCatalogRequests.delete(id); }
    """
}
