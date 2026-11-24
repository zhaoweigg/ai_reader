import Foundation

// Ratings and reviews for a book on a Discover page, gathered from the open sites that
// have them: Open Library (ratings), 豆瓣读书 (score and short reviews), 微信读书 (its
// recommendation rate), The New York Times (critics' reviews, with the reader's own key)
// and Z-Library's own score. Each is looked up once when a book page opens.

/// The sites a book's ratings and reviews come from.
enum BookReviewSite: String, Codable, CaseIterable, Hashable {
    case openLibrary, douban, weread, zlibrary, nyt
    var title: String {
        switch self {
        case .openLibrary: return "Open Library"
        case .douban: return "豆瓣读书"
        case .weread: return "微信读书"
        case .zlibrary: return "Z-Library"
        case .nyt: return "The New York Times"
        }
    }
}

/// One site's score for a book, worded as the site shows it.
struct BookRating: Codable, Hashable {
    let site: BookReviewSite
    /// The score as the site gives it: "4.5", "8.9" or "93.0%".
    let score: String
    /// The score on a five-star scale, where the site's scale converts.
    var stars: Double? = nil
    /// "202 ratings", "519,564 ratings", "recommended by 296,101 readers".
    let count: String
    /// A site's own verdict, such as 微信读书's 神作.
    var verdict: String? = nil
    /// Each star's share from five down to one, when the site publishes it.
    var distribution: [Double]? = nil
    var notes: [String] = []
    var url: URL? = nil
}

/// A reader's short review, without their name.
struct ReaderReview: Codable, Hashable {
    /// One to five, when the reader gave stars.
    let stars: Int?
    let text: String
    /// How many readers marked it useful.
    let helpful: Int?
}

/// A critic's review: where it ran and a link to read it there.
struct CriticReview: Codable, Hashable {
    let outlet: String
    let byline: String
    /// "2021-05-04" as the outlet gives it.
    let published: String
    let summary: String
    let url: URL
}

/// What the sites said about one book, as of `fetchedAt`.
struct BookReviews: Codable, Equatable {
    var ratings: [BookRating] = []
    var readerReviews: [ReaderReview] = []
    /// Where the reader reviews come from and where all of them can be read.
    var readerReviewsSite: BookReviewSite? = nil
    var readerReviewsURL: URL? = nil
    var critics: [CriticReview] = []
    /// Sites that did not answer this time, kept apart from sites with no entry for the book.
    var unavailable: [BookReviewSite] = []
    var fetchedAt: Date
    var isEmpty: Bool { ratings.isEmpty && readerReviews.isEmpty && critics.isEmpty }
}

/// What a book page knows about the book whose reviews are wanted.
struct BookReviewQuery: Hashable {
    var title: String
    var author: String
    var isbns: [String] = []
    /// A score the list or catalog already carried: 微信读书's or Z-Library's.
    var listed: BookRating? = nil

    init(title: String, author: String, isbns: [String] = [], listed: BookRating? = nil) {
        self.title = title; self.author = author
        var seen: Set<String> = []
        self.isbns = isbns.compactMap(BestsellerText.canonicalISBN).filter { seen.insert($0).inserted }
        self.listed = listed
    }
    /// One cache entry per book, whichever page or edition it was opened from.
    var key: String {
        if let isbn = isbns.first { return "isbn:" + isbn }
        let title = WebNovelText.title(self.title), author = WebNovelText.author(self.author)
        return "work:" + (title.isEmpty ? BestsellerText.title(self.title) : title) + "|" + (author.isEmpty ? BestsellerText.normalized(self.author) : author)
    }
    /// A Chinese title or author: 豆瓣 by title and 微信读书 are asked, Open Library is not.
    var isChinese: Bool { ReaderChatMessage.usesChinese(title + author) }
}

