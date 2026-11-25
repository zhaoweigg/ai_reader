import Foundation

/// The public lists Discover added in 1.47: 豆瓣, Project Gutenberg, Apple Books,
/// prize winners and Open Library. Each is read without an account.
enum BookListSource: String, CaseIterable, Codable, Identifiable {
    case douban, gutenberg, apple, prizes, openLibrary = "openlibrary"
    var id: String { rawValue }
    var title: String { DiscoverList(self).title }
    var fullName: String {
        switch self {
        case .douban: return "豆瓣读书"
        case .gutenberg: return "Project Gutenberg"
        case .apple: return "Apple Books"
        case .prizes: return "Prize winners"
        case .openLibrary: return "Open Library"
        }
    }
    var charts: [BookListChart] { BookListChart.allCases.filter { $0.source == self } }
}

/// One list from a source. The raw value is the cache's and the setting's name for it.
enum BookListChart: String, CaseIterable, Codable, Identifiable {
    case doubanTop250 = "douban-top250", doubanLatest = "douban-latest"
    case gutenbergPopular = "gutenberg-popular"
    case appleTopPaid = "apple-top-paid", appleTopFree = "apple-top-free"
    case booker, internationalBooker = "international-booker", pulitzer, nationalBook = "national-book", hugo, nebula, maoDun = "mao-dun"
    case openLibraryDaily = "openlibrary-daily", openLibraryWeekly = "openlibrary-weekly", openLibraryMonthly = "openlibrary-monthly"
    var id: String { rawValue }
    var source: BookListSource {
        switch self {
        case .doubanTop250, .doubanLatest: return .douban
        case .gutenbergPopular: return .gutenberg
        case .appleTopPaid, .appleTopFree: return .apple
        case .booker, .internationalBooker, .pulitzer, .nationalBook, .hugo, .nebula, .maoDun: return .prizes
        case .openLibraryDaily, .openLibraryWeekly, .openLibraryMonthly: return .openLibrary
        }
    }
    var title: String {
        switch self {
        case .doubanTop250: return "豆瓣读书 Top 250"
        case .doubanLatest: return "新书速递"
        case .gutenbergPopular: return "Most downloaded"
        case .appleTopPaid: return "Top paid"
        case .appleTopFree: return "Top free"
        case .booker: return "Booker Prize"
        case .internationalBooker: return "International Booker Prize"
        case .pulitzer: return "Pulitzer Prize for Fiction"
        case .nationalBook: return "National Book Award for Fiction"
        case .hugo: return "Hugo Award for Best Novel"
        case .nebula: return "Nebula Award for Best Novel"
        case .maoDun: return "茅盾文学奖"
        case .openLibraryDaily: return "Trending today"
        case .openLibraryWeekly: return "Trending this week"
        case .openLibraryMonthly: return "Trending this month"
        }
    }
    /// Short enough for a segment on a narrow phone.
    var shortTitle: String {
        switch self {
        case .doubanTop250: return "Top 250"
        case .doubanLatest: return "新书速递"
        case .gutenbergPopular: return "Popular"
        case .appleTopPaid: return "Top paid"
        case .appleTopFree: return "Top free"
        case .booker: return "Booker"
        case .internationalBooker: return "International Booker"
        case .pulitzer: return "Pulitzer"
        case .nationalBook: return "National Book Award"
        case .hugo: return "Hugo"
        case .nebula: return "Nebula"
        case .maoDun: return "茅盾"
        case .openLibraryDaily: return "Today"
        case .openLibraryWeekly: return "This week"
        case .openLibraryMonthly: return "This month"
        }
    }
    /// What the list ranks, for Ask Leaf and the footnote.
    var meaning: String {
        switch self {
        case .doubanTop250: return "豆瓣读书's 250 highest-rated books"
        case .doubanLatest: return "new books 豆瓣读书 readers are rating"
        case .gutenbergPopular: return "Project Gutenberg's most downloaded free books"
        case .appleTopPaid: return "Apple Books' best-selling paid books"
        case .appleTopFree: return "Apple Books' most downloaded free books"
        case .openLibraryDaily, .openLibraryWeekly, .openLibraryMonthly: return "books Open Library readers are looking at most"
        default: return "the prize's winners, newest first"
        }
    }
    /// Prize lists are carried in the app; they change once a year.
    var isBundled: Bool { source == .prizes }
}

