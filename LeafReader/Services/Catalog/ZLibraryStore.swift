import Foundation
import WebKit

@MainActor
final class ZLibraryStore: ObservableObject {
    @Published private(set) var origin: ZLibraryOrigin
    @Published private(set) var connected = false
    @Published private(set) var accountName = ""
    @Published private(set) var remaining: Int?
    @Published private(set) var books: [ZLibraryBook] = []
    @Published private(set) var loading = false
    @Published private(set) var showingSavedResults = false
    @Published private(set) var activeQuery = ""
    @Published private(set) var searchOrder: ZLibrarySearchOrder
    @Published private(set) var canLoadMore = false
    @Published private(set) var searchLimitReached = false
    @Published private(set) var verifying = false
    @Published private(set) var error: String?
    @Published private(set) var requestDiagnostic: String?
    @Published private(set) var websiteAccessNeeded = false
    @Published private(set) var connectionError: String?
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress: Double?
    @Published private(set) var importedID: UUID?
    @Published private(set) var importError: String?
    private var signInData: WKWebsiteDataStore?
    private var browserSession: ZLibraryBrowserSession?
    var websiteBrowser: ZLibraryBrowserSession {
        if let browserSession { return browserSession }
        let browser = ZLibraryBrowserSession(origin: origin, dataStore: websiteData)
        browser.contextChanged = { [weak self] userAgent in
            guard let self else { return }
            if let userAgent { self.captureWebsiteUserAgent(userAgent) }
            try? await self.saveWebsiteContext()
        }
        browserSession = browser
        return browser
    }
    private var seedingWebsite = false
    private var websiteUserAgent: String?
    var websiteData: WKWebsiteDataStore {
        if let signInData { return signInData }
        // A stable, isolated WebKit store survives app replacement, including website
        // storage that cannot be reconstructed from the two account cookies alone.
        let key = "zlibrary.websiteData.\(origin.url.absoluteString)"
        let identifier = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString, forKey: key)
        let data = WKWebsiteDataStore(forIdentifier: identifier)
        signInData = data; return data
    }
    private let defaults: UserDefaults
    private let credentials: any ChatCredentialStore
    private let clientOverride: (any ZLibraryServing)?
    private var client: any ZLibraryServing { clientOverride ?? ZLibraryClient(transport: websiteBrowser) }
    private var session: ZLibrarySession?
    private var generation = UUID()
    private var downloadTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogRequest = UUID()
    private var searchPage = 0
    private var retryNextPage = false
    // Bounded, in-memory navigation state, isolated to the verified account/origin.
    // Popular plus the three most recently visited searches (at most 1,100 rows).
    private struct CatalogKey: Hashable {
        let query: String
        let order: String
        init(_ query: String, _ order: ZLibrarySearchOrder) {
            self.query = query; self.order = query.isEmpty ? "" : order.rawValue
        }
    }
    private struct CatalogSnapshot {
        let books: [ZLibraryBook]
        let page: Int
        let canLoadMore: Bool
        let limitReached: Bool
    }
    private var snapshots: [CatalogKey: CatalogSnapshot] = [:]
    private var recentSearches: [CatalogKey] = []
    private func clearSnapshots() {
        snapshots.removeAll(); recentSearches.removeAll(); showingSavedResults = false
    }
    private func touch(_ key: CatalogKey) {
        guard !key.query.isEmpty else { return }
        recentSearches.removeAll { $0 == key }; recentSearches.append(key)
        while recentSearches.count > 3 { snapshots.removeValue(forKey: recentSearches.removeFirst()) }
    }
    private func restore(_ key: CatalogKey) -> Bool {
        guard let saved = snapshots[key] else { return false }
        touch(key)
        books = saved.books; searchPage = saved.page
        canLoadMore = saved.canLoadMore; searchLimitReached = saved.limitReached
        showingSavedResults = true
        return true
    }
    #if DEBUG
    let isPreview: Bool
    #else
    let isPreview = false
    #endif
    init(defaults: UserDefaults = .standard, credentials: any ChatCredentialStore = KeychainChatCredentials(service: "com.weizhao.leafreader.zlibrary"), client: (any ZLibraryServing)? = nil) {
        self.defaults = defaults; self.credentials = credentials; self.clientOverride = client
        searchOrder = ZLibrarySearchOrder(rawValue: defaults.string(forKey: "zlibrary.searchOrder") ?? "") ?? .popular
        origin = (try? ZLibraryOrigin(defaults.string(forKey: "zlibrary.origin") ?? "https://z-library.sk")) ?? (try! ZLibraryOrigin("https://z-library.sk"))
        #if DEBUG
        isPreview = client.map { $0 is UITestZLibraryClient } ?? false
        #endif
        do {
            session = try savedSession(for: origin)
            websiteUserAgent = session?.userAgent
            accountName = session == nil ? "" : "Saved account"
        } catch { connectionError = "Leaf could not read your saved connection. Unlock your device and try again." }
    }
    /// The Keychain session of an origin; an unreadable or invalid record counts as none.
    private func savedSession(for origin: ZLibraryOrigin) throws -> ZLibrarySession? {
        let saved = try credentials.read(account: origin.url.absoluteString)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ZLibrarySession.self, from: $0) }
        return saved?.valid == true ? saved : nil
    }
    private func store(_ session: ZLibrarySession, for origin: ZLibraryOrigin) throws {
        let encoded = try JSONEncoder().encode(session)
        try credentials.write(String(decoding: encoded, as: UTF8.self), account: origin.url.absoluteString)
    }
    /// Discards every in-flight request, cached page and status that belonged to
    /// the previous account or origin.
    private func resetCatalog() {
        generation = UUID(); clearSnapshots(); downloadTask?.cancel(); downloadTask = nil
        cancelCatalogLoad(); searchPage = 0; canLoadMore = false; searchLimitReached = false
        books = []; error = nil; requestDiagnostic = nil; websiteAccessNeeded = false
        loading = false; verifying = false; downloadingID = nil; progress = nil
    }
    func changeAddress(_ address: String) async throws {
        let next = try ZLibraryOrigin(address)
        guard next != origin else { return }
        try await disconnect()
        signInData = nil
        origin = next; defaults.set(next.url.absoluteString, forKey: "zlibrary.origin")
        session = try savedSession(for: next)
        websiteUserAgent = session?.userAgent
    }
    func clearWebsite() async {
        browserSession?.invalidate(); browserSession = nil
        websiteUserAgent = nil
        // Disconnect must clear disk-backed data even if no browser was opened
        // during this launch.
        await websiteData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    func disconnect() async throws {
        try credentials.write(nil, account: origin.url.absoluteString)
        resetCatalog(); activeQuery = ""
        session = nil; connected = false; accountName = ""; remaining = nil; connectionError = nil
        await clearWebsite()
    }
    func connect(_ candidate: ZLibrarySession) async -> Bool {
        guard !verifying, candidate.valid else { return false }
        verifying = true; connectionError = nil
        let token = generation, source = origin
        defer { if token == generation { verifying = false } }
        do {
            let profile = try await client.profile(origin: source, session: candidate)
            try Task.checkCancellation()
            guard token == generation else { return false }
            do { try store(candidate, for: source) }
            catch { throw ZLibraryError.service("Leaf could not save the Z-Library session in Keychain. Your existing connection was kept.") }
            // Discard responses started with the old account (including anonymous feed loads).
            resetCatalog()
            session = candidate; connected = true; accountName = profile.name; remaining = profile.remaining
            return true
        } catch {
            if token == generation && !Task.isCancelled && !Self.isCancellation(error) { connectionError = error.localizedDescription }
            return false
        }
    }
    func cookieCandidate(_ cookies: [HTTPCookie]) -> ZLibrarySession? {
        let trusted = cookies.filter { cookie in
            // This cookie store belongs to an HTTPS-only sign-in view. Verify account identity
            // over HTTPS even when the website omits Secure on its own issued cookies.
            cookie.hostDomain == origin.url.host && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        guard let user = trusted.first(where: { $0.name == "remix_userid" }), let key = trusted.first(where: { $0.name == "remix_userkey" }) else { return nil }
        let context = trusted.filter { !["remix_userid", "remix_userkey"].contains($0.name) }.map {
            ZLibraryWebsiteCookie(name: $0.name, value: $0.value, path: $0.path, expires: $0.expiresDate)
        }.filter(\.valid)
        let candidate = ZLibrarySession(userID: user.value, userKey: key.value, websiteCookies: context.isEmpty ? nil : context.sorted { ($0.name, $0.path) < ($1.name, $1.path) }, userAgent: websiteUserAgent ?? session?.userAgent)
        return candidate.valid ? candidate : nil
    }
    func captureWebsiteUserAgent(_ text: String) {
        if ZLibrarySession.validUserAgent(text) { websiteUserAgent = text }
    }
    // Never adopt a different browser account without explicit Check connection.
    // Capture refreshed cookies even when the user simply closes the website.
    func saveWebsiteContext() async throws {
        guard !seedingWebsite, let existing = session, let data = signInData else { return }
        let token = generation, source = origin
        let cookies = await data.httpCookieStore.allCookies()
        try Task.checkCancellation()
        guard !seedingWebsite, token == generation, source == origin,
              let candidate = cookieCandidate(cookies),
              candidate.userID == existing.userID, candidate.userKey == existing.userKey,
              candidate != existing else { return }
        try store(candidate, for: source)
        session = candidate
    }
    func seedWebsite() async {
        guard !seedingWebsite, let session else { return }
        seedingWebsite = true
        defer { seedingWebsite = false }
        let source = origin, data = websiteData, token = generation
        websiteUserAgent = websiteUserAgent ?? session.userAgent
        let cookies = await data.httpCookieStore.allCookies()
        guard token == generation else { return }
        let browser = cookieCandidate(cookies)
        let sameAccount = browser?.userID == session.userID && browser?.userKey == session.userKey
        // Do not overwrite newer access cookies with the older Keychain snapshot.
        if sameAccount { return }
        if browser != nil {
            await data.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            guard token == generation else { return }
        }
        for (name, value) in [("remix_userid",session.userID),("remix_userkey",session.userKey)] {
            guard token == generation else { return }
            if let cookie = HTTPCookie(properties: [.domain:source.url.host!, .path:"/", .name:name, .value:value, .secure:"TRUE"]) {
                await data.httpCookieStore.setCookie(cookie)
            }
        }
        for context in session.websiteCookies ?? [] where context.valid && (context.expires.map { $0 > Date() } ?? true) {
            guard token == generation else { return }
            if browser == nil, cookies.contains(where: {
                $0.hostDomain == source.url.host && $0.name == context.name && $0.path == context.path && ($0.expiresDate.map { $0 > Date() } ?? true)
            }) { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: source.url.host!, .path: context.path, .name: context.name, .value: context.value, .secure: "TRUE"]
            if let expires = context.expires { properties[.expires] = expires }
            if let cookie = HTTPCookie(properties: properties) { await data.httpCookieStore.setCookie(cookie) }
        }
    }
    func loadPopular() async { await loadCatalog(query: "") }
    func search(_ query: String) async { await loadCatalog(query: query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    func setSearchOrder(_ order: ZLibrarySearchOrder) async {
        guard order != searchOrder else { return }
        searchOrder = order; defaults.set(order.rawValue, forKey: "zlibrary.searchOrder")
        // A new order is a new result set. Cancel even when the submitted query is
        // identical, and restart at page one so differently ordered pages never mix.
        if !activeQuery.isEmpty { cancelCatalogLoad(); await reload() }
    }
    func reload() async { await loadCatalog(query: activeQuery, refresh: true) }
    func retry() async {
        if retryNextPage { await loadMore() } else { await reload() }
    }
    func loadMore() async {
        guard !activeQuery.isEmpty, canLoadMore, !loading else { return }
        await loadCatalog(query: activeQuery, append: true)
    }
    func cancelCatalogLoad() {
        catalogTask?.cancel(); catalogTask = nil; catalogRequest = UUID(); loading = false
    }
    private func loadCatalog(query: String, append: Bool = false, refresh: Bool = false) async {
        if loading && query == activeQuery { return }
        cancelCatalogLoad()
        let request = catalogRequest, token = generation, source = origin, order = searchOrder
        activeQuery = query; retryNextPage = append
        error = nil; requestDiagnostic = nil; websiteAccessNeeded = false
        if !append {
            let restored = restore(CatalogKey(query, order))
            if restored && !refresh { return }
            if !restored {
                books = []; searchPage = 0; canLoadMore = false; searchLimitReached = false
                showingSavedResults = false
            }
        }
        loading = true
        let page = append ? searchPage + 1 : 1
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performLoad(query: query, page: page, order: order, append: append, request: request, token: token, source: source)
        }
        // Hold a cancellable task: a query change cancels network work as well as rejecting stale results.
        catalogTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
    private func performLoad(query: String, page: Int, order: ZLibrarySearchOrder, append: Bool, request: UUID, token: UUID, source: ZLibraryOrigin) async {
        defer { if token == generation && request == catalogRequest { loading = false; catalogTask = nil } }
        do {
            try Task.checkCancellation()
            // Keychain may have been locked during app initialization. Retry on use
            // rather than making the user reconnect an account that is still saved.
            if session == nil {
                session = try savedSession(for: source)
                websiteUserAgent = session?.userAgent
                connectionError = nil
            }
            // Restore Keychain account cookies that WebKit treats as session-only,
            // while retaining any newer persistent browser access cookies.
            await seedWebsite()
            try await saveWebsiteContext()
            try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
            let saved = session
            if let saved, !connected {
                let profile = try await client.profile(origin: source, session: saved)
                try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
                connected = true; accountName = profile.name; remaining = profile.remaining
            }
            let result: [ZLibraryBook], more: Bool
            if query.isEmpty { result = try await client.popular(origin: source, session: saved); more = false }
            else {
                let response = try await client.search(query, page: page, order: order, origin: source, session: saved)
                result = response.books; more = response.hasMore
            }
            try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
            let existing = append ? Set(books.map(\.id)) : []
            let added = result.filter { !existing.contains($0.id) }
            books = append ? books + added : result
            searchPage = query.isEmpty ? 0 : page
            searchLimitReached = !query.isEmpty && more && page >= ZLibrarySearchPage.maximumPages
            canLoadMore = !query.isEmpty && more && !added.isEmpty && !searchLimitReached
            let key = CatalogKey(query, order)
            snapshots[key] = CatalogSnapshot(books: books, page: searchPage, canLoadMore: canLoadMore, limitReached: searchLimitReached)
            touch(key); showingSavedResults = false
        } catch {
            if token == generation && request == catalogRequest && !Task.isCancelled && !Self.isCancellation(error) {
                let issue = ZLibraryRequestFailure.issue(error)
                if issue == .signInRequired { connected = false }
                websiteAccessNeeded = issue == .challenge || issue == .accessCheck
                requestDiagnostic = (error as? ZLibraryRequestFailure)?.diagnostic
                if issue == .accessCheck {
                    self.error = ZLibraryError.accessCheck.localizedDescription + (connected ? " Your account remains connected." : "")
                } else {
                    self.error = connected && websiteAccessNeeded
                        ? (query.isEmpty ? "Your account is connected, but the website did not return popular-book data. Open the website to check access, then try again." : "Your account is connected, but the website did not return search results. Open the website to check access, then try again.")
                        : error.localizedDescription
                }
            }
        }
    }
    func details(_ book: ZLibraryBook) async throws -> ZLibraryBook {
        if let cached = books.first(where: { $0.id == book.id }), !cached.fileExtension.isEmpty { return cached }
        let token = generation, source = origin
        do {
            let resolved = try await client.details(book, origin: source, session: session)
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = resolved }
            for (key, snapshot) in snapshots {
                guard let index = snapshot.books.firstIndex(where: { $0.id == book.id }) else { continue }
                var rows = snapshot.books; rows[index] = resolved
                snapshots[key] = CatalogSnapshot(books: rows, page: snapshot.page, canLoadMore: snapshot.canLoadMore, limitReached: snapshot.limitReached)
            }
            return resolved
        } catch {
            guard token == generation else { throw CancellationError() }
            if ZLibraryRequestFailure.issue(error) == .signInRequired { connected = false }
            throw error
        }
    }
    func add(_ book: ZLibraryBook, library: LibraryStore) {
        guard downloadTask == nil, let session, connected else { importError = ZLibraryError.signInRequired.localizedDescription; return }
        downloadingID = book.id; progress = nil; importError = nil; importedID = nil
        let token = generation, source = origin
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == self.generation { self.downloadingID = nil; self.progress = nil; self.downloadTask = nil } }
            do {
                // Quota and session are checked at the point of download, not inferred from cached UI.
                let profile = try await client.profile(origin: source, session: session)
                guard token == self.generation else { return }
                self.remaining = profile.remaining
                if profile.remaining == 0 { throw ZLibraryError.service("Your Z-Library download allowance is used up. Try again when it resets.") }
                let file = try await client.download(book, origin: source, session: session, progress: { [weak self] value in
                    Task { @MainActor in if token == self?.generation && self?.downloadingID == book.id { self?.progress = value } }
                })
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation(); guard token == self.generation else { return }
                let imported = try await library.importCatalogBook(file, catalogID: book.sourceID, title: book.title, author: book.author)
                guard token == self.generation else { return }
                self.importedID = imported.id
                if let remaining = self.remaining { self.remaining = max(0, remaining - 1) }
            } catch {
                if token == self.generation && !Task.isCancelled && !Self.isCancellation(error) {
                    if ZLibraryRequestFailure.issue(error) == .signInRequired { self.connected = false }
                    self.importError = error.localizedDescription
                }
            }
        }
    }
    static func isCancellation(_ error: Error) -> Bool { error is CancellationError || (error as? URLError)?.code == .cancelled }
    func cancelDownload() { downloadTask?.cancel() }
    func resetImportResult() { importedID = nil; importError = nil }
    #if DEBUG
    func connectPreview() async -> Bool { guard isPreview else { return false }; return await connect(ZLibrarySession(userID:"preview",userKey:"preview-only")) }
    #endif
}

