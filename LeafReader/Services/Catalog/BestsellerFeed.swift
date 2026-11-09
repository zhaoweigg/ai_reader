import Foundation

enum BestsellerSource: String, CaseIterable, Codable, Identifiable {
    case indie, nyt
    var id: String { rawValue }
    var title: String { self == .indie ? "Indie" : "New York Times" }
    var attribution: String { self == .indie ? "Indie Bestsellers · American Booksellers Association" : "The New York Times Best Sellers" }
}

enum BestsellerGenre: String, CaseIterable, Codable, Identifiable {
    case fiction, nonfiction
    var id: String { rawValue }
    var title: String { self == .fiction ? "Fiction" : "Nonfiction" }
    var listName: String { "hardcover-" + rawValue }
    var caption: String { "Hardcover " + title }
}

struct BestsellerList: Codable, Equatable {
    let source: BestsellerSource
    let genre: BestsellerGenre
    let published: String
    let fetchedAt: Date
    let books: [BestsellerBook]
    let relayURL: URL?
    var id: String { source.rawValue + ":" + genre.rawValue }
    init(source: BestsellerSource, genre: BestsellerGenre, published: String, fetchedAt: Date, books: [BestsellerBook], relayURL: URL? = nil) {
        self.source = source; self.genre = genre; self.published = published
        self.fetchedAt = fetchedAt; self.books = books; self.relayURL = relayURL
    }
}

struct BestsellerBook: Codable, Equatable, Identifiable {
    let source: BestsellerSource
    let genre: BestsellerGenre
    let rank: Int
    let title: String
    let author: String
    let summary: String
    let isbns: [String]
    let sourceURL: URL
    var id: String { "\(source.rawValue):\(genre.rawValue):\(rank):\(workID)" }
    var workID: String { BestsellerText.title(title) + "|" + BestsellerText.normalized(author) }
    // Publisher artwork is independent of the list provider and contains no account data.
    var coverURL: URL? { isbns.compactMap(BestsellerText.isbn).first.flatMap { URL(string: "https://images.penguinrandomhouse.com/cover/\($0)?width=300") } }
}

enum BestsellerFeedError: LocalizedError, Equatable {
    case nytKeyRejected, unavailable, invalidResponse, rateLimited
    var errorDescription: String? {
        switch self {
        case .nytKeyRejected: return "NYT Books did not accept this API key. Check your connection and try again."
        case .unavailable: return "The bestseller list could not be loaded. Try again."
        case .invalidResponse: return "The provider returned an unfamiliar list format. Your previously loaded list has been kept."
        case .rateLimited: return "The provider’s request limit has been reached. Try again later."
        }
    }
}

protocol BestsellerServing {
    func lists(source: BestsellerSource, apiKey: String?) async throws -> [BestsellerList]
}