/// The Apple Books stores Leaf offers. Apple publishes no chart for the China store.
enum BookListCountry: String, CaseIterable, Codable, Identifiable {
    case us, gb, ca, au, jp, tw, hk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .us: return "United States"
        case .gb: return "United Kingdom"
        case .ca: return "Canada"
        case .au: return "Australia"
        case .jp: return "Japan"
        case .tw: return "Taiwan"
        case .hk: return "Hong Kong"
        }
    }
}

/// One list as the reader chose it; only Apple's charts depend on the country.
struct BookListSelection: Hashable, Codable {
    var chart: BookListChart
    var country: BookListCountry
    var source: BookListSource { chart.source }
    init(chart: BookListChart, country: BookListCountry = .us) {
        self.chart = chart
        self.country = chart.source == .apple ? country : .us
    }
    var caption: String { source == .apple ? "\(chart.title) · \(country.title)" : chart.title }
    /// The list's own page, for the reader to open.
    var pageURL: URL {
        switch chart {
        case .doubanTop250: return URL(string: "https://book.douban.com/top250")!
        case .doubanLatest: return URL(string: "https://book.douban.com/latest")!
        case .gutenbergPopular: return URL(string: "https://www.gutenberg.org/ebooks/search/?sort_order=downloads")!
        case .appleTopPaid, .appleTopFree: return URL(string: "https://books.apple.com/\(country.rawValue)/charts")!
        case .openLibraryDaily: return URL(string: "https://openlibrary.org/trending/daily")!
        case .openLibraryWeekly: return URL(string: "https://openlibrary.org/trending/weekly")!
        case .openLibraryMonthly: return URL(string: "https://openlibrary.org/trending/monthly")!
        case .booker: return URL(string: "https://en.wikipedia.org/wiki/Booker_Prize")!
        case .internationalBooker: return URL(string: "https://en.wikipedia.org/wiki/International_Booker_Prize")!
        case .pulitzer: return URL(string: "https://en.wikipedia.org/wiki/Pulitzer_Prize_for_Fiction")!
        case .nationalBook: return URL(string: "https://en.wikipedia.org/wiki/National_Book_Award_for_Fiction")!
        case .hugo: return URL(string: "https://en.wikipedia.org/wiki/Hugo_Award_for_Best_Novel")!
        case .nebula: return URL(string: "https://en.wikipedia.org/wiki/Nebula_Award_for_Best_Novel")!
        case .maoDun: return URL(string: "https://zh.wikipedia.org/wiki/%E8%8C%85%E7%9B%BE%E6%96%87%E5%AD%A6%E5%A5%96")!
        }
    }
    /// The page or data Leaf reads for the books after the first `offset`.
    func requestURL(offset: Int) -> URL? {
        switch chart {
        case .doubanTop250: return URL(string: "https://book.douban.com/top250?start=\(offset)")
        case .doubanLatest: return URL(string: "https://book.douban.com/latest?subcat=%E5%85%A8%E9%83%A8&p=\(offset / DoubanLists.latestPageSize + 1)")
        case .gutenbergPopular: return URL(string: "https://gutendex.com/books/?sort=popular&page=\(offset / GutenbergList.pageSize + 1)")
        case .appleTopPaid: return URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country.rawValue)/books/top-paid/\(AppleBooksList.size)/books.json")
        case .appleTopFree: return URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country.rawValue)/books/top-free/\(AppleBooksList.size)/books.json")
        case .openLibraryDaily: return URL(string: "https://openlibrary.org/trending/daily.json?limit=\(OpenLibraryList.size)")
        case .openLibraryWeekly: return URL(string: "https://openlibrary.org/trending/weekly.json?limit=\(OpenLibraryList.size)")
        case .openLibraryMonthly: return URL(string: "https://openlibrary.org/trending/monthly.json?limit=\(OpenLibraryList.size)")
        default: return nil
        }
    }
}