extension BookReviewQuery {
    init(_ book: ZLibraryBook) {
        var listed: BookRating?
        if let rating = book.rating {
            let value = rating.formatted(.number.precision(.fractionLength(0...1)))
            let count = book.ratingCount.map { "\($0.formatted()) \($0 == 1 ? "rating" : "ratings")" } ?? "catalog score"
            let quality = book.qualityScore.map { ["File quality \($0.formatted(.number.precision(.fractionLength(0...1))))"] } ?? []
            listed = BookRating(site: .zlibrary, score: value, count: count, notes: quality)
        }
        self.init(title: book.title, author: book.author, isbns: book.isbns ?? [], listed: listed)
    }
    init(_ book: BestsellerBook) { self.init(title: book.title, author: book.author, isbns: book.isbns) }
    init(_ novel: WebNovel) { self.init(title: novel.title, author: novel.author, listed: novel.wereadRating) }
}

extension WebNovel {
    /// 微信读书's own recommendation rate, carried with its chart rows.
    var wereadRating: BookRating? {
        guard source == .weread, let rating = ratingPermille, let count = ratingCount else { return nil }
        return WeReadRatings.rating(permille: rating, count: count, verdict: ratingTitle, url: link)
    }
}

enum BookReviewError: LocalizedError, Equatable {
    case unavailable, invalidResponse, blocked
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The site did not answer."
        case .invalidResponse: return "The site answered in an unfamiliar way."
        case .blocked: return "The site asked for a check Leaf does not pass."
        }
    }
}

private enum BookReviewPart: Sendable {
    case nothing, rating(BookRating?), douban(DoubanBook?), critics([CriticReview]), failed(BookReviewSite)
}

protocol BookReviewServing: Sendable {
    /// Every site's part for one book. A site that fails is listed in `unavailable`; the rest still count.
    func reviews(_ query: BookReviewQuery, nytKey: String?) async -> BookReviews
}

struct BookReviewClient: BookReviewServing {
    var session: URLSession = URLSession(configuration: .ephemeral)
    static let userAgent = "LeafReader/1.45 (book discovery)"

    func reviews(_ query: BookReviewQuery, nytKey: String?) async -> BookReviews {
        let key = nytKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let client = self
        let parts = await withTaskGroup(of: BookReviewPart.self) { group -> [BookReviewPart] in
            if !query.isChinese, !query.isbns.isEmpty || !query.title.isEmpty {
                group.addTask { await Self.attempt(.openLibrary) { .rating(try await client.openLibrary(query)) } }
            }
            // 豆瓣 is asked by ISBN for any book, and by title only for Chinese ones.
            if !query.isbns.isEmpty || query.isChinese {
                group.addTask { await Self.attempt(.douban) { .douban(try await client.douban(query)) } }
            }
            if query.isChinese, query.listed?.site != .weread {
                group.addTask { await Self.attempt(.weread) { .rating(try await client.weread(query)) } }
            }
            if !key.isEmpty, !query.isbns.isEmpty, !query.isChinese {
                group.addTask { await Self.attempt(.nyt) { .critics(try await client.nyt(query, key: key)) } }
            }
            var parts: [BookReviewPart] = []
            for await part in group { parts.append(part) }
            return parts
        }
        var result = BookReviews(fetchedAt: Date())
        if let listed = query.listed { result.ratings.append(listed) }
        for part in parts {
            switch part {
            case .nothing: break
            case .rating(let rating): if let rating, rating.site != query.listed?.site { result.ratings.append(rating) }
            case .douban(let book):
                guard let book else { continue }
                if let rating = book.rating { result.ratings.append(rating) }
                result.readerReviews = Array(book.reviews.prefix(3))
                if !result.readerReviews.isEmpty { result.readerReviewsSite = .douban; result.readerReviewsURL = book.reviewsURL }
            case .critics(let critics): result.critics = critics
            case .failed(let site): result.unavailable.append(site)
            }
        }
        // The list's own score first, then the larger communities.
        let order: [BookReviewSite] = [.weread, .zlibrary, .douban, .openLibrary]
        func place(_ rating: BookRating) -> Int { rating.site == query.listed?.site ? -1 : (order.firstIndex(of: rating.site) ?? order.count) }
        result.ratings.sort { place($0) < place($1) }
        result.unavailable.sort { $0.rawValue < $1.rawValue }
        return result
    }
    private static func attempt(_ site: BookReviewSite, _ work: () async throws -> BookReviewPart) async -> BookReviewPart {
        do { return try await work() }
        catch { return Task.isCancelled ? .nothing : .failed(site) }
    }

