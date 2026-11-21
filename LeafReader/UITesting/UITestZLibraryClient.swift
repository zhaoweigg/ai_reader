import Foundation

#if DEBUG
struct UITestZLibraryClient: ZLibraryServing {
    func recommended(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> [ZLibraryBook] {
        if UITesting.flag(.zlibShelfRetry), !(await UITestCatalogRequestHistory.shared.repeated("library-shelf-retry")) {
            throw ZLibraryRequestFailure(issue: .accessCheck, diagnostic: "Offline shelf retry fixture")
        }
        if UITesting.flag(.zlibShelfEmpty) { return [] }
        if UITesting.flag(.zlibShelfRefresh) {
            let refreshed = await UITestCatalogRequestHistory.shared.repeated("library-shelf-refresh")
            return [ZLibraryBook(remoteID: refreshed ? "shelf-refreshed" : "shelf-initial", hash: "shelf-fixture",
                title: refreshed ? "Refreshed recommendations" : "First recommendations", author: "Leaf Editions",
                fileExtension: "txt", size: "18 KB", language: "English", year: "2026", coverURL: nil)]
        }
        if UITesting.flag(.bestsellersMock) { return UITestBestsellerClient.samples().reversed().flatMap(UITestBestsellerClient.editions) }
        try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation()
        try await guardRepeatedRequest("recommended-" + session.userID, path: "user/book/recommended", session: session)
        if UITesting.flag(.zlibRecommendationsEmpty) { return [] }
        if UITesting.flag(.zlibRecommendationsFailure) {
            throw ZLibraryRequestFailure(issue: .accessCheck, diagnostic: "GET /eapi/user/book/recommended · browser redirect · website verification required")
        }
        let books = [ZLibraryBook(remoteID:"recommended",hash:"ddeeff",title:"A Field Guide to Slow Days",author:"Leaf Editions",fileExtension:"txt",size:"18 KB",language:"English",year:"2026",coverURL:nil,rating:4.7,ratingCount:18)]
        if UITesting.flag(.zlibAsyncDetails) { return sampleBooks() }
        return UITesting.flag(.zlibGrid) ? books + sampleBooks() : books
    }
    func details(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibraryBook {
        if UITesting.flag(.bestsellersMock) || UITesting.flag(.webNovelsMock) { return book }
        let summaryMode = UITesting.value(.zlibSummary)
        if summaryMode == "loading" { try await Task.sleep(for:.seconds(4)) }
        try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
        if UITesting.value(.zlibDetails) == "failure" { throw ZLibraryError.metadata }
        if summaryMode == "retry", !(await UITestCatalogRequestHistory.shared.repeated("summary-" + book.id)) { throw ZLibraryError.response }
        let summary: String?
        switch summaryMode {
        case "missing": summary = nil
        case "short": summary = "A quiet guide to noticing everyday life."
        case "long", "loading", "retry": summary = String(repeating:"A reader learns to notice the small details of everyday life, from morning light to the sounds of the coast. ",count:6) + "The final passage brings those observations together."
        case "chinese": summary = String(repeating:"这本书讲述了一个人在日常生活中重新发现细节的故事，从清晨的光线到海边的声音。",count:8) + "最后一段将这些观察串联起来。"
        default: summary = "A fixture description of \(book.title)."
        }
        return ZLibraryBook(remoteID: book.remoteID, hash: book.hash, title: book.title, author: book.author,
                            fileExtension: UITesting.value(.zlibDetails) == "unsupported" ? "djvu" : "epub",
                            size: "1 MB", language: "English", year: "2026", coverURL: book.coverURL,
                            rating: UITesting.flag(.zlibAsyncDetails) ? 4.8 : book.rating,
                            ratingCount: UITesting.flag(.zlibAsyncDetails) ? 42 : book.ratingCount, qualityScore: book.qualityScore,
                            summary: summary)
    }
    func profile(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> ZLibraryProfile {
        ZLibraryProfile(name: "Preview account", remaining: UITesting.flag(.bestsellersQuota) ? 0 : 5)
    }
    func popular(origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> [ZLibraryBook] {
        if UITesting.flag(.bestsellersMock) { return UITestBestsellerClient.samples().flatMap(UITestBestsellerClient.editions) }
        try await guardRepeatedRequest("popular-" + (session?.userID ?? "anonymous"), path: "book/most-popular", session: session)
        if UITesting.flag(.zlibWebsiteFixture), let session,
           session.userAgent == nil || session.websiteCookies?.contains(where: { $0.name == "site_access" && $0.value == "refreshed-preview" }) != true {
            throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        }
        if UITesting.flag(.zlibFeedFailure), session != nil {
            throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "GET /eapi/book/most-popular · HTTP 200 · HTML instead of JSON")
        }
        if UITesting.flag(.zlibPopularRedirect), session != nil {
            let transport = UITestPopularRedirectTransport()
            return try await ZLibraryClient(transport: transport).popular(origin: origin, session: session)
        }
        return sampleBooks()
    }
    private func guardRepeatedRequest(_ key: String, path: String, session: ZLibrarySession?) async throws {
        guard UITesting.flag(.zlibRepeatGuard), await UITestCatalogRequestHistory.shared.repeated(key) else { return }
        _ = try await ZLibraryClient(transport: UITestPopularRedirectTransport()).object(path, origin: try ZLibraryOrigin("https://catalog.example"), session: session, form: path == "book/search" ? ["message": "fixture"] : nil)
    }
    private func sampleBooks() -> [ZLibraryBook] {
        if UITesting.flag(.zlibAsyncDetails) {
            return (1...15).map { ZLibraryBook(remoteID: "async\($0)", hash: "abc\($0)", title: "Background book \($0)",
                author: "Leaf Editions", fileExtension: "", size: "", language: "", year: "", coverURL: nil) }
        }
        if UITesting.flag(.zlibThumbnails) {
            return (0..<72).map { index in ZLibraryBook(remoteID: "cover\(index)", hash: "cover\(index)",
                title: "Catalog cover \(index + 1)", author: "Leaf Editions", fileExtension: "epub", size: "1 MB", language: "English", year: "2026",
                coverURL: URL(string: "https://covers.example/\(index).png")) }
        }
        let sparse = UITesting.value(.zlibDetails) != nil
        let books = [ZLibraryBook(remoteID:"sample",hash:"aabbcc",title:"The Art of Noticing",author:"Leaf Editions",fileExtension:sparse ? "" : "epub",size:sparse ? "" : "1.8 MB",language:sparse ? "" : "English",year:sparse ? "" : "2026",coverURL:nil,rating:4.6,ratingCount:52,qualityScore:4.2),
         ZLibraryBook(remoteID:"sample2",hash:"ccddaa",title:"Notes from the Coast",author:"Rowan Hale",fileExtension:"pdf",size:"2.4 MB",language:"English",year:"2026",coverURL:nil)]
        guard UITesting.flag(.zlibGrid) else { return books }
        return books + [
            ZLibraryBook(remoteID:"grid3",hash:"grid3",title:"墓碑：中国六十年代大饥荒纪实",author:"杨继绳",fileExtension:"pdf",size:"26.8 MB",language:"Chinese",year:"2008",coverURL:nil,rating:4.8,ratingCount:123),
            ZLibraryBook(remoteID:"grid4",hash:"grid4",title:"Thinking, Fast and Slow",author:"Daniel Kahneman",fileExtension:"epub",size:"",language:"English",year:"2011",coverURL:nil),
            ZLibraryBook(remoteID:"grid5",hash:"grid5",title:"A Longer Book Title That Wraps Across Several Lines",author:"An author with a long name",fileExtension:"pdf",size:"128 MB",language:"English",year:"2025",coverURL:nil,rating:4.2,ratingCount:8),
            ZLibraryBook(remoteID:"grid6",hash:"grid6",title:"十日终焉",author:"杀虫队队员",fileExtension:"epub",size:"12.6 MB",language:"Chinese",year:"2026",coverURL:nil)
        ]
    }
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage {
        if UITesting.flag(.bestsellersMock) { return ZLibrarySearchPage(books: UITestBestsellerClient.search(query), hasMore: false) }
        if UITesting.flag(.webNovelsMock) { return ZLibrarySearchPage(books: UITestWebNovelClient.search(query), hasMore: false) }
        try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation()
        try await guardRepeatedRequest("\(query)-\(order.rawValue)-\(page)-\(session?.userID ?? "anonymous")", path: "book/search", session: session)
        if query.lowercased() == "unavailable" { throw ZLibraryRequestFailure(issue: .challenge, diagnostic: "POST /eapi/book/search · HTTP 200 · HTML instead of JSON") }
        if query.lowercased() == "no matches" { return ZLibrarySearchPage(books: [], hasMore: false) }
        var sample = sampleBooks()
        if UITesting.flag(.zlibGrid) { return ZLibrarySearchPage(books: sample, hasMore: false) }
        if [.titleAscending, .recentlyAdded, .fileSizeDescending].contains(order) { sample.reverse() }
        if page == 1 { return ZLibrarySearchPage(books: [sample[0]], hasMore: true) }
        return ZLibrarySearchPage(books: sample, hasMore: false)
    }
    func download(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        if UITesting.flag(.bestsellersMock) || UITesting.flag(.webNovelsMock) { return try await UITestBestsellerClient.download(book, progress: progress) }
        progress(0.3); try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
        guard let source = Bundle.main.url(forResource: "\(book.title).\(book.fileExtension)", withExtension:nil,subdirectory:"Samples") else { throw ZLibraryError.file }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).\(book.fileExtension)")
        try FileManager.default.copyItem(at:source,to:destination);progress(1);return destination
    }
}
actor UITestCatalogRequestHistory {
    static let shared = UITestCatalogRequestHistory()
    private var keys: Set<String> = []
    func repeated(_ key: String) -> Bool { !keys.insert(key).inserted }
}
struct UITestPopularRedirectTransport: ZLibraryTransport {
    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        ZLibraryPayload(data: Data("<html>Fixture access check</html>".utf8), file: nil,
            response: HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil,
                headerFields: ["Location": request.url!.absoluteString, "Set-Cookie": "__diamwall=fixture-only; Path=/; Secure"])!)
    }
}

#endif