/// A book on one of these lists.
struct ListedBook: Codable, Equatable, Identifiable {
    /// Renumbered when a page is added, so a book the source skipped leaves no gap.
    var rank: Int
    /// The source's own number or key for the book.
    let bookID: String
    let title: String
    let author: String
    var source: BookListSource
    /// Publisher, date, language: the source's own wording.
    var detail: String = ""
    /// What the list counts: "9.7 · 471,956 ratings", "208,430 downloads", "Winner 2024".
    var figure: String = ""
    /// 豆瓣 Top 250's one-line description of the book.
    var quote: String = ""
    var summary: String = ""
    var cover: URL? = nil
    var link: URL? = nil
    var isbns: [String] = []
    /// Project Gutenberg's free EPUB.
    var epub: URL? = nil
    /// 豆瓣's score out of 10 and how many readers gave it.
    var rating: Double? = nil
    var ratingCount: Int? = nil
    /// The year a prize winner won, shown in place of a rank.
    var year: Int? = nil
    var id: String { source.rawValue + ":" + bookID }
    var byline: String { [author, detail].filter { !$0.isEmpty }.joined(separator: " · ") }
    /// The catalog source Leaf records for a Gutenberg book added from this list.
    var gutenbergSource: String? { epub == nil ? nil : "gutenberg:" + bookID }
    /// Chinese books are matched and reviewed the way the 中文 charts are.
    var isChinese: Bool { source == .douban || ReaderChatMessage.usesChinese(title + author) }
}

struct BookList: Codable, Equatable {
    let selection: BookListSelection
    /// The source's date for the list, such as Apple's update time; often empty.
    let published: String
    let fetchedAt: Date
    let books: [ListedBook]
    /// Where the next page starts in the source's own count, when it has one.
    var next: Int? = nil
    var hasMore: Bool { next != nil }
}

enum BookListFeedError: LocalizedError, Equatable {
    case unavailable, invalidResponse, rateLimited, maintenance, noChart
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The list could not be loaded. Try again."
        case .invalidResponse: return "The site returned an unfamiliar page. A list loaded earlier has been kept."
        case .rateLimited: return "The site is limiting requests. Try again later."
        case .maintenance: return "The site is down for maintenance. Try again later."
        case .noChart: return "Apple publishes no such chart for this store. Try Top free or another store."
        }
    }
}

protocol BookListServing {
    /// The list from its first book, or the books that follow the first `offset`.
    func list(_ selection: BookListSelection, offset: Int) async throws -> BookList
    /// A Project Gutenberg book's EPUB as a local file.
    func download(_ book: ListedBook) async throws -> URL
}

/// Reads one public list page. No account, no cookies kept.
struct BookListClient: BookListServing {
    var session: URLSession = URLSession(configuration: .ephemeral)
    static let userAgent = "LeafReader/1.47 (book discovery)"

    func list(_ selection: BookListSelection, offset: Int) async throws -> BookList {
        if selection.chart.isBundled { return PrizeWinners.list(selection) }
        guard let url = selection.requestURL(offset: offset) else { throw BookListFeedError.unavailable }
        let data = try await Self.get(url, session: session, accept: selection.source == .douban ? "text/html" : "application/json")
        switch selection.chart {
        case .doubanTop250: return try DoubanLists.parseTop250(data, selection: selection, offset: offset)
        case .doubanLatest: return try DoubanLists.parseLatest(data, selection: selection, offset: offset)
        case .gutenbergPopular: return try GutenbergList.parse(data, selection: selection, offset: offset)
        case .appleTopPaid, .appleTopFree: return try AppleBooksList.parse(data, selection: selection)
        case .openLibraryDaily, .openLibraryWeekly, .openLibraryMonthly: return try OpenLibraryList.parse(data, selection: selection)
        default: throw BookListFeedError.unavailable
        }
    }
    static func get(_ url: URL, session: URLSession, accept: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BookListFeedError.invalidResponse }
        // 豆瓣 sends a visitor it doubts to a check page instead of the list.
        if let host = response.url?.host, host.hasPrefix("sec.") { throw BookListFeedError.rateLimited }
        switch response.statusCode {
        case 200: break
        case 403, 418, 429: throw BookListFeedError.rateLimited
        case 503: throw BookListFeedError.maintenance
        default: throw BookListFeedError.unavailable
        }
        guard !data.isEmpty, data.count <= 5_000_000 else { throw BookListFeedError.invalidResponse }
        return data
    }
}

/// Small helpers for reading list pages.
enum ListText {
    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
    static func first(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }
    /// Text without tags or entities, on one line.
    static func plain(_ html: String, limit: Int = 400) -> String {
        var value = html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&#039;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&middot;", "·"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(value.trimmingCharacters(in: .whitespaces).prefix(limit))
    }
    /// An https address on one of the given hosts, or nothing.
    static func address(_ value: Any?, hosts: [String]) -> URL? {
        guard let text = value as? String, text.utf8.count <= 600, let url = URL(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
    static func count(_ value: Int) -> String { value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) }
}

/// 豆瓣读书's Top 250 (25 a page) and 新书速递 (20 a page) pages.
enum DoubanLists {
    static let top250PageSize = 25, latestPageSize = 20, latestLimit = 100
    private static let hosts = ["doubanio.com", "douban.com"]