    // MARK: Open Library: one search request carries the ratings and reading counts.
    func openLibrary(_ query: BookReviewQuery) async throws -> BookRating? {
        var url = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "fields", value: OpenLibraryRatings.fields), URLQueryItem(name: "limit", value: "5")]
        if let isbn = query.isbns.first { items.append(URLQueryItem(name: "isbn", value: isbn)) }
        else {
            items.append(URLQueryItem(name: "title", value: String(query.title.prefix(200))))
            items.append(URLQueryItem(name: "author", value: String(query.author.prefix(100))))
        }
        url.queryItems = items
        return try OpenLibraryRatings.parse(try await get(url.url!), query: query)
    }

    // MARK: 豆瓣读书: the book's page, found by ISBN or through the site's title suggestions.
    func douban(_ query: BookReviewQuery) async throws -> DoubanBook? {
        for isbn in query.isbns.prefix(2) {
            let (data, address) = try await page(URL(string: "https://book.douban.com/isbn/\(isbn)/")!, missingIsNil: true)
            guard let data, let address, DoubanBooks.subjectID(address) != nil else { continue }
            return try DoubanBooks.parse(data, address: address)
        }
        guard query.isChinese, !query.title.isEmpty else { return nil }
        var suggest = URLComponents(string: "https://book.douban.com/j/subject_suggest")!
        suggest.queryItems = [URLQueryItem(name: "q", value: String(query.title.prefix(100)))]
        guard let id = try DoubanBooks.match(try await get(suggest.url!, accept: "application/json"), query: query) else { return nil }
        let (data, address) = try await page(URL(string: "https://book.douban.com/subject/\(id)/")!, missingIsNil: false)
        guard let data, let address else { return nil }
        return try DoubanBooks.parse(data, address: address)
    }

    // MARK: 微信读书: its search lists each book's recommendation rate.
    func weread(_ query: BookReviewQuery) async throws -> BookRating? {
        var url = URLComponents(string: "https://weread.qq.com/web/search/global")!
        url.queryItems = [URLQueryItem(name: "keyword", value: String(query.title.prefix(100)))]
        return try WeReadRatings.parse(try await get(url.url!, accept: "application/json"), query: query)
    }

    // MARK: The New York Times: its reviews of the book, with the reader's own API key.
    func nyt(_ query: BookReviewQuery, key: String) async throws -> [CriticReview] {
        var url = URLComponents(string: "https://api.nytimes.com/svc/books/v3/reviews.json")!
        url.queryItems = [URLQueryItem(name: "isbn", value: query.isbns[0]), URLQueryItem(name: "api-key", value: key)]
        return try NYTReviews.parse(try await get(url.url!, accept: "application/json"))
    }

    private func get(_ url: URL, accept: String = "application/json") async throws -> Data {
        let (data, _) = try await page(url, accept: accept, missingIsNil: false)
        guard let data else { throw BookReviewError.unavailable }
        return data
    }
    /// The body and the address it finally came from; nothing for a 404 when that means "no entry".
    private func page(_ url: URL, accept: String = "text/html", missingIsNil: Bool) async throws -> (Data?, URL?) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BookReviewError.invalidResponse }
        // 豆瓣 sends a visitor it doubts to a check page instead of the book.
        if let host = response.url?.host, host.hasPrefix("sec.") { throw BookReviewError.blocked }
        switch response.statusCode {
        case 200: break
        case 404 where missingIsNil: return (nil, nil)
        case 403, 418: throw BookReviewError.blocked
        default: throw BookReviewError.unavailable
        }
        guard !data.isEmpty, data.count <= 3_000_000 else { throw BookReviewError.invalidResponse }
        return (data, response.url)
    }
}

