import Foundation
import WebKit

/// Two metadata transfers at a time, with cancellable FIFO waiting. A quick
/// scroll must not leave every off-screen edition waiting to hit the website.
@MainActor final class ZLibraryDetailSlots {
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
                waiting.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume() }
    }
}

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
    @Published private(set) var feed: ZLibraryFeed
    @Published private(set) var searchOrder: ZLibrarySearchOrder
    @Published private(set) var canLoadMore = false
    @Published private(set) var searchLimitReached = false
    @Published private(set) var verifying = false
    @Published private(set) var error: String?
    @Published private(set) var requestDiagnostic: String?
    @Published private(set) var websiteAccessNeeded = false
    @Published private(set) var recommendationConnectionRequired = false
    @Published private(set) var connectionError: String?
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress: Double?
    @Published private(set) var importedID: UUID?
    @Published private(set) var importError: String?
    /// The library's Discover shelf: account recommendations, or popular books without an account.
    @Published private(set) var shelf: [ZLibraryBook] = []
    @Published private(set) var shelfFeed: ZLibraryFeed = .popular
    /// Whether the library may request books before the user opens Discover.
    let discoversFromLibrary: Bool
    private var shelfTask: Task<Void, Never>?
    private var shelfGeneration: UUID?
    private struct ShelfCache: Codable {
        let origin: String
        let account: String?
        let feed: String
        let books: [ZLibraryBook]
    }
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
    var matchingContextID: UUID { generation }
    private var downloadTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogRequest = UUID()
    private var searchPage = 0
    private var retryNextPage = false
    @Published private(set) var detailRefresh = 0
    @Published private var detailFailures: Set<String> = []
    private let detailSlots = ZLibraryDetailSlots()
    private struct DetailRequest {
        let id: UUID
        let task: Task<ZLibraryBook, Error>
        var readers: Set<UUID>
    }
    private var detailRequests: [String: DetailRequest] = [:]
    private var detailCache: [String: ZLibraryBook] = [:]
    private var detailOrder: [String] = []
    // Bounded, in-memory navigation state, isolated to the verified account/origin.
    // Both feeds plus the three most recently visited searches (at most 1,300 rows).
    private struct CatalogKey: Hashable {
        let query: String
        let order: String
        let feed: ZLibraryFeed
        init(_ query: String, _ order: ZLibrarySearchOrder, feed: ZLibraryFeed) {
            self.query = query; self.order = query.isEmpty ? "" : order.rawValue
            self.feed = query.isEmpty ? feed : .popular
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
    init(defaults: UserDefaults = .standard, credentials: any ChatCredentialStore = KeychainChatCredentials(service: "com.weizhao.leafreader.zlibrary"), client: (any ZLibraryServing)? = nil, discoversFromLibrary: Bool = true) {
        self.defaults = defaults; self.credentials = credentials; self.clientOverride = client
        self.discoversFromLibrary = discoversFromLibrary
        feed = ZLibraryFeed(rawValue: defaults.string(forKey: "zlibrary.feed") ?? "") ?? .popular
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
        if discoversFromLibrary, let data = defaults.data(forKey: "zlibrary.shelf"),
           let saved = try? JSONDecoder().decode(ShelfCache.self, from: data),
           saved.origin == origin.url.absoluteString, saved.account == session?.userID,
           let feed = ZLibraryFeed(rawValue: saved.feed) {
            shelf = saved.books; shelfFeed = feed
        }
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
        for request in detailRequests.values { request.task.cancel() }
        detailRequests.removeAll(); detailCache.removeAll(); detailOrder.removeAll(); detailFailures.removeAll()
        cancelCatalogLoad(); searchPage = 0; canLoadMore = false; searchLimitReached = false
        books = []; error = nil; requestDiagnostic = nil; websiteAccessNeeded = false
        recommendationConnectionRequired = false
        loading = false; verifying = false; downloadingID = nil; progress = nil
        shelfTask?.cancel(); shelfTask = nil; shelfGeneration = nil
        shelf = []; defaults.removeObject(forKey: "zlibrary.shelf")
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
    func loadPopular() async { await browse(.popular) }
    func browse(_ feed: ZLibraryFeed) async {
        if feed != self.feed {
            cancelCatalogLoad()
            self.feed = feed; defaults.set(feed.rawValue, forKey: "zlibrary.feed")
        }
        await loadCatalog(query: "")
    }
    func search(_ query: String) async { await loadCatalog(query: query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    /// A discovery lookup shares the verified account and website transport, but
    /// does not replace the visible catalog query, feed, pagination or errors.
    func matchingSearch(_ query: String) async throws -> [ZLibraryBook] {
        let token = generation, source = origin
        do {
            if session == nil { session = try savedSession(for: source); websiteUserAgent = session?.userAgent }
            guard let saved = session else { throw ZLibraryError.signInRequired }
            try await prepareCatalogWebsiteContext(request: UUID())
            try Task.checkCancellation(); guard token == generation else { throw CancellationError() }
            if !connected {
                let profile = try await client.profile(origin: source, session: saved)
                try Task.checkCancellation(); guard token == generation else { throw CancellationError() }
                connected = true; accountName = profile.name; remaining = profile.remaining
            }
            let page = try await client.search(String(query.prefix(500)), page: 1, order: .bestMatch, origin: source, session: saved)
            try Task.checkCancellation(); guard token == generation, connected else { throw CancellationError() }
            return page.books
        } catch {
            guard token == generation else { throw CancellationError() }
            if ZLibraryRequestFailure.issue(error) == .signInRequired { connected = false }
            throw error
        }
    }
    func setSearchOrder(_ order: ZLibrarySearchOrder) async {
        guard order != searchOrder else { return }
        searchOrder = order; defaults.set(order.rawValue, forKey: "zlibrary.searchOrder")
        // A new order is a new result set. Cancel even when the submitted query is
        // identical, and restart at page one so differently ordered pages never mix.
        if !activeQuery.isEmpty { cancelCatalogLoad(); await reload() }
    }
    /// Selects what Discover shows; its view performs the load when it appears.
    func show(_ feed: ZLibraryFeed) {
        cancelCatalogLoad(); activeQuery = ""
        if feed != self.feed { self.feed = feed; defaults.set(feed.rawValue, forKey: "zlibrary.feed") }
    }
    func show(query: String) {
        cancelCatalogLoad(); activeQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Loads the shelf once per account. It reuses a Discover list already loaded
    /// for the same feed, and keeps its saved books when a request fails; Discover
    /// is where failures are explained.
    func loadShelf() async {
        guard discoversFromLibrary, shelfGeneration != generation else { return }
        if let shelfTask { return await shelfTask.value }
        let token = generation, source = origin
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                if self.session == nil {
                    self.session = try self.savedSession(for: source)
                    self.websiteUserAgent = self.session?.userAgent
                }
                let saved = self.session, feed: ZLibraryFeed = saved == nil ? .popular : .recommended
                let books: [ZLibraryBook]
                if let listed = self.snapshots[CatalogKey("", self.searchOrder, feed: feed)] {
                    books = listed.books
                } else {
                    try await self.prepareCatalogWebsiteContext(request: UUID())
                    try Task.checkCancellation(); guard token == self.generation else { return }
                    if let saved, feed == .recommended {
                        books = try await self.client.recommended(origin: source, session: saved)
                    } else { books = try await self.client.popular(origin: source, session: saved) }
                }
                try Task.checkCancellation(); guard token == self.generation else { return }
                self.shelfGeneration = token; self.shelfFeed = feed
                self.shelf = books.prefix(12).map { book in self.detailCache[book.id].map { book.fillingMissingDetails(from: $0) } ?? book }
                let cache = ShelfCache(origin: source.url.absoluteString, account: saved?.userID, feed: feed.rawValue, books: self.shelf)
                self.defaults.set(try? JSONEncoder().encode(cache), forKey: "zlibrary.shelf")
            } catch {
                // One attempt per account and launch; reopening the library must not repeat it.
                if token == self.generation && !Task.isCancelled && !Self.isCancellation(error) { self.shelfGeneration = token }
            }
        }
        shelfTask = task
        await task.value
        if token == generation { shelfTask = nil }
    }
    /// First-page matches for a library search. Discover still performs its own
    /// search, so it verifies the account and keeps its pagination state.
    func searchPreview(_ query: String) async -> [ZLibraryBook] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard discoversFromLibrary, !query.isEmpty else { return [] }
        if let listed = snapshots[CatalogKey(query, searchOrder, feed: feed)] { return listed.books }
        let token = generation, source = origin, order = searchOrder
        do {
            try await prepareCatalogWebsiteContext(request: UUID())
            try Task.checkCancellation(); guard token == generation else { return [] }
            let page = try await client.search(query, page: 1, order: order, origin: source, session: session)
            try Task.checkCancellation()
            return token == generation ? page.books : []
        } catch { return [] }
    }
    func reload() async {
        detailFailures.removeAll(); detailRefresh += 1
        await loadCatalog(query: activeQuery, refresh: true)
    }
    func retry() async {
        if retryNextPage { await loadMore() } else { await reload() }
    }
    func loadMore() async {
        guard !activeQuery.isEmpty, canLoadMore, !loading else { return }
        await loadCatalog(query: activeQuery, append: true)
    }
    func cancelCatalogLoad(_ reason: String = "replaced") {
        if catalogTask != nil { traceCatalogLoad("cancel \(reason)", request: catalogRequest) }
        catalogTask?.cancel(); catalogTask = nil; catalogRequest = UUID(); loading = false
    }
    private func loadCatalog(query: String, append: Bool = false, refresh: Bool = false) async {
        if loading && query == activeQuery { return }
        cancelCatalogLoad()
        let request = catalogRequest, token = generation, source = origin, order = searchOrder, feed = self.feed
        traceCatalogLoad("start \(query.isEmpty ? feed.rawValue : "search")\(refresh ? " refresh" : "")\(append ? " more" : "")", request: request)
        activeQuery = query; retryNextPage = append
        error = nil; requestDiagnostic = nil; websiteAccessNeeded = false
        recommendationConnectionRequired = false
        if !append {
            let restored = restore(CatalogKey(query, order, feed: feed))
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
            await self.performLoad(query: query, feed: feed, page: page, order: order, append: append, request: request, token: token, source: source)
        }
        // Hold a cancellable task: a query change cancels network work as well as rejecting stale results.
        catalogTask = task
        // The load belongs to the catalog, not to the view action awaiting it. SwiftUI cancels a
        // refresh or .task when the content it shows changes; forwarding that cancelled the current
        // request and suppressed its error, leaving an empty catalog (QA76-002). Replacing a load and
        // leaving Discover cancel it explicitly through cancelCatalogLoad.
        await task.value
    }
    private func performLoad(query: String, feed: ZLibraryFeed, page: Int, order: ZLibrarySearchOrder, append: Bool, request: UUID, token: UUID, source: ZLibraryOrigin) async {
        defer {
            traceCatalogLoad("finished cancelled=\(Task.isCancelled)", request: request)
            if token == generation && request == catalogRequest { loading = false; catalogTask = nil }
        }
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
            try await prepareCatalogWebsiteContext(request: request)
            try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
            let saved = session
            if let saved, !connected {
                let profile = try await client.profile(origin: source, session: saved)
                try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
                connected = true; accountName = profile.name; remaining = profile.remaining
            }
            let result: [ZLibraryBook], more: Bool
            traceCatalogLoad("request \(query.isEmpty ? feed.rawValue : "search")", request: request)
            if query.isEmpty {
                if feed == .recommended {
                    guard let saved else { recommendationConnectionRequired = true; return }
                    result = try await client.recommended(origin: source, session: saved)
                } else { result = try await client.popular(origin: source, session: saved) }
                more = false
            }
            else {
                let response = try await client.search(query, page: page, order: order, origin: source, session: saved)
                result = response.books; more = response.hasMore
            }
            try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
            traceCatalogLoad("received rows=\(result.count)", request: request)
            let existing = append ? Set(books.map(\.id)) : []
            let resolved = result.map { book in detailCache[book.id].map { book.fillingMissingDetails(from: $0) } ?? book }
            let added = resolved.filter { !existing.contains($0.id) }
            books = append ? books + added : resolved
            searchPage = query.isEmpty ? 0 : page
            searchLimitReached = !query.isEmpty && more && page >= ZLibrarySearchPage.maximumPages
            canLoadMore = !query.isEmpty && more && !added.isEmpty && !searchLimitReached
            let key = CatalogKey(query, order, feed: feed)
            snapshots[key] = CatalogSnapshot(books: books, page: searchPage, canLoadMore: canLoadMore, limitReached: searchLimitReached)
            touch(key); showingSavedResults = false
        } catch {
            traceCatalogLoad("failed current=\(token == generation && request == catalogRequest) cancelled=\(Task.isCancelled || Self.isCancellation(error))", request: request)
            if token == generation && request == catalogRequest && !Task.isCancelled && !Self.isCancellation(error) {
                let issue = ZLibraryRequestFailure.issue(error)
                if issue == .signInRequired {
                    connected = false
                    recommendationConnectionRequired = query.isEmpty && feed == .recommended
                }
                websiteAccessNeeded = issue == .challenge || issue == .accessCheck
                requestDiagnostic = (error as? ZLibraryRequestFailure)?.diagnostic
                if issue == .accessCheck {
                    self.error = ZLibraryError.accessCheck.localizedDescription + (connected ? " Your account remains connected." : "")
                } else {
                    self.error = connected && websiteAccessNeeded
                        ? (query.isEmpty ? (feed == .recommended ? "Your account is connected, but the website did not return recommendations. Open the website to check access, then try again." : "Your account is connected, but the website did not return popular-book data. Open the website to check access, then try again.") : "Your account is connected, but the website did not return search results. Open the website to check access, then try again.")
                        : error.localizedDescription
                }
            }
        }
    }
    private func prepareCatalogWebsiteContext(request: UUID) async throws {
        #if DEBUG
        // Ordinary offline fixtures use account IDs from the fake client, not
        // browser cookies. Keep them independent of WebKit network-process IPC.
        // Dedicated website fixtures continue to exercise real cookie storage.
        if isPreview && !UITesting.flag(.zlibWebsiteFixture) {
            traceCatalogLoad("offline client: browser context not required", request: request)
            return
        }
        #endif
        traceCatalogLoad("seed website", request: request)
        await seedWebsite()
        traceCatalogLoad("save website context", request: request)
        try await saveWebsiteContext()
        traceCatalogLoad("website ready", request: request)
    }
    func traceCatalogLoad(_ event: String, request: UUID? = nil) {
        #if DEBUG
        // Offline UI fixtures can trace lifecycle stalls without logging queries,
        // account identities, cookies or any real network response.
        guard UITesting.flag(.zlibMock) else { return }
        let id = request.map { String($0.uuidString.prefix(4)) } ?? "view"
        print("[ZLibraryLoad] \(id) \(event)")
        // Shown to UI tests that opt in, so a failure report carries the sequence.
        if UITesting.flag(.zlibTrace) { loadTrace = Array((loadTrace + ["\(id) \(event)"]).suffix(24)) }
        #endif
    }
    #if DEBUG
    @Published private(set) var loadTrace: [String] = []
    var cachedDetailCount: Int { detailCache.count }
    #endif
    /// One edition's details; `description` also fetches a listed book for its description.
    /// The book whose details page is showing, for Ask Leaf; read when a tool runs, so not published.
    private(set) var viewingBook: ZLibraryBook?
    func beginViewing(_ book: ZLibraryBook) { viewingBook = book }
    /// A page that disappears after the next one appeared must not clear the newer one.
    func endViewing(_ book: ZLibraryBook) { if viewingBook?.id == book.id { viewingBook = nil } }
    /// The newest known copy of a listed or viewed edition, with any details fetched since.
    func latest(_ book: ZLibraryBook) -> ZLibraryBook { (books + shelf).first { $0.id == book.id && !$0.fileExtension.isEmpty } ?? book }
    /// Unknown list fields are pending, rather than proof the provider has no metadata.
    func cardDetailsPending(_ book: ZLibraryBook) -> Bool {
        detailCache[book.id] == nil && !detailFailures.contains(book.id)
            && (book.fileExtension.isEmpty || book.size.isEmpty || book.language.isEmpty || book.year.isEmpty || book.rating == nil)
    }
    func cardDetailsFailed(_ book: ZLibraryBook) -> Bool { detailFailures.contains(book.id) }
    /// A cell owns its subscription. Recycling it cancels queued work; another
    /// visible cell or the details page can keep the same request alive.
    func loadCardDetails(_ book: ZLibraryBook) async {
        guard !Task.isCancelled else { return }
        if let cached = detailCache[book.id] { updateDetails(latest(book).fillingMissingDetails(from: cached)); return }
        guard cardDetailsPending(book) else { return }
        let token = generation
        do {
            var resolved = try await fetchDetails(book)
            try Task.checkCancellation()
            guard token == generation else { return }
            resolved.summary = resolved.summary ?? ""
            // Another completion may already have evicted this edition. Do not
            // put it back outside the bounded cache's insertion/eviction path.
            if detailCache[book.id] != nil { detailCache[book.id] = resolved }
            updateDetails(latest(book).fillingMissingDetails(from: resolved))
        } catch {
            if token == generation && !Task.isCancelled && !Self.isCancellation(error) {
                detailFailures.insert(book.id)
            }
        }
    }
    private func fetchDetails(_ book: ZLibraryBook) async throws -> ZLibraryBook {
        try Task.checkCancellation()
        if let cached = detailCache[book.id] { return cached }
        let reader = UUID()
        if detailRequests[book.id] == nil {
            let id = UUID(), token = generation, source = origin, saved = session, service = client
            let task = Task { [self] () throws -> ZLibraryBook in
                defer { if detailRequests[book.id]?.id == id { detailRequests[book.id] = nil } }
                try await detailSlots.acquire()
                defer { detailSlots.release() }
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                let resolved = try await service.details(book, origin: source, session: saved)
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                detailCache[book.id] = resolved
                detailFailures.remove(book.id)
                detailOrder.removeAll { $0 == book.id }; detailOrder.append(book.id)
                while detailOrder.count > 200 { detailCache[detailOrder.removeFirst()] = nil }
                return resolved
            }
            detailRequests[book.id] = DetailRequest(id: id, task: task, readers: [])
        }
        detailRequests[book.id]?.readers.insert(reader)
        guard let request = detailRequests[book.id] else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            let resolved = try await request.task.value
            try Task.checkCancellation()
            return resolved
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDetails(reader, book: book.id, request: request.id) }
        }
    }
    private func cancelDetails(_ reader: UUID, book: String, request id: UUID) {
        guard var request = detailRequests[book], request.id == id else { return }
        request.readers.remove(reader)
        if request.readers.isEmpty { detailRequests[book] = nil; request.task.cancel() }
        else { detailRequests[book] = request }
    }
    private func updateDetails(_ resolved: ZLibraryBook) {
        if let index = books.firstIndex(where: { $0.id == resolved.id }) { books[index] = resolved }
        if let index = shelf.firstIndex(where: { $0.id == resolved.id }) { shelf[index] = resolved }
        for (key, snapshot) in snapshots {
            guard let index = snapshot.books.firstIndex(where: { $0.id == resolved.id }) else { continue }
            var rows = snapshot.books; rows[index] = resolved
            snapshots[key] = CatalogSnapshot(books: rows, page: snapshot.page, canLoadMore: snapshot.canLoadMore, limitReached: snapshot.limitReached)
        }
    }
    func details(_ book: ZLibraryBook, description: Bool = false) async throws -> ZLibraryBook {
        if let cached = (books + shelf).first(where: { $0.id == book.id }), !cached.fileExtension.isEmpty, !description || cached.summary != nil { return cached }
        let token = generation
        do {
            var resolved = try await fetchDetails(book)
            // Fetched without one: the catalog has no description, so it is not asked again.
            if description, resolved.summary == nil { resolved.summary = "" }
            // Keep known listing fields while enriching its description and missing metadata.
            if description, let listed = (books + shelf).first(where: { $0.id == book.id }), !listed.fileExtension.isEmpty {
                resolved = listed.fillingMissingDetails(from: resolved)
            }
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            updateDetails(resolved)
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
