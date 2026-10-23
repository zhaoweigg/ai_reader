import Foundation
import CoreFoundation

// The mobile EAPI is unofficial. Keep wire details outside the library and reader.
enum ZLibraryError: LocalizedError, Equatable {
    case address, query, signInRequired, challenge, accessCheck, response, metadata, service(String), size, file, busy
    var errorDescription: String? {
        switch self {
        case .address: return "Enter an HTTPS website address without a path, port, or sign-in details."
        case .query: return "Enter a title, author, or ISBN of up to 500 characters."
        case .signInRequired: return "Connect your Z-Library account to continue."
        case .challenge: return "The website returned a page or redirect instead of book data. Open the website to check access, then try again."
        case .accessCheck: return "The website is requesting a browser access check instead of returning book data. Open the website to review access. If it keeps returning, wait before retrying."
        case .response: return "Z-Library returned an unexpected response. Try again later."
        case .metadata: return "This book’s format is not available yet. Try loading its details again."
        case .service(let message): return message
        case .size: return "This download exceeds Leaf’s 100 MB book limit. Choose a smaller edition."
        case .file: return "The download is not a complete supported book. Try another edition."
        case .busy: return "Another book is being imported. Try again when it finishes."
        }
    }
}

// Safe to show/copy: never include response bodies, cookies, account details or URL queries.
struct ZLibraryRequestFailure: LocalizedError {
    let issue: ZLibraryError
    let diagnostic: String
    var errorDescription: String? { issue.errorDescription }
    static func issue(_ error: Error) -> ZLibraryError? {
        (error as? Self)?.issue ?? error as? ZLibraryError
    }
}

struct ZLibraryOrigin: Codable, Equatable {
    let url: URL
    init(_ address: String) throws {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              host.contains("."), !host.hasSuffix(".local"), host != "localhost", !host.contains(":"),
              parts.port == nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", !host.allSatisfy({ $0.isNumber || $0 == "." }),
              let url = URL(string: "https://\(host)") else { throw ZLibraryError.address }
        self.url = url
    }
    func contains(_ other: URL) -> Bool {
        other.scheme == "https" && other.host?.lowercased() == url.host && other.port == nil && other.user == nil && other.password == nil
    }
    static func fileURL(_ text: String, relativeTo origin: ZLibraryOrigin) throws -> URL {
        guard let url = URL(string: text, relativeTo: origin.url)?.absoluteURL,
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil,
              host != "localhost", !host.hasSuffix(".local"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else { throw ZLibraryError.response }
        return url
    }
}

struct ZLibraryWebsiteCookie: Codable, Equatable {
    let name: String
    let value: String
    let path: String
    let expires: Date?
    var valid: Bool {
        !name.isEmpty && name.count <= 256 && name.utf8.allSatisfy { (33...126).contains($0) && !"()<>@,;:\\\"/[]?={} ".utf8.contains($0) }
        && !["remix_userid", "remix_userkey"].contains(name)
        && value.count <= 4096 && value.utf8.allSatisfy { (33...126).contains($0) && !",;\"\\".utf8.contains($0) }
        && path.hasPrefix("/") && path.count <= 1024 && !path.contains("\r") && !path.contains("\n")
        && (expires.map { $0.timeIntervalSince1970.isFinite } ?? true)
    }
    func applies(to url: URL, now: Date = Date()) -> Bool {
        guard valid, expires.map({ $0 > now }) ?? true else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return requestPath == path || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")))
    }
}

struct ZLibrarySession: Codable, Equatable {
    let userID: String
    let userKey: String
    let websiteCookies: [ZLibraryWebsiteCookie]?
    let userAgent: String?
    init(userID: String, userKey: String, websiteCookies: [ZLibraryWebsiteCookie]? = nil, userAgent: String? = nil) {
        self.userID = userID; self.userKey = userKey; self.websiteCookies = websiteCookies; self.userAgent = userAgent
    }
    static func validUserAgent(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 1024 && text.utf8.allSatisfy { (32...126).contains($0) } }
    var valid: Bool {
        !userID.isEmpty && !userKey.isEmpty && userID.count < 256 && userKey.count < 4096
        && "\(userID)\(userKey)".unicodeScalars.allSatisfy { (33...126).contains(Int($0.value)) && !";,\"\\".unicodeScalars.contains($0) }
        && (websiteCookies?.count ?? 0) <= 64 && (websiteCookies?.allSatisfy(\.valid) ?? true)
        && (websiteCookies?.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) ?? 0) <= 16384
        && (userAgent.map(Self.validUserAgent) ?? true)
    }
    func cookieHeader(for url: URL) -> String {
        let context = (websiteCookies ?? []).filter { $0.applies(to: url) }.sorted { $0.path.count > $1.path.count }
        return (["remix_userid=\(userID)", "remix_userkey=\(userKey)"] + context.map { "\($0.name)=\($0.value)" }).joined(separator: "; ")
    }
}
struct ZLibraryProfile: Equatable {
    let name: String
    let remaining: Int?
}
struct ZLibraryBook: Identifiable, Equatable {
    let remoteID: String
    let hash: String
    let title: String
    let author: String
    let fileExtension: String
    let size: String
    let language: String
    let year: String
    let coverURL: URL?
    var rating: Double? = nil
    var ratingCount: Int? = nil
    var qualityScore: Double? = nil
    var fileSummary: String { [fileExtension.uppercased(), size.isEmpty ? "Size unavailable" : size].filter { !$0.isEmpty }.joined(separator: " · ") }
    var editionSummary: String { [language, year].filter { !$0.isEmpty }.joined(separator: " · ") }
    var ratingSummary: String {
        guard let rating else { return "No rating provided" }
        let value = rating.formatted(.number.precision(.fractionLength(0...1)))
        guard let count = ratingCount else { return "Rating \(value)" }
        return "\(value) · \(count.formatted()) \(count == 1 ? "rating" : "ratings")"
    }
    var id: String { "\(remoteID):\(hash)" }
    var sourceID: String { "zlibrary:\(id)" }
    var format: BookFormat? { BookFormat.detect(URL(fileURLWithPath: "book.\(fileExtension)")) }
    var placeholder: Book { Book(id: UUID(), title: title, author: author, fileName: "", format: format ?? .epub, fingerprint: hash) }
}