enum OpenLibraryRatings {
    static let fields = "key,title,author_name,ratings_average,ratings_count,ratings_count_1,ratings_count_2,ratings_count_3,ratings_count_4,ratings_count_5,want_to_read_count,already_read_count"
    /// The first work that is this book and has ratings. A title search must match the
    /// title and an author; an ISBN search is the book.
    static func parse(_ data: Data, query: BookReviewQuery) throws -> BookRating? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let docs = root["docs"] as? [[String: Any]]
        else { throw BookReviewError.invalidResponse }
        let byISBN = !query.isbns.isEmpty, author = BestsellerText.normalized(query.author)
        for doc in docs.prefix(5) {
            guard let average = number(doc["ratings_average"]), (1...5).contains(average),
                  let count = number(doc["ratings_count"]).map(Int.init), count > 0 else { continue }
            if !byISBN {
                let authors = (doc["author_name"] as? [String] ?? []).map(BestsellerText.normalized)
                guard BestsellerText.compatibleTitles(doc["title"] as? String ?? "", query.title),
                      !author.isEmpty, authors.contains(where: { $0 == author || $0.contains(author) || author.contains($0) && !$0.isEmpty })
                else { continue }
            }
            let stars = (1...5).reversed().map { number(doc["ratings_count_\($0)"]) ?? 0 }
            let total = stars.reduce(0, +)
            var notes: [String] = []
            if let want = number(doc["want_to_read_count"]).map(Int.init), want > 0 { notes.append("\(want.formatted()) want to read") }
            if let read = number(doc["already_read_count"]).map(Int.init), read > 0 { notes.append("\(read.formatted()) have read") }
            let key = doc["key"] as? String ?? ""
            return BookRating(site: .openLibrary, score: average.formatted(.number.precision(.fractionLength(1))), stars: average,
                              count: "\(count.formatted()) \(count == 1 ? "rating" : "ratings")",
                              distribution: total > 0 ? stars.map { $0 / total } : nil, notes: notes,
                              url: key.hasPrefix("/works/") && key.dropFirst(7).allSatisfy({ $0.isLetter || $0.isNumber }) ? URL(string: "https://openlibrary.org" + key) : nil)
        }
        return nil
    }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

/// A 豆瓣读书 book page: its score, how the stars split and its most useful short reviews.
struct DoubanBook: Equatable {
    let rating: BookRating?
    let reviews: [ReaderReview]
    let reviewsURL: URL
}

