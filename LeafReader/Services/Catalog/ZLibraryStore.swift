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
    private var websiteUserAgent: String?
    var websiteData: WKWebsiteDataStore {
        if let signInData { return signInData }
        let data = WKWebsiteDataStore.nonPersistent(); signInData = data; return data
    }
    private let defaults: UserDefaults
    private let credentials: any ChatCredentialStore
    private let client: any ZLibraryServing
    private var session: ZLibrarySession?
    private var generation = UUID()
    private var downloadTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var catalogRequest = UUID()
    private var searchPage = 0
    private var retryNextPage = false
    #if DEBUG
    let isPreview: Bool
    #else
    let isPreview = false
    #endif
    init(defaults: UserDefaults = .standard, credentials: any ChatCredentialStore = KeychainChatCredentials(service: "com.weizhao.leafreader.zlibrary"), client: any ZLibraryServing = ZLibraryClient()) {
        self.defaults = defaults; self.credentials = credentials; self.client = client
        searchOrder = ZLibrarySearchOrder(rawValue: defaults.string(forKey: "zlibrary.searchOrder") ?? "") ?? .popular
        origin = (try? ZLibraryOrigin(defaults.string(forKey: "zlibrary.origin") ?? "https://z-library.sk")) ?? (try! ZLibraryOrigin("https://z-library.sk"))
        #if DEBUG
        isPreview = client is UITestZLibraryClient
        #endif
        do { session = try credentials.read(account: origin.url.absoluteString).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ZLibrarySession.self, from: $0) }
            if session?.valid != true { session = nil }
            accountName = session == nil ? "" : "Saved account"
        } catch { connectionError = "Leaf could not read your saved connection. Unlock your device and try again." }
    }
    func changeAddress(_ address: String) async throws {
        let next = try ZLibraryOrigin(address)
        guard next != origin else { return }
        try await disconnect()
        origin = next; defaults.set(next.url.absoluteString, forKey: "zlibrary.origin")
        session = try credentials.read(account: next.url.absoluteString).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ZLibrarySession.self, from: $0) }
        if session?.valid != true { session = nil }
        await clearWebsite()
    }
    func clearWebsite() async {
        websiteUserAgent = nil
        guard let signInData else { return }
        await signInData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    func disconnect() async throws {
        try credentials.write(nil, account: origin.url.absoluteString)
        generation = UUID(); downloadTask?.cancel(); downloadTask = nil
        cancelCatalogLoad(); activeQuery = ""; searchPage = 0; canLoadMore = false; searchLimitReached = false
        session = nil; connected = false; accountName = ""; remaining = nil; books = []; error = nil; connectionError = nil
        requestDiagnostic = nil; websiteAccessNeeded = false
        loading = false; verifying = false; downloadingID = nil; progress = nil
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
            let encoded = try JSONEncoder().encode(candidate)
            do { try credentials.write(String(decoding: encoded, as: UTF8.self), account: source.url.absoluteString) }
            catch { throw ZLibraryError.service("Leaf could not save the Z-Library session in Keychain. Your existing connection was kept.") }
            // Discard responses started with the old account (including anonymous feed loads).
            generation = UUID(); downloadTask?.cancel(); downloadTask = nil
            cancelCatalogLoad(); searchPage = 0; canLoadMore = false; searchLimitReached = false
            loading = false; verifying = false; downloadingID = nil; progress = nil; books = []
            error = nil; requestDiagnostic = nil; websiteAccessNeeded = false
            session = candidate; connected = true; accountName = profile.name; remaining = profile.remaining
            return true
        } catch {
            if token == generation && !Task.isCancelled && !Self.isCancellation(error) { connectionError = error.localizedDescription }
            return false
        }
    }
    func cookieCandidate(_ cookies: [HTTPCookie]) -> ZLibrarySession? {
        let trusted = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            // This cookie store belongs to an HTTPS-only sign-in view. Verify account identity
            // over HTTPS even when the website omits Secure on its own issued cookies.
            return domain == origin.url.host && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        guard let user = trusted.first(where: { $0.name == "remix_userid" }), let key = trusted.first(where: { $0.name == "remix_userkey" }) else { return nil }
        let context = trusted.filter { !["remix_userid", "remix_userkey"].contains($0.name) }.map {
            ZLibraryWebsiteCookie(name: $0.name, value: $0.value, path: $0.path, expires: $0.expiresDate)
        }.filter(\.valid)
        let candidate = ZLibrarySession(userID: user.value, userKey: key.value, websiteCookies: context, userAgent: websiteUserAgent)
        return candidate.valid ? candidate : nil
    }
    func captureWebsiteUserAgent(_ text: String) {
        if ZLibrarySession.validUserAgent(text) { websiteUserAgent = text }
    }
    func seedWebsite() async {
        guard let session else { return }
        let source = origin, data = websiteData, token = generation
        websiteUserAgent = session.userAgent
        for (name, value) in [("remix_userid",session.userID),("remix_userkey",session.userKey)] {
            guard token == generation else { return }
            if let cookie = HTTPCookie(properties: [.domain:source.url.host!, .path:"/", .name:name, .value:value, .secure:"TRUE"]) {
                await data.httpCookieStore.setCookie(cookie)
            }
        }
        for context in session.websiteCookies ?? [] where context.valid && (context.expires.map { $0 > Date() } ?? true) {
            guard token == generation else { return }
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
    func reload() async { await loadCatalog(query: activeQuery) }
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
    private func loadCatalog(query: String, append: Bool = false) async {
        if loading && query == activeQuery { return }
        cancelCatalogLoad()
        let request = catalogRequest, token = generation, source = origin, order = searchOrder
        activeQuery = query; retryNextPage = append
        if !append { books = []; searchPage = 0; canLoadMore = false; searchLimitReached = false }
        loading = true; error = nil; requestDiagnostic = nil; websiteAccessNeeded = false
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
        var saved = session
        defer { if token == generation && request == catalogRequest { loading = false; catalogTask = nil } }
        do {
            try Task.checkCancellation()
            // Reuse only this origin's browser context and only for the same verified account.
            // Opening/closing the website can refresh access without another account sign-in.
            if let existing = saved, let signInData {
                let cookies = await signInData.httpCookieStore.allCookies()
                try Task.checkCancellation(); guard token == generation && request == catalogRequest else { return }
                if let candidate = cookieCandidate(cookies), candidate.userID == existing.userID, candidate.userKey == existing.userKey, candidate != existing {
                    let encoded = try JSONEncoder().encode(candidate)
                    try credentials.write(String(decoding: encoded, as: UTF8.self), account: source.url.absoluteString)
                    session = candidate; saved = candidate
                }
            }
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
        } catch {
            if token == generation && request == catalogRequest && !Task.isCancelled && !Self.isCancellation(error) {
                let issue = ZLibraryRequestFailure.issue(error)
                if issue == .signInRequired { connected = false }
                websiteAccessNeeded = issue == .challenge
                requestDiagnostic = (error as? ZLibraryRequestFailure)?.diagnostic
                self.error = connected && websiteAccessNeeded
                    ? (query.isEmpty ? "Your account is connected, but the website did not return popular-book data. Open the website to check access, then try again." : "Your account is connected, but the website did not return search results. Open the website to check access, then try again.")
                    : error.localizedDescription
            }
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
    func profile(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> ZLibraryProfile { ZLibraryProfile(name:"Preview account",remaining:5) }
    func popular(origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> [ZLibraryBook] {
        if ProcessInfo.processInfo.environment["LEAF_UI_ZLIB_FEED_FAILURE"] == "1", session != nil {
            throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        }
        return [ZLibraryBook(remoteID:"sample",hash:"aabbcc",title:"The Art of Noticing",author:"Leaf Editions",fileExtension:"epub",size:"1.8 MB",language:"English",year:"2026",coverURL:nil,rating:4.6,ratingCount:52,qualityScore:4.2),
         ZLibraryBook(remoteID:"sample2",hash:"ccddaa",title:"Notes from the Coast",author:"Rowan Hale",fileExtension:"pdf",size:"2.4 MB",language:"English",year:"2026",coverURL:nil)]
    }
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage {
        try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation()
        if query.lowercased() == "unavailable" { throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "POST /eapi/book/search · HTTP 200 · HTML instead of JSON") }
        if query.lowercased() == "no matches" { return ZLibrarySearchPage(books: [], hasMore: false) }
        var sample = try await popular(origin: origin, session: session)
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
#endif