struct ZLibraryPayload {
    var data: Data
    var file: URL?
    var response: HTTPURLResponse
    // Cookies handed out by an access-check redirect on the way to this response.
    var challengeCookies: [HTTPCookie] = []
}
struct ZLibrarySearchPage {
    static let pageSize = 30
    static let maximumPages = 10
    let books: [ZLibraryBook]
    let hasMore: Bool
}
enum ZLibrarySearchOrder: String, CaseIterable, Identifiable {
    case popular, bestMatch = "bestmatch", recentlyAdded = "date", titleAscending = "titleA", titleDescending = "title", year, fileSizeDescending = "filesize", fileSizeAscending = "filesizeA"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .popular: return "Most popular"
        case .bestMatch: return "Best match"
        case .recentlyAdded: return "Recently added"
        case .titleAscending: return "Title (A–Z)"
        case .titleDescending: return "Title (Z–A)"
        case .year: return "Year"
        case .fileSizeDescending: return "File size ↓"
        case .fileSizeAscending: return "File size ↑"
        }
    }
}
protocol ZLibraryTransport {
    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload
}
protocol ZLibraryServing {
    func popular(origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> [ZLibraryBook]
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage
    func profile(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> ZLibraryProfile
    func details(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibraryBook
    func download(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

struct ZLibraryClient: ZLibraryServing {
    var transport: any ZLibraryTransport = ZLibraryHTTPTransport()
    func request(_ path: String, origin: ZLibraryOrigin, session: ZLibrarySession?) -> URLRequest {
        var request = URLRequest(url: origin.url.appendingPathComponent("eapi").appendingPathComponent(path))
        request.setValue(session?.valid == true ? session?.userAgent ?? "Leaf (iOS)" : "Leaf (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let session, session.valid {
            request.setValue(session.userID, forHTTPHeaderField: "remix-userid")
            request.setValue(session.userKey, forHTTPHeaderField: "remix-userkey")
            request.setValue(session.cookieHeader(for: request.url!), forHTTPHeaderField: "Cookie")
        }
        return request
    }
    func object(_ path: String, origin: ZLibraryOrigin, session: ZLibrarySession?, form: [String: String]? = nil) async throws -> [String: Any] {
        var request = request(path, origin: origin, session: session)
        if let form {
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        }
        let method = request.httpMethod ?? "GET"
        let original = request.url
        var visited = Set([request.url!]), count = 0
        while true {
            try Task.checkCancellation()
            let payload = try await transport.send(request, toFile: false, progress: { _ in })
            if (300...399).contains(payload.response.statusCode),
               (method == "GET" || [307, 308].contains(payload.response.statusCode)),
               let location = payload.response.value(forHTTPHeaderField: "Location"),
               let url = URL(string: location, relativeTo: request.url)?.absoluteURL {
                var next = request; next.url = url
                if let redirected = ZLibraryHTTPTransport.redirect(next, original: origin.url.appendingPathComponent("eapi/\(path)"), toFile: false, visited: visited, count: count) {
                    request = redirected
                    if let session, session.valid { request.setValue(session.cookieHeader(for: url), forHTTPHeaderField: "Cookie") }
                    visited.insert(url); count += 1
                    continue
                }
            }
            let redirect = (300...399).contains(payload.response.statusCode)
                ? Self.redirectDiagnostic(payload, request: request, original: original, visited: visited, count: count)
                : nil
            return try Self.decode(payload, path: path, method: method, redirect: redirect)
        }
    }
    // Only fixed categories leave this function. Location, queries, cookie values,
    // arbitrary server headers, and body text must never enter the diagnostic.
    private static func redirectDiagnostic(_ payload: ZLibraryPayload, request: URLRequest, original: URL?, visited: Set<URL>, count: Int) -> String {
        let location = payload.response.value(forHTTPHeaderField: "Location")
        let target = location.flatMap { URL(string: $0, relativeTo: request.url)?.absoluteURL }
        let reason: String
        let destination: String
        if location == nil {
            reason = "missing Location"; destination = "missing"
        } else if let target {
            var next = request; next.url = target
            if request.httpMethod != "GET", ![307, 308].contains(payload.response.statusCode) {
                reason = "method change refused"
            } else {
                reason = ZLibraryHTTPTransport.redirectRejection(next, original: original, toFile: false, visited: visited, count: count)?.rawValue ?? "unresolved"
            }
            if target == request.url { destination = "same URL" }
            else if target.scheme != "https" { destination = "non-HTTPS" }
            else if target.host == original?.host && target.port == original?.port {
                destination = target.path.hasPrefix("/eapi/") ? "same-origin API" : "same-origin website"
            } else { destination = "different origin" }
        } else {
            reason = "invalid Location"; destination = "invalid"
        }
        let update = payload.response.value(forHTTPHeaderField: "Set-Cookie") == nil ? "absent" : "present"
        let marker = accessCheckMarker(payload)
        return "Redirect target: \(destination) · reason: \(reason)\nRedirects followed: \(count)/3 · response cookie update: \(update) · access-check marker: \(marker)"
    }
    private static func accessCheckMarker(_ payload: ZLibraryPayload) -> String {
        let body = String(decoding: payload.data.prefix(4096), as: UTF8.self).lowercased()
        let cookie = payload.response.value(forHTTPHeaderField: "Set-Cookie")?.lowercased() ?? ""
        if body.contains("diamwall") || cookie.contains("__diamwall=") { return "DiamWall" }
        if body.contains("/cdn-cgi/challenge") || body.contains("__cf_chl") { return "Cloudflare" }
        return "not identified"
    }
    private static func decode(_ payload: ZLibraryPayload, path: String, method: String, redirect: String? = nil) throws -> [String: Any] {
        do { return try Self.decode(payload) }
        catch let issue as ZLibraryError {
            let status = payload.response.statusCode
            let kind: String
            if (300...399).contains(status) { kind = "redirect not followed" }
            else if payload.response.mimeType == "text/html" || String(decoding: payload.data.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { kind = "HTML instead of JSON" }
            else { kind = "JSON/API response" }
            let summary = "\(method) /eapi/\(path) · HTTP \(status) · \(kind)"
            throw ZLibraryRequestFailure(issue: issue == .challenge && accessCheckMarker(payload) != "not identified" ? .accessCheck : issue, diagnostic: summary + (redirect.map { "\n" + $0 } ?? ""))
        }
    }
    static func decode(_ payload: ZLibraryPayload) throws -> [String: Any] {
        let response = payload.response
        let text = String(data: payload.data.prefix(2048), encoding: .utf8)?.lowercased() ?? ""
        if (300...399).contains(response.statusCode) { throw ZLibraryError.challenge }
        guard let object = try? JSONSerialization.jsonObject(with: payload.data) as? [String: Any] else {
            if response.statusCode == 403 || response.statusCode == 517 || text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<") { throw ZLibraryError.challenge }
            throw ZLibraryError.response
        }
        if number(object["success"]) != 1 {
            let message = string(object["error"]).isEmpty ? string(object["message"]) : string(object["error"])
            let lower = message.lowercased()
            if response.statusCode == 401 || lower.contains("please login") || lower.contains("invalid credentials") || lower.contains("not logged") { throw ZLibraryError.signInRequired }
            throw message.isEmpty ? ZLibraryError.response : ZLibraryError.service(String(message.prefix(300)))
        }
        guard (200...299).contains(response.statusCode) else { throw ZLibraryError.response }
        return object
    }
    func popular(origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> [ZLibraryBook] {
        let object = try await object("book/most-popular", origin: origin, session: session)
        guard let rows = object["books"] as? [[String: Any]] else { throw ZLibraryError.response }
        return Self.books(rows, origin: origin, limit: 200)
    }
    func search(_ query: String, page: Int, order: ZLibrarySearchOrder = .popular, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibrarySearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500, (1...ZLibrarySearchPage.maximumPages).contains(page) else { throw ZLibraryError.query }
        let object = try await object("book/search", origin: origin, session: session,
                                      form: ["message": query, "page": String(page), "limit": String(ZLibrarySearchPage.pageSize), "order": order.rawValue])
        guard let rows = object["books"] as? [[String: Any]] else { throw ZLibraryError.response }
        let books = Self.books(rows, origin: origin, limit: ZLibrarySearchPage.pageSize)
        return ZLibrarySearchPage(books: books, hasMore: !books.isEmpty && rows.count >= ZLibrarySearchPage.pageSize)
    }
    private static func books(_ rows: [[String: Any]], origin: ZLibraryOrigin, limit: Int) -> [ZLibraryBook] {
        var seen = Set<String>()
        return rows.prefix(limit).compactMap { row in
            guard let book = Self.book(row, origin: origin), seen.insert(book.id).inserted else { return nil }
            return book
        }
    }
    static func book(_ row: [String: Any], origin: ZLibraryOrigin) -> ZLibraryBook? {
        let id = string(row["id"]), hash = string(row["hash"]), title = string(row["title"])
        func safeID(_ text: String) -> Bool { !text.isEmpty && text.count <= 128 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        guard safeID(id), safeID(hash), !title.isEmpty else { return nil }
        let cover = string(row["cover"])
        return ZLibraryBook(remoteID: id, hash: hash, title: String(title.prefix(500)), author: String(string(row["author"]).prefix(300)),
                            fileExtension: string(row["extension"]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), size: fileSize(row), language: string(row["language"]),
                            year: string(row["year"]), coverURL: cover.isEmpty ? nil : try? ZLibraryOrigin.fileURL(cover, relativeTo: origin),
                            rating: score(row["rating"]) ?? score(row["interestScore"]),
                            ratingCount: positiveInteger(row["ratingCount"]), qualityScore: score(row["qualityScore"]))
    }
    // EAPI clients use interestScore for the book rating, separately from qualityScore.
    // Preserve the provider's score without inventing a five-star scale or review count.
    private static func score(_ value: Any?) -> Double? {
        guard let text = scalar(value), text.count <= 32, let value = Double(text), value.isFinite, value > 0, value <= 10 else { return nil }
        return value
    }
    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let text = scalar(value), let number = Int(text), number > 0 else { return nil }
        return number
    }
    private static func scalar(_ value: Any?) -> String? {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (value as? NSNumber)?.stringValue
    }
    private static func fileSize(_ row: [String: Any]) -> String {
        if let text = row["filesizeString"] as? String {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count <= 40, text.range(of: #"^[0-9]+([.,][0-9]+)?\s*[KMGT]?i?B$"#, options: [.regularExpression, .caseInsensitive]) != nil,
               let amount = Double(text.prefix { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")), amount.isFinite, amount > 0 {
                return text
            }
        }
        guard let text = scalar(row["filesize"]), let bytes = Int64(text), bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    func profile(origin: ZLibraryOrigin, session: ZLibrarySession) async throws -> ZLibraryProfile {
        guard session.valid else { throw ZLibraryError.signInRequired }
        let object = try await object("user/profile", origin: origin, session: session)
        guard let user = object["user"] as? [String: Any], Self.string(user["id"]) == session.userID else { throw ZLibraryError.response }
        let used = Self.number(user["downloads_today"] ?? user["dailyDownloadsCount"]) ?? 0
        let limit = Self.number(user["downloads_limit"] ?? user["dailyDownloadLimit"])
        return ZLibraryProfile(name: Self.string(user["email"]).isEmpty ? Self.string(user["name"]) : Self.string(user["email"]), remaining: limit.map { max(0, $0 - used) })
    }
    func details(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession?) async throws -> ZLibraryBook {
        // Popular results are MinBook summaries: fetch only the selected edition, never the whole feed.
        let object = try await object("book/\(book.remoteID)/\(book.hash)", origin: origin, session: session)
        guard var row = object["book"] as? [String: Any] else { throw ZLibraryError.response }
        for (key, expected) in [("id", book.remoteID), ("hash", book.hash)] {
            let actual = Self.string(row[key])
            guard actual.isEmpty || actual == expected else { throw ZLibraryError.response }
            row[key] = expected
        }
        // Retain summary information when a detail response omits it.
        for (key, value) in [("title", book.title), ("author", book.author), ("cover", book.coverURL?.absoluteString ?? ""),
                             ("extension", book.fileExtension), ("filesizeString", book.size), ("language", book.language), ("year", book.year)] {
            if Self.string(row[key]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { row[key] = value }
        }
        guard var resolved = Self.book(row, origin: origin) else { throw ZLibraryError.response }
        guard !resolved.fileExtension.isEmpty else { throw ZLibraryError.metadata }
        resolved.rating = resolved.rating ?? book.rating
        resolved.ratingCount = resolved.ratingCount ?? book.ratingCount
        resolved.qualityScore = resolved.qualityScore ?? book.qualityScore
        return resolved
    }
    func download(_ book: ZLibraryBook, origin: ZLibraryOrigin, session: ZLibrarySession, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let book = book.fileExtension.isEmpty ? try await details(book, origin: origin, session: session) : book
        try Task.checkCancellation()
        guard let format = book.format else { throw ZLibraryError.file }
        let object = try await object("book/\(book.remoteID)/\(book.hash)/file", origin: origin, session: session)
        let nested = object["file"] as? [String: Any]
        let link = [nested?["downloadLink"], object["downloadLink"], object["url"], object["link"]].map(Self.string).first { !$0.isEmpty } ?? ""
        guard !link.isEmpty else { throw ZLibraryError.response }
        let url = try ZLibraryOrigin.fileURL(link, relativeTo: origin)
        // Signed CDN links receive no reusable account credential.
        var request = URLRequest(url: url)
        request.setValue("Leaf (iOS)", forHTTPHeaderField: "User-Agent")
        if origin.contains(url) {
            let headers = self.request("", origin: origin, session: session).allHTTPHeaderFields ?? [:]
            for (key, value) in headers where key.lowercased() != "accept" { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue(session.cookieHeader(for: url), forHTTPHeaderField: "Cookie")
        }
        let payload = try await transport.send(request, toFile: true, progress: progress)
        guard let temp = payload.file else { throw ZLibraryError.file }
        do {
            try Task.checkCancellation()
            guard (200...299).contains(payload.response.statusCode) else { throw ZLibraryError.challenge }
            try Self.validateFile(temp, format: format)
            let destination = temp.deletingPathExtension().appendingPathExtension(format.rawValue)
            try FileManager.default.moveItem(at: temp, to: destination)
            return destination
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
    static func validateFile(_ url: URL, format: BookFormat) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        guard !prefix.isEmpty else { throw ZLibraryError.file }
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || text.hasPrefix("{\"success\"") { throw ZLibraryError.challenge }
        if format == .pdf && !prefix.starts(with: Data("%PDF-".utf8)) { throw ZLibraryError.file }
        if [.epub, .fbz, .cbz].contains(format) && !prefix.starts(with: [0x50,0x4b,0x03,0x04]) { throw ZLibraryError.file }
    }
    static func string(_ value: Any?) -> String { if let value = value as? String { return value }; if let value = value as? NSNumber { return value.stringValue }; return "" }
    static func number(_ value: Any?) -> Int? { Int(string(value)) }
}

struct ZLibraryHTTPTransport: ZLibraryTransport {
    enum RedirectRejection: String {
        case hopLimit = "redirect limit reached"
        case invalidURL = "invalid URL"
        case insecure = "HTTPS required"
        case credentials = "credentials in target"
        case port = "explicit port refused"
        case sameURL = "same URL refused"
        case loop = "redirect loop"
        case differentOrigin = "different API origin refused"
        case outsideAPI = "outside API refused"
    }
    var configuration: URLSessionConfiguration = .ephemeral
    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        try await ZLibraryTransfer(configuration: configuration).run(request, toFile: toFile, progress: progress)
    }
    static func redirect(_ request: URLRequest, original: URL?, toFile: Bool, visited: Set<URL> = [], count: Int = 0) -> URLRequest? {
        guard redirectRejection(request, original: original, toFile: toFile, visited: visited, count: count) == nil,
              let url = request.url else { return nil }
        var result = request
        let sameOrigin = original?.scheme == url.scheme && original?.host == url.host && original?.port == url.port
        if !sameOrigin {
            for name in ["Cookie", "Authorization", "remix-userid", "remix-userkey"] { result.setValue(nil, forHTTPHeaderField:name) }
        }
        return result
    }
    static func redirectRejection(_ request: URLRequest, original: URL?, toFile: Bool, visited: Set<URL> = [], count: Int = 0) -> RedirectRejection? {
        guard count < 3 else { return .hopLimit }
        guard let url = request.url, url.host != nil else { return .invalidURL }
        guard url.scheme == "https" else { return .insecure }
        guard url.user == nil, url.password == nil else { return .credentials }
        guard url.port == nil else { return .port }
        guard url != original else { return .sameURL }
        guard !visited.contains(url) else { return .loop }
        let sameOrigin = original?.scheme == url.scheme && original?.host == url.host && original?.port == url.port
        // Keep the existing policy unchanged while explaining each rejected case.
        if !toFile {
            guard sameOrigin else { return .differentOrigin }
            guard original?.path.hasPrefix("/eapi/") == true, url.path.hasPrefix("/eapi/") else { return .outsideAPI }
        }
        return nil
    }
}

// One transfer owns one bounded response and a serial delegate queue. No complete book Data is created.
private final class ZLibraryTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ZLibraryPayload, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var response: HTTPURLResponse?
    private var data = Data()
    private var file: URL?
    private var handle: FileHandle?
    private var bytes: Int64 = 0
    private var limit: Int64 = 2 * 1024 * 1024
    private var originalURL: URL?
    private var visited = Set<URL>()
    private var redirectCount = 0
    private var challengeCookies: [HTTPCookie] = []
    private var toFile = false
    private var progress: (@Sendable (Double?) -> Void)?
    init(configuration: URLSessionConfiguration) { self.configuration = configuration; super.init() }
    func run(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation; self.toFile = toFile; self.originalURL = request.url; self.progress = progress
                if let url = request.url { visited.insert(url) }
                limit = toFile ? 100 * 1024 * 1024 : 2 * 1024 * 1024
                do {
                    if toFile {
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("LeafDownload-\(UUID()).part")
                        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw ZLibraryError.file }
                        self.file = file; handle = try FileHandle(forWritingTo: file)
                    }
                    let config = configuration.copy() as! URLSessionConfiguration
                    config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
                    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 300
                    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    self.session = session; let task = session.dataTask(with: request); self.task = task
                    lock.unlock(); task.resume()
                } catch { lock.unlock(); finish(.failure(error)) }
            }
        }, onCancel: { [self] in
            lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
        })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // JSON redirects are handled by the client so path-scoped cookies are rebuilt
        // for each URL. The transport never silently changes an API request's target.
        if toFile, challengeCookies.isEmpty, redirectCount < 3, let url = request.url, url == response.url,
           let cookies = Self.challengeCookies(response, for: url), !cookies.isEmpty {
            // A redirect back to the same URL that only hands out cookies is the provider's
            // access check, not a loop. Repeat the download once with those cookies, as a
            // browser would; the session never stores them itself.
            var next = request
            next.setValue(Self.cookieHeader(request.value(forHTTPHeaderField: "Cookie"), adding: cookies), forHTTPHeaderField: "Cookie")
            challengeCookies = cookies; redirectCount += 1
            completionHandler(next); return
        }
        let next = toFile ? ZLibraryHTTPTransport.redirect(request,original:originalURL,toFile:true,visited:visited,count:redirectCount) : nil
        if let url = next?.url { visited.insert(url); redirectCount += 1 }
        completionHandler(next)
    }
    private static func challengeCookies(_ response: HTTPURLResponse, for url: URL) -> [HTTPCookie]? {
        guard let host = url.host?.lowercased(), let fields = response.allHeaderFields as? [String: String] else { return nil }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == domain || host.hasSuffix("." + domain)
        }
    }
    private static func cookieHeader(_ existing: String?, adding cookies: [HTTPCookie]) -> String {
        var pairs: [(String, String)] = (existing ?? "").split(separator: ";").compactMap { item in
            let text = item.trimmingCharacters(in: .whitespaces)
            guard let equals = text.firstIndex(of: "=") else { return nil }
            return (String(text[..<equals]), String(text[text.index(after: equals)...]))
        }
        for cookie in cookies {
            pairs.removeAll { $0.0 == cookie.name }
            pairs.append((cookie.name, cookie.value))
        }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(ZLibraryError.response)); return }
        self.response = response
        if response.expectedContentLength > limit { completionHandler(.cancel); finish(.failure(toFile ? ZLibraryError.size : ZLibraryError.response)); return }
        if toFile && (!(200...299).contains(response.statusCode) || response.mimeType == "text/html" || response.mimeType == "application/json") { completionHandler(.cancel); finish(.failure(ZLibraryError.challenge)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes += Int64(data.count)
        guard bytes <= limit else { dataTask.cancel(); finish(.failure(toFile ? ZLibraryError.size : ZLibraryError.response)); return }
        do {
            if let handle { try handle.write(contentsOf: data) } else { self.data.append(data) }
            let expected = response?.expectedContentLength ?? -1
            progress?(expected > 0 ? min(1, Double(bytes) / Double(expected)) : nil)
        } catch { dataTask.cancel(); finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success(ZLibraryPayload(data: data, file: file, response: response, challengeCookies: challengeCookies))) }
        else { finish(.failure(ZLibraryError.response)) }
    }
    private func finish(_ result: Result<ZLibraryPayload, Error>) {
        lock.lock(); guard let continuation else { lock.unlock(); return }; self.continuation = nil; lock.unlock()
        try? handle?.close(); handle = nil
        if case .failure = result, let file { try? FileManager.default.removeItem(at: file) }
        session?.invalidateAndCancel(); session = nil; task = nil; progress = nil
        continuation.resume(with: result)
    }
}