enum DoubanBooks {
    static func subjectID(_ address: URL) -> String? {
        guard address.host == "book.douban.com" else { return nil }
        let parts = address.pathComponents
        guard parts.count >= 3, parts[1] == "subject", !parts[2].isEmpty, parts[2].allSatisfy(\.isNumber) else { return nil }
        return parts[2]
    }
    /// The book among the site's title suggestions with the same title and author.
    static func match(_ data: Data, query: BookReviewQuery) throws -> String? {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw BookReviewError.invalidResponse }
        let title = WebNovelText.title(query.title), main = WebNovelText.title(query.title, mainOnly: true), author = WebNovelText.author(query.author)
        guard !title.isEmpty, !author.isEmpty else { return nil }
        let books = rows.prefix(10).compactMap { row -> (id: String, title: String, main: String, author: String)? in
            guard row["type"] as? String == "b", let id = row["id"] as? String, !id.isEmpty, id.allSatisfy(\.isNumber),
                  let name = row["title"] as? String else { return nil }
            return (id, WebNovelText.title(name), WebNovelText.title(name, mainOnly: true), WebNovelText.author(row["author_name"] as? String ?? ""))
        }.filter { !$0.author.isEmpty && ($0.author.contains(author) || author.contains($0.author)) }
        // The same title first; then a printed edition such as "诡秘之主 1" or "（全18册）".
        return (books.first { $0.title == title } ?? books.first { $0.main == main } ?? books.first { $0.title.hasPrefix(title) && $0.title.dropFirst(title.count).allSatisfy(\.isNumber) })?.id
    }
    static func parse(_ data: Data, address: URL) throws -> DoubanBook {
        guard let id = subjectID(address), let html = String(data: data, encoding: .utf8), html.contains("v:itemreviewed") else { throw BookReviewError.invalidResponse }
        let page = URL(string: "https://book.douban.com/subject/\(id)/")!
        var rating: BookRating?
        // A book with too few ratings shows no score; its reviews still count.
        if let raw = first(#"<strong[^>]*property="v:average"[^>]*>\s*([0-9.]+)\s*<"#, html), let score = Double(raw), (1...10).contains(score),
           let votes = first(#"property="v:votes"[^>]*>\s*(\d+)\s*<"#, html).flatMap(Int.init), votes > 0 {
            let shares = all(#"class="rating_per"[^>]*>\s*([0-9.]+)%"#, html).compactMap(Double.init).map { $0 / 100 }
            rating = BookRating(site: .douban, score: score.formatted(.number.precision(.fractionLength(1))), stars: score / 2,
                                count: "\(votes.formatted()) \(votes == 1 ? "rating" : "ratings")",
                                distribution: shares.count == 5 ? shares : nil, url: page)
        }
        let reviews = all(#"(?s)<li class="comment-item.*?</li>"#, html).prefix(5).compactMap { item -> ReaderReview? in
            guard let raw = first(#"(?s)<span class="short">(.*?)</span>"#, item) else { return nil }
            let text = BestsellerText.plain(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let stars = first(#"allstar(\d)0"#, item).flatMap(Int.init).flatMap { (1...5).contains($0) ? $0 : nil }
            return ReaderReview(stars: stars, text: String(text.prefix(400)), helpful: first(#"class="vote-count"[^>]*>(\d+)<"#, item).flatMap(Int.init))
        }.sorted { ($0.helpful ?? 0) > ($1.helpful ?? 0) }
        return DoubanBook(rating: rating, reviews: reviews, reviewsURL: page.appendingPathComponent("comments/"))
    }
    private static func first(_ pattern: String, _ text: String) -> String? { all(pattern, text).first }
    private static func all(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let index = match.numberOfRanges > 1 ? 1 : 0
            return Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

enum WeReadRatings {
    /// 微信读书 rates a book by the share of readers who recommend it, in thousandths.
    static func rating(permille: Int, count: Int, verdict: String?, url: URL?) -> BookRating? {
        guard (1...1000).contains(permille), count > 0 else { return nil }
        let verdict = verdict?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BookRating(site: .weread, score: String(format: "%.1f%%", Double(permille) / 10),
                          count: "recommended · \(count.formatted()) \(count == 1 ? "rating" : "ratings")",
                          verdict: verdict?.isEmpty == false ? verdict : nil, url: url)
    }
    /// The search result that is this book, with the same title and author.
    static func parse(_ data: Data, query: BookReviewQuery) throws -> BookRating? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rows = root["books"] as? [[String: Any]]
        else { throw BookReviewError.invalidResponse }
        let title = WebNovelText.title(query.title), author = WebNovelText.author(query.author)
        guard !title.isEmpty, !author.isEmpty else { return nil }
        for row in rows.prefix(10) {
            guard let info = row["bookInfo"] as? [String: Any], WebNovelText.title(info["title"] as? String ?? "") == title else { continue }
            let credit = WebNovelText.author(info["author"] as? String ?? "")
            guard !credit.isEmpty, credit.contains(author) || author.contains(credit),
                  let rating = info["newRating"] as? Int, let count = info["newRatingCount"] as? Int else { continue }
            let link = (info["deepLink"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.host == "weread.qq.com" ? $0 : nil }
            return Self.rating(permille: rating, count: count, verdict: (info["newRatingDetail"] as? [String: Any])?["title"] as? String, url: link)
        }
        return nil
    }
}

enum NYTReviews {
    static func parse(_ data: Data) throws -> [CriticReview] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["status"] as? String == "OK",
              let rows = root["results"] as? [[String: Any]] else { throw BookReviewError.invalidResponse }
        var seen: Set<URL> = []
        return rows.prefix(3).compactMap { row -> CriticReview? in
            guard let text = row["url"] as? String, let url = URL(string: text), url.scheme == "https",
                  let host = url.host, host == "nytimes.com" || host.hasSuffix(".nytimes.com"), seen.insert(url).inserted else { return nil }
            func value(_ key: String, _ limit: Int) -> String { String((row[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)) }
            return CriticReview(outlet: BookReviewSite.nyt.title, byline: value("byline", 120), published: value("publication_dt", 20),
                                summary: value("summary", 600), url: url)
        }
    }
}
