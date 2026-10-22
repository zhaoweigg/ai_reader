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
    @Published private(set) var verifying = false
    @Published private(set) var error: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress: Double?
    @Published private(set) var importedID: UUID?
    @Published private(set) var importError: String?
    private var signInData: WKWebsiteDataStore?
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
    #if DEBUG
    let isPreview: Bool
    #else
    let isPreview = false
    #endif
    init(defaults: UserDefaults = .standard, credentials: any ChatCredentialStore = KeychainChatCredentials(service: "com.weizhao.leafreader.zlibrary"), client: any ZLibraryServing = ZLibraryClient()) {
        self.defaults = defaults; self.credentials = credentials; self.client = client
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
        guard let signInData else { return }
        await signInData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    func disconnect() async throws {
        try credentials.write(nil, account: origin.url.absoluteString)
        generation = UUID(); downloadTask?.cancel(); downloadTask = nil
        session = nil; connected = false; accountName = ""; remaining = nil; books = []; error = nil; connectionError = nil
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
            loading = false; verifying = false; downloadingID = nil; progress = nil; books = []
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
        let candidate = ZLibrarySession(userID: user.value, userKey: key.value)
        return candidate.valid ? candidate : nil
    }
    func seedWebsite() async {
        guard let session else { return }
        for (name, value) in [("remix_userid",session.userID),("remix_userkey",session.userKey)] {
            if let cookie = HTTPCookie(properties: [.domain:origin.url.host!, .path:"/", .name:name, .value:value, .secure:"TRUE"]) {
                await websiteData.httpCookieStore.setCookie(cookie)
            }
        }
    }
    func loadPopular() async {
        guard !loading else { return }
        loading = true; error = nil
        let token = generation, source = origin, saved = session
        defer { if token == generation { loading = false } }
        do {
            if let saved, !connected {
                let profile = try await client.profile(origin: source, session: saved)
                guard token == generation else { return }
                connected = true; accountName = profile.name; remaining = profile.remaining
            }
            let result = try await client.popular(origin: source, session: saved)
            try Task.checkCancellation(); guard token == generation else { return }
            books = result
        } catch {
            if token == generation && !Task.isCancelled && !Self.isCancellation(error) {
                if error as? ZLibraryError == .signInRequired { connected = false }
                self.error = error.localizedDescription
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
                    if error as? ZLibraryError == .signInRequired { self.connected = false }
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
        [ZLibraryBook(remoteID:"sample",hash:"aabbcc",title:"The Art of Noticing",author:"Leaf Editions",fileExtension:"epub",size:"Sample",language:"English",year:"2026",coverURL:nil),
         ZLibraryBook(remoteID:"sample2",hash:"ccddaa",title:"Notes from the Coast",author:"Rowan Hale",fileExtension:"pdf",size:"Sample",language:"English",year:"2026",coverURL:nil)]
    }
    func download(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        progress(0.3); try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
        guard let source = Bundle.main.url(forResource: "\(book.title).\(book.fileExtension)", withExtension:nil,subdirectory:"Samples") else { throw ZLibraryError.file }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).\(book.fileExtension)")
        try FileManager.default.copyItem(at:source,to:destination);progress(1);return destination
    }
}
#endif