    static func parseTop250(_ data: Data, selection: BookListSelection, offset: Int, now: Date = Date()) throws -> BookList {
        guard let html = String(data: data, encoding: .utf8) else { throw BookListFeedError.invalidResponse }
        let rows = html.components(separatedBy: #"<tr class="item">"#).dropFirst()
        guard !rows.isEmpty, rows.count <= top250PageSize else { throw BookListFeedError.invalidResponse }
        let books = try rows.enumerated().map { index, row -> ListedBook in
            let row = String(row.prefix(8000))
            guard let id = ListText.first(#"book\.douban\.com/subject/(\d{1,12})/"#, in: row),
                  let title = ListText.first(#"<div class="pl2">\s*<a [^>]*title="([^"]{1,300})""#, in: row).map({ ListText.plain($0, limit: 200) }),
                  !title.isEmpty else { throw BookListFeedError.invalidResponse }
            let facts = ListText.plain(ListText.first(#"<p class="pl">([\s\S]*?)</p>"#, in: row) ?? "", limit: 300)
            let parts = facts.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let score = ListText.first(#"rating_nums">\s*([0-9.]{1,4})\s*<"#, in: row).flatMap(Double.init)
            let votes = ListText.first(#"(\d{1,9})人评价"#, in: row).flatMap(Int.init)
            return ListedBook(rank: offset + index + 1, bookID: id, title: title, author: parts.first ?? "", source: .douban,
                              detail: details(parts.dropFirst()), figure: figure(score, votes),
                              quote: ListText.plain(ListText.first(#"<span class="inq">([\s\S]*?)</span>"#, in: row) ?? "", limit: 120),
                              cover: ListText.address(ListText.first(#"<img src="([^"]+)""#, in: row), hosts: hosts),
                              link: URL(string: "https://book.douban.com/subject/\(id)/"), rating: score, ratingCount: votes)
        }
        guard Set(books.map(\.bookID)).count == books.count else { throw BookListFeedError.invalidResponse }
        let next = offset + books.count
        return BookList(selection: selection, published: "", fetchedAt: now, books: books, next: books.count == top250PageSize && next < 250 ? next : nil)
    }

    static func parseLatest(_ data: Data, selection: BookListSelection, offset: Int, now: Date = Date()) throws -> BookList {
        guard let html = String(data: data, encoding: .utf8) else { throw BookListFeedError.invalidResponse }
        let rows = html.components(separatedBy: #"<li class="media clearfix">"#).dropFirst()
        guard !rows.isEmpty, rows.count <= latestPageSize else { throw BookListFeedError.invalidResponse }
        let books = try rows.enumerated().map { index, row -> ListedBook in
            let row = String(row.prefix(8000))
            guard let id = ListText.first(#"book\.douban\.com/subject/(\d{1,12})/"#, in: row),
                  let title = ListText.first(#"<h2[^>]*>\s*<a [^>]*>([\s\S]{1,300}?)</a>"#, in: row).map({ ListText.plain($0, limit: 200) }),
                  !title.isEmpty else { throw BookListFeedError.invalidResponse }
            let facts = ListText.plain(ListText.first(#"subject-abstract[^"]*">([\s\S]*?)</p>"#, in: row) ?? "", limit: 300)
            let parts = facts.components(separatedBy: " / ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let score = ListText.first(#"font-small fleft">\s*([0-9.]{1,4})\s*<"#, in: row).flatMap(Double.init)
            let votes = ListText.first(#"\((\d{1,9})人评价\)"#, in: row).flatMap(Int.init)
            return ListedBook(rank: offset + index + 1, bookID: id, title: title, author: parts.first ?? "", source: .douban,
                              detail: details(parts.dropFirst()), figure: figure(score, votes),
                              cover: ListText.address(ListText.first(#"<img [^>]*src="([^"]+)""#, in: row), hosts: hosts),
                              link: URL(string: "https://book.douban.com/subject/\(id)/"), rating: score, ratingCount: votes)
        }
        guard Set(books.map(\.bookID)).count == books.count else { throw BookListFeedError.invalidResponse }
        let page = offset / latestPageSize + 1
        let more = html.contains("p=\(page + 1)&") || html.contains("p=\(page + 1)\"")
        // A page can hold fewer than twenty; the next one is still the next twenty places.
        let next = page * latestPageSize
        return BookList(selection: selection, published: "", fetchedAt: now, books: books, next: more && next < latestLimit ? next : nil)
    }
    /// Publisher and date; the price, binding and translators stay on 豆瓣. Top 250 lists
    /// "translator / publisher / date / price" after the author, 新书速递 "date / publisher / price".
    private static func details(_ parts: ArraySlice<String>) -> String {
        let facts = Array(parts)
        func price(_ text: String) -> Bool {
            text.range(of: #"^[0-9.]+\s*元?$"#, options: .regularExpression) != nil
                || ["USD", "CNY", "NT$", "HK$", "JPY", "EUR", "GBP", "$", "¥"].contains { text.hasPrefix($0) }
        }
        if let date = facts.firstIndex(where: { $0.range(of: #"^\d{4}(-\d{1,2}){0,2}$"#, options: .regularExpression) != nil }) {
            // 新书速递 puts the publisher after the date; Top 250 puts it before and the price after.
            if date + 1 < facts.count, !price(facts[date + 1]) { return facts[date] + " · " + facts[date + 1] }
            if date > 0 { return facts[date - 1] + " · " + facts[date] }
            return facts[date]
        }
        let kept = parts.filter { part in
            !(part.hasSuffix("元") || part.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil
              || ["平装", "精装", "简装", "盒装"].contains(part) || part.hasSuffix("译") || part.hasPrefix("USD") || part.hasPrefix("CNY"))
        }
        return kept.prefix(2).joined(separator: " · ")
    }
    private static func figure(_ score: Double?, _ votes: Int?) -> String {
        guard let score, score > 0 else { return votes.map { "\(ListText.count($0))人评价" } ?? "" }
        return [String(format: "%.1f", score), votes.map { "\(ListText.count($0))人评价" }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Project Gutenberg's most downloaded books, through Gutendex's catalog data (32 a page).
enum GutenbergList {
    static let pageSize = 32, limit = 160

    static func parse(_ data: Data, selection: BookListSelection, offset: Int, now: Date = Date()) throws -> BookList {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["results"] as? [[String: Any]], !rows.isEmpty, rows.count <= pageSize else { throw BookListFeedError.invalidResponse }
        var rank = offset
        let books = rows.compactMap { row -> ListedBook? in
            guard let number = row["id"] as? Int, number > 0, let rawTitle = row["title"] as? String else { return nil }
            let formats = row["formats"] as? [String: Any] ?? [:]
            // Only books with an EPUB can be added; a dictionary or a sound file cannot be read here.
            guard (row["media_type"] as? String ?? "Text") == "Text",
                  let epub = ListText.address(formats["application/epub+zip"], hosts: ["gutenberg.org"]) else { return nil }
            let people = (row["authors"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.map(name)
            let summary = (row["summaries"] as? [String])?.first.map {
                $0.replacingOccurrences(of: "(This is an automatically generated summary.)", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            let languages = (row["languages"] as? [String] ?? []).prefix(3).map { Locale(identifier: "en").localizedString(forLanguageCode: $0) ?? $0 }
            let downloads = row["download_count"] as? Int
            rank += 1
            return ListedBook(rank: rank, bookID: String(number), title: String(rawTitle.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(200)),
                              author: people.prefix(3).joined(separator: ", "), source: .gutenberg,
                              detail: languages.joined(separator: ", "),
                              figure: downloads.map { "\(ListText.count($0)) downloads this month" } ?? "",
                              summary: String(summary.prefix(3000)),
                              cover: ListText.address(formats["image/jpeg"], hosts: ["gutenberg.org"]),
                              link: URL(string: "https://www.gutenberg.org/ebooks/\(number)"), epub: epub)
        }
        guard !books.isEmpty, Set(books.map(\.bookID)).count == books.count else { throw BookListFeedError.invalidResponse }
        let next = offset + rows.count
        return BookList(selection: selection, published: "", fetchedAt: now, books: books, next: root["next"] is String && next < limit ? next : nil)
    }
    /// "Austen, Jane" → "Jane Austen"; "Smollett, T. (Tobias)" → "Tobias Smollett".
    static func name(_ value: String) -> String {
        let parts = value.components(separatedBy: ", ")
        guard parts.count == 2 else { return value.trimmingCharacters(in: .whitespaces) }
        var given = parts[1].trimmingCharacters(in: .whitespaces)
        // Gutenberg spells out initials in brackets.
        if let full = ListText.first(#"\(([^()]+)\)"#, in: given) { given = full.trimmingCharacters(in: .whitespaces) }
        return given + " " + parts[0].trimmingCharacters(in: .whitespaces)
    }
}

/// Apple's public Top Paid and Top Free book charts for one store.
enum AppleBooksList {
    static let size = 50

    static func parse(_ data: Data, selection: BookListSelection, now: Date = Date()) throws -> BookList {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let feed = root["feed"] as? [String: Any],
              (feed["country"] as? String)?.lowercased() == selection.country.rawValue else { throw BookListFeedError.invalidResponse }
        // Taiwan's and Hong Kong's stores publish an empty Top paid chart.
        let rows = feed["results"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else { throw BookListFeedError.noChart }
        guard rows.count <= 200 else { throw BookListFeedError.invalidResponse }
        let books = try rows.enumerated().map { index, row -> ListedBook in
            guard let id = row["id"] as? String, !id.isEmpty, id.allSatisfy(\.isNumber), let title = row["name"] as? String, !title.isEmpty
            else { throw BookListFeedError.invalidResponse }
            let genre = (row["genres"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.first { $0 != "Books" } ?? ""
            let year = (row["releaseDate"] as? String).map { String($0.prefix(4)) } ?? ""
            return ListedBook(rank: index + 1, bookID: id, title: String(title.prefix(200)), author: String((row["artistName"] as? String ?? "").prefix(200)),
                              source: .apple, detail: [genre, year].filter { !$0.isEmpty }.joined(separator: " · "),
                              cover: ListText.address((row["artworkUrl100"] as? String).map(artwork), hosts: ["mzstatic.com"]),
                              link: ListText.address(row["url"], hosts: ["apple.com"]))
        }
        guard Set(books.map(\.bookID)).count == books.count else { throw BookListFeedError.invalidResponse }
        var published = ""
        if let updated = feed["updated"] as? String, let date = DateFormatter.rfc1123.date(from: updated) {
            published = "Updated " + date.formatted(date: .abbreviated, time: .omitted)
        }
        return BookList(selection: selection, published: published, fetchedAt: now, books: books)
    }
    /// The chart's 100-point artwork asked for at three times the size.
    static func artwork(_ url: String) -> String {
        guard let match = ListText.matches(#"/(\d{2,4})x(\d{2,4})bb\.(png|jpg)$"#, in: url).first, let width = Int(match[1]), let height = Int(match[2]) else { return url }
        return url.replacingOccurrences(of: match[0], with: "/\(width * 3)x\(height * 3)bb.\(match[3])")
    }
}

private extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}

/// Open Library's trending works for a day, a week or a month.
enum OpenLibraryList {
    static let size = 50

    static func parse(_ data: Data, selection: BookListSelection, now: Date = Date()) throws -> BookList {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rows = root["works"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= 200 else { throw BookListFeedError.invalidResponse }
        var seen: Set<String> = []
        let books = rows.compactMap { row -> ListedBook? in
            guard let key = row["key"] as? String, key.hasPrefix("/works/"), let title = row["title"] as? String, !title.isEmpty else { return nil }
            let id = String(key.dropFirst("/works/".count))
            guard id.count <= 20, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), seen.insert(id).inserted else { return nil }
            let editions = ((row["editions"] as? [String: Any])?["docs"] as? [[String: Any]]) ?? []
            let isbn = editions.compactMap { ($0["availability"] as? [String: Any])?["isbn"] as? String }.first
            let year = (row["first_publish_year"] as? Int).map { "First published \($0)" } ?? ""
            let count = (row["edition_count"] as? Int).map { "\(ListText.count($0)) editions" } ?? ""
            return ListedBook(rank: seen.count, bookID: id, title: String(title.prefix(200)),
                              author: ((row["author_name"] as? [String]) ?? []).prefix(3).joined(separator: ", "), source: .openLibrary,
                              detail: year, figure: count,
                              cover: (row["cover_i"] as? Int).flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg") },
                              link: URL(string: "https://openlibrary.org/works/\(id)"), isbns: isbn.map { [$0] } ?? [])
        }
        guard !books.isEmpty else { throw BookListFeedError.invalidResponse }
        return BookList(selection: selection, published: "", fetchedAt: now, books: books)
    }
}