enum BestsellerText {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func title(_ text: String) -> String {
        let base = text.components(separatedBy: ":").first ?? text
        return normalized(base.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression))
    }
    static func compatibleTitles(_ lhs: String, _ rhs: String) -> Bool {
        let base = title(lhs)
        guard !base.isEmpty, base == title(rhs) else { return false }
        let a = normalized(lhs.components(separatedBy: ":").dropFirst().joined(separator: ":"))
        let b = normalized(rhs.components(separatedBy: ":").dropFirst().joined(separator: ":"))
        // Providers sometimes omit a subtitle. Two different supplied subtitles
        // can name different volumes, so a shared prefix cannot identify them.
        return a.isEmpty || b.isEmpty || a == b
    }
    static func isbn(_ input: String) -> String? {
        let s = input.uppercased().filter { $0.isASCII && ($0.isNumber || $0 == "X") }
        let chars = Array(s)
        if chars.count == 13, chars.allSatisfy(\.isNumber) {
            let sum = chars.enumerated().reduce(0) { $0 + $1.element.wholeNumberValue! * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
            return sum.isMultiple(of: 10) ? s : nil
        }
        if chars.count == 10, chars.prefix(9).allSatisfy(\.isNumber), chars.last!.isNumber || chars.last == "X" {
            let sum = chars.enumerated().reduce(0) { $0 + ($1.element == "X" ? 10 : $1.element.wholeNumberValue!) * (10 - $1.offset) }
            return sum.isMultiple(of: 11) ? s : nil
        }
        return nil
    }
    static func canonicalISBN(_ input: String) -> String? {
        guard let value = isbn(input) else { return nil }
        guard value.count == 10 else { return value }
        let base = "978" + value.prefix(9)
        let sum = base.enumerated().reduce(0) { $0 + $1.element.wholeNumberValue! * ($1.offset.isMultiple(of: 2) ? 1 : 3) }
        return base + String((10 - sum % 10) % 10)
    }
    static func plain(_ html: String) -> String {
        var s = String(html.prefix(12_000)).replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        let entities = ["&amp;":"&", "&quot;":"\"", "&apos;":"'", "&#039;":"'", "&nbsp;":" ", "&lt;":"<", "&gt;":">", "&rsquo;":"’", "&lsquo;":"‘", "&ldquo;":"“", "&rdquo;":"”", "&mdash;":"—", "&ndash;":"–"]
        for (key, value) in entities { s = s.replacingOccurrences(of: key, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let range = Range(match.range(at: 1), in: s), let entire = Range(match.range, in: s) else { continue }
                let raw = String(s[range]), value = raw.first == "x" ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let value, let scalar = UnicodeScalar(value) { s.replaceSubrange(entire, with: String(scalar)) }
            }
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BestsellerFeedClient: BestsellerServing {
    var session: URLSession = URLSession(configuration: .ephemeral)
    func lists(source: BestsellerSource, apiKey: String?) async throws -> [BestsellerList] {
        if source == .indie {
            let data = try await request(URL(string: "https://www.indiebound.org/bestseller-list-v2")!)
            return try Self.indie(data)
        }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try await withThrowingTaskGroup(of: BestsellerList.self) { group in
            for genre in BestsellerGenre.allCases {
                group.addTask {
                    if key.isEmpty {
                        return try Self.publicNYT(try await request(Self.publicNYTURL(genre)), genre: genre)
                    }
                    var url = URLComponents(string: "https://api.nytimes.com/svc/books/v3/lists/current/\(genre.listName).json")!
                    url.queryItems = [URLQueryItem(name: "api-key", value: key)]
                    return try Self.nyt(try await request(url.url!, nytAPI: true), genre: genre)
                }
            }
            var result: [BestsellerList] = []
            for try await list in group { result.append(list) }
            return result.sorted { $0.genre.rawValue < $1.genre.rawValue }
        }
    }
    private func request(_ url: URL, nytAPI: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("LeafReader/1.35 (book discovery)", forHTTPHeaderField: "User-Agent")
        request.setValue(nytAPI ? "application/json" : "text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BestsellerFeedError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw nytAPI ? BestsellerFeedError.nytKeyRejected : BestsellerFeedError.unavailable
        case 429: throw BestsellerFeedError.rateLimited
        default: throw BestsellerFeedError.unavailable
        }
        guard !data.isEmpty, data.count <= 3_000_000 else { throw BestsellerFeedError.invalidResponse }
        return data
    }
    static func publicNYTURL(_ genre: BestsellerGenre) -> URL {
        URL(string: "https://www.teambook.club/nyt-bestsellers/\(genre.listName)")!
    }
    // Read the public page's schema.org Book list, never executable Next.js state
    // or its private API. Reject changed, partial, miscategorized or stale charts.
    static func publicNYT(_ data: Data, genre: BestsellerGenre, now: Date = Date()) throws -> BestsellerList {
        guard data.count <= 3_000_000, let html = String(data: data, encoding: .utf8),
              let published = captures(#"Week of ([A-Za-z]+ \d{1,2}, \d{4})"#, html).first else { throw BestsellerFeedError.invalidResponse }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMMM d, yyyy"; formatter.isLenient = false
        guard let date = formatter.date(from: published), formatter.string(from: date) == published,
              (-14 * 86_400...28 * 86_400).contains(now.timeIntervalSince(date)) else { throw BestsellerFeedError.invalidResponse }
        let scripts = captures(#"(?is)<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#, html)
        for script in scripts {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(script.utf8))) as? [String: Any],
                  object["@type"] as? String == "CollectionPage", object["url"] as? String == publicNYTURL(genre).absoluteString,
                  let list = object["mainEntity"] as? [String: Any], list["@type"] as? String == "ItemList",
                  list["name"] as? String == genre.caption, list["numberOfItems"] as? Int == 15,
                  let rows = list["itemListElement"] as? [[String: Any]], rows.count == 15 else { continue }
            let books = try rows.map { row -> BestsellerBook in
                guard row["@type"] as? String == "ListItem", let rank = row["position"] as? Int,
                      let item = row["item"] as? [String: Any], item["@type"] as? String == "Book",
                      let title = item["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let author = item["author"] as? [String: Any], let name = author["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let rawISBN = item["isbn"] as? String, let isbn = BestsellerText.isbn(rawISBN) else { throw BestsellerFeedError.invalidResponse }
                return BestsellerBook(source: .nyt, genre: genre, rank: rank, title: String(title.prefix(1000)), author: String(name.prefix(500)),
                                      summary: String((item["description"] as? String ?? "").prefix(3000)), isbns: [isbn],
                                      sourceURL: URL(string: "https://www.nytimes.com/books/best-sellers/\(genre.listName)/")!)
            }
            let result = try validated(source: .nyt, genre: genre, published: published, books: books, now: now)
            return BestsellerList(source: result.source, genre: genre, published: result.published, fetchedAt: now, books: result.books, relayURL: publicNYTURL(genre))
        }
        throw BestsellerFeedError.invalidResponse
    }
    static func nyt(_ data: Data, genre: BestsellerGenre, now: Date = Date()) throws -> BestsellerList {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["status"] as? String == "OK",
              let results = object["results"] as? [String: Any], let rows = results["books"] as? [[String: Any]],
              let published = results["published_date"] as? String, !published.isEmpty else { throw BestsellerFeedError.invalidResponse }
        let books = rows.prefix(30).compactMap { row -> BestsellerBook? in
            guard let rank = row["rank"] as? Int, (1...30).contains(rank), let title = row["title"] as? String,
                  let author = row["author"] as? String, !title.isEmpty, !author.isEmpty else { return nil }
            let raw = [row["primary_isbn13"] as? String, row["primary_isbn10"] as? String].compactMap { $0 }
                + ((row["isbns"] as? [[String: Any]]) ?? []).flatMap { [$0["isbn13"] as? String, $0["isbn10"] as? String].compactMap { $0 } }
            var seen: Set<String> = []
            let isbns = raw.compactMap(BestsellerText.isbn).filter { seen.insert($0).inserted }
            return BestsellerBook(source: .nyt, genre: genre, rank: rank, title: String(title.prefix(1000)), author: String(author.prefix(500)),
                                  summary: String((row["description"] as? String ?? "").prefix(3000)), isbns: isbns,
                                  sourceURL: URL(string: "https://www.nytimes.com/books/best-sellers/\(genre.listName)/")!)
        }
        return try validated(source: .nyt, genre: genre, published: published, books: books, now: now)
    }
    static func indie(_ data: Data, now: Date = Date()) throws -> [BestsellerList] {
        guard data.count <= 3_000_000, let html = String(data: data, encoding: .utf8) else { throw BestsellerFeedError.invalidResponse }
        let published = captures(#"(?is)National\s+Bestsellers for\s*(?:<time\b[^>]*>)?([^<]+)"#, html).first.map(BestsellerText.plain)
        guard let published, !published.isEmpty else { throw BestsellerFeedError.invalidResponse }
        let tables = captures(#"(?is)<table\b[^>]*>(.*?)</table>"#, html)
        return try BestsellerGenre.allCases.map { genre in
            guard let table = tables.first(where: { captures(#"(?is)<caption\b[^>]*>(.*?)</caption>"#, $0).first.map(BestsellerText.plain) == genre.caption }) else { throw BestsellerFeedError.invalidResponse }
            let books = captures(#"(?is)<tr\b[^>]*>(.*?)</tr>"#, table).prefix(31).compactMap { row -> BestsellerBook? in
                let cells = captures(#"(?is)<td\b[^>]*>(.*?)</td>"#, row)
                guard cells.count >= 2, let rank = Int(BestsellerText.plain(cells[0])), (1...30).contains(rank) else { return nil }
                let cell = cells[1]
                guard let rawISBN = captures(#"/(?:buy-local|book)/([0-9Xx-]{10,17})"#, cell).first,
                      let isbn = BestsellerText.isbn(rawISBN), let rawTitle = captures(#"(?is)<a\b[^>]*>(.*?)</a>"#, cell).first else { return nil }
                let title = BestsellerText.plain(rawTitle), parts = cell.components(separatedBy: try! NSRegularExpression(pattern: #"(?i)<br\s*/?>"#))
                guard parts.count >= 2 else { return nil }
                let author = indieAuthor(BestsellerText.plain(parts[1]))
                guard !title.isEmpty, !author.isEmpty else { return nil }
                return BestsellerBook(source: .indie, genre: genre, rank: rank, title: String(title.prefix(1000)), author: String(author.prefix(500)),
                                      summary: String(BestsellerText.plain(parts.dropFirst(2).joined(separator: " ")).prefix(3000)), isbns: [isbn],
                                      sourceURL: URL(string: "https://www.indiebound.org/book/\(isbn)")!)
            }
            return try validated(source: .indie, genre: genre, published: published, books: books, now: now)
        }
    }
    private static func indieAuthor(_ byline: String) -> String {
        let fields = byline.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let price = fields.firstIndex(where: { $0.hasPrefix("$") }) else { return fields.first ?? "" }
        let credits = fields.prefix(price).joined(separator: ", ")
        // IndieBound flattens author and publisher into one comma-delimited
        // line. These publisher names also contain commas; remove the full
        // imprint before preserving coauthors, translators and name suffixes.
        let imprints = ["Little, Brown and Company", "Little, Brown Books for Young Readers", "Little, Brown",
                        "Farrar, Straus and Giroux", "Farrar, Straus & Giroux", "Harcourt, Brace and Company"]
        if let imprint = imprints.first(where: { credits.hasSuffix(", " + $0) }) {
            return String(credits.dropLast(imprint.count + 2))
        }
        return fields.prefix(price).dropLast().joined(separator: ", ")
    }
    private static func validated(source: BestsellerSource, genre: BestsellerGenre, published: String, books: [BestsellerBook], now: Date) throws -> BestsellerList {
        let sorted = books.sorted { $0.rank < $1.rank }
        // A changed page is a parse failure, never a successful empty or truncated chart.
        guard sorted.count == 15, Set(sorted.map(\.rank)).count == sorted.count,
              sorted.enumerated().allSatisfy({ $0.offset + 1 == $0.element.rank }) else { throw BestsellerFeedError.invalidResponse }
        return BestsellerList(source: source, genre: genre, published: String(published.prefix(120)), fetchedAt: now, books: sorted)
    }
    private static func captures(_ pattern: String, _ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range(at: 1), in: value).map { String(value[$0]) }
        }
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var result: [String] = [], start = startIndex
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let range = Range(match.range, in: self) else { continue }
            result.append(String(self[start..<range.lowerBound])); start = range.upperBound
        }
        result.append(String(self[start...])); return result
    }
}