#if DEBUG
struct UITestZLibraryClient: ZLibraryServing {
    func details(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibraryBook {
        try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
        if UITesting.environment("LEAF_UI_ZLIB_DETAILS") == "failure" { throw ZLibraryError.metadata }
        return ZLibraryBook(remoteID: book.remoteID, hash: book.hash, title: book.title, author: book.author,
                            fileExtension: UITesting.environment("LEAF_UI_ZLIB_DETAILS") == "unsupported" ? "djvu" : "epub",
                            size: "1 MB", language: "English", year: "2026", coverURL: book.coverURL,
                            rating: book.rating, ratingCount: book.ratingCount, qualityScore: book.qualityScore)
    }
    func profile(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> ZLibraryProfile { ZLibraryProfile(name:"Preview account",remaining:5) }
    func popular(origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> [ZLibraryBook] {
        try await guardRepeatedRequest("popular-" + (session?.userID ?? "anonymous"), path: "book/most-popular", session: session)
        if UITesting.flag("LEAF_UI_ZLIB_WEBSITE_FIXTURE"), let session,
           session.userAgent == nil || session.websiteCookies?.contains(where: { $0.name == "site_access" && $0.value == "refreshed-preview" }) != true {
            throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        }
        if UITesting.flag("LEAF_UI_ZLIB_FEED_FAILURE"), session != nil {
            throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        }
        if UITesting.flag("LEAF_UI_ZLIB_POPULAR_REDIRECT"), session != nil {
            let transport = UITestPopularRedirectTransport()
            return try await ZLibraryClient(transport: transport).popular(origin: origin, session: session)
        }
        return sampleBooks()
    }
    private func guardRepeatedRequest(_ key: String, path: String, session: ZLibrarySession?) async throws {
        guard UITesting.flag("LEAF_UI_ZLIB_REPEAT_GUARD"), await UITestCatalogRequestHistory.shared.repeated(key) else { return }
        _ = try await ZLibraryClient(transport: UITestPopularRedirectTransport()).object(path, origin: try ZLibraryOrigin("https://catalog.example"), session: session, form: path == "book/search" ? ["message": "fixture"] : nil)
    }
    private func sampleBooks() -> [ZLibraryBook] {
        let sparse = UITesting.environment("LEAF_UI_ZLIB_DETAILS") != nil
        return [ZLibraryBook(remoteID:"sample",hash:"aabbcc",title:"The Art of Noticing",author:"Leaf Editions",fileExtension:sparse ? "" : "epub",size:sparse ? "" : "1.8 MB",language:sparse ? "" : "English",year:sparse ? "" : "2026",coverURL:nil,rating:4.6,ratingCount:52,qualityScore:4.2),
         ZLibraryBook(remoteID:"sample2",hash:"ccddaa",title:"Notes from the Coast",author:"Rowan Hale",fileExtension:"pdf",size:"2.4 MB",language:"English",year:"2026",coverURL:nil)]
    }
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage {
        try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation()
        try await guardRepeatedRequest("\(query)-\(order.rawValue)-\(page)-\(session?.userID ?? "anonymous")", path: "book/search", session: session)
        if query.lowercased() == "unavailable" { throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "POST /eapi/book/search · HTTP 200 · HTML instead of JSON") }
        if query.lowercased() == "no matches" { return ZLibrarySearchPage(books: [], hasMore: false) }
        var sample = sampleBooks()
        if [.titleAscending, .recentlyAdded, .fileSizeDescending].contains(order) { sample.reverse() }
        if page == 1 { return ZLibrarySearchPage(books: [sample[0]], hasMore: true) }
        return ZLibrarySearchPage(books: sample, hasMore: false)
    }
    func download(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        progress(0.3); try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
        guard let source = Bundle.main.url(forResource: "\(book.title).\(book.fileExtension)", withExtension:nil,subdirectory:"Samples") else { throw ZLibraryError.file }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).\(book.fileExtension)")
        try FileManager.default.copyItem(at:source,to:destination);progress(1);return destination
    }
}
private actor UITestCatalogRequestHistory {
    static let shared = UITestCatalogRequestHistory()
    private var keys: Set<String> = []
    func repeated(_ key: String) -> Bool { !keys.insert(key).inserted }
}
private struct UITestPopularRedirectTransport: ZLibraryTransport {
    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        ZLibraryPayload(data: Data("<html>Fixture access check</html>".utf8), file: nil,
            response: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                headerFields: ["Location": request.url!.absoluteString, "Set-Cookie": "__diamwall=fixture-only; Path=/; Secure"])!)
    }
}

#endif
