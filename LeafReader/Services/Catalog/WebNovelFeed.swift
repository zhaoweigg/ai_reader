import Foundation

/// The 起点中文网 charts Leaf shows. The raw value is the chart's path on the site.
enum WebNovelChart: String, CaseIterable, Codable, Identifiable {
    case tickets = "yuepiao", sales = "hotsales", reading = "readindex", recommended = "rec"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tickets: return "月票榜"
        case .sales: return "畅销榜"
        case .reading: return "阅读指数榜"
        case .recommended: return "推荐票榜"
        }
    }
    /// A label short enough for four segments on a narrow phone.
    var shortTitle: String { self == .reading ? "阅读指数" : String(title.dropLast()) }
    var meaning: String {
        switch self {
        case .tickets: return "monthly reader votes"
        case .sales: return "sales"
        case .reading: return "reading index"
        case .recommended: return "recommendation votes"
        }
    }
    /// Only the recommendation chart is published for a week, a month and all time.
    var hasPeriods: Bool { self == .recommended }
}

enum WebNovelPeriod: Int, CaseIterable, Codable, Identifiable {
    case week = 3, month = 2, allTime = 1
    var id: Int { rawValue }
    var title: String { self == .week ? "周榜" : self == .month ? "月榜" : "总榜" }
    /// The name Ask Leaf's tool uses.
    var key: String { self == .week ? "week" : self == .month ? "month" : "all_time" }
}

struct WebNovelCategory: Hashable, Identifiable {
    let id: Int
    let title: String
    static let everything = WebNovelCategory(id: -1, title: "全站")
    static let all: [WebNovelCategory] = [everything] + [
        (21, "玄幻"), (1, "奇幻"), (2, "武侠"), (22, "仙侠"), (4, "都市"), (15, "现实"), (6, "军事"), (5, "历史"),
        (7, "游戏"), (8, "体育"), (9, "科幻"), (10, "悬疑灵异"), (20109, "诸天无限"), (12, "轻小说")
    ].map { WebNovelCategory(id: $0.0, title: $0.1) }
    static func titled(_ id: Int) -> String { all.first { $0.id == id }?.title ?? everything.title }
}

/// One chart as the reader chose it: which chart, which category, which period.
struct WebNovelSelection: Hashable, Codable {
    var chart: WebNovelChart
    var category: Int
    var period: WebNovelPeriod
    init(chart: WebNovelChart = .tickets, category: Int = WebNovelCategory.everything.id, period: WebNovelPeriod = .week) {
        self.chart = chart
        self.category = WebNovelCategory.all.contains { $0.id == category } ? category : WebNovelCategory.everything.id
        self.period = chart.hasPeriods ? period : .week
    }
    var url: URL {
        var path = "https://m.qidian.com/rank/\(chart.rawValue)/catid\(category)/"
        if chart.hasPeriods { path += "\(period.rawValue)/" }
        return URL(string: path)!
    }
    var caption: String {
        ([chart.title] + (chart.hasPeriods ? [period.title] : []) + [WebNovelCategory.titled(category)]).joined(separator: " · ")
    }
}

struct WebNovel: Codable, Equatable, Identifiable {
    let rank: Int
    let bookID: String
    let title: String
    let author: String
    let category: String
    let subcategory: String
    /// The site's own wording, such as "86.29万字".
    let length: String
    /// What the chart counts, such as "6.48万月票"; some charts publish none.
    let figure: String
    let summary: String
    var id: String { "qidian:" + bookID }
    var coverURL: URL? { URL(string: "https://bookcover.yuewen.com/qdbimg/349573/\(bookID)/180") }
    var sourceURL: URL { URL(string: "https://m.qidian.com/book/\(bookID)/")! }
    var byline: String { [author, category, length].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct WebNovelList: Codable, Equatable {
    let selection: WebNovelSelection
    /// The month a 月票榜 counts, such as "2026年11月"; empty for the other charts.
    let published: String
    let fetchedAt: Date
    let books: [WebNovel]
}

enum WebNovelFeedError: LocalizedError, Equatable {
    case unavailable, invalidResponse, rateLimited
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The 起点 chart could not be loaded. Try again."
        case .invalidResponse: return "起点 returned an unfamiliar page. A chart loaded earlier has been kept."
        case .rateLimited: return "起点 is limiting requests. Try again later."
        }
    }
}

protocol WebNovelServing {
    func list(_ selection: WebNovelSelection) async throws -> WebNovelList
}

/// Reads one public chart page of 起点's mobile site. No account, no cookies kept.
struct QidianChartClient: WebNovelServing {
    var session: URLSession = URLSession(configuration: .ephemeral)
    static let pageSize = 20

    func list(_ selection: WebNovelSelection) async throws -> WebNovelList {
        var request = URLRequest(url: selection.url, timeoutInterval: 25)
        request.setValue("LeafReader/1.41 (book discovery)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw WebNovelFeedError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 429: throw WebNovelFeedError.rateLimited
        default: throw WebNovelFeedError.unavailable // 202 is the site's browser check
        }
        return try Self.parse(data, selection: selection)
    }

    /// The page carries its chart as JSON for its own scripts. Leaf reads that data
    /// and nothing executable, and accepts it only when the page says it is the chart,
    /// category and period that were asked for, with a full, gapless ranking.
    static func parse(_ data: Data, selection: WebNovelSelection, now: Date = Date()) throws -> WebNovelList {
        guard !data.isEmpty, data.count <= 3_000_000, let html = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"(?is)<script\b[^>]*\bid\s*=\s*["']vite-plugin-ssr_pageContext["'][^>]*>(.*?)</script\s*>"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let root = (try? JSONSerialization.jsonObject(with: Data(html[range].utf8))) as? [String: Any],
              let context = root["pageContext"] as? [String: Any],
              (context["routeParams"] as? [String: Any])?["pageType"] as? String == selection.chart.rawValue,
              let page = (context["pageProps"] as? [String: Any])?["pageData"] as? [String: Any],
              page["pageNum"] as? Int == 1, let total = page["total"] as? Int,
              let rows = page["records"] as? [[String: Any]], let filters = page["filters"] as? [[String: Any]]
        else { throw WebNovelFeedError.invalidResponse }
        func chosen(_ key: String) -> Any? {
            guard let filter = filters.first(where: { $0["key"] as? String == key }), let items = filter["items"] as? [[String: Any]],
                  let index = filter["selectedIndex"] as? Int, items.indices.contains(index) else { return nil }
            return items[index]["value"]
        }
        guard chosen("catId") as? Int == selection.category,
              !selection.chart.hasPeriods || chosen("rankPeriod") as? Int == selection.period.rawValue,
              rows.count == min(pageSize, total), !rows.isEmpty else { throw WebNovelFeedError.invalidResponse }
        let books = try rows.enumerated().map { index, row -> WebNovel in
            func text(_ key: String, _ limit: Int) -> String {
                String((row[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
            }
            let id = text("bid", 20), title = text("bName", 200), author = text("bAuth", 100)
            guard row["rankNum"] as? Int == index + 1, !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !title.isEmpty, !author.isEmpty else { throw WebNovelFeedError.invalidResponse }
            return WebNovel(rank: index + 1, bookID: id, title: title, author: author, category: text("cat", 40),
                            subcategory: text("subCat", 40), length: text("cnt", 40), figure: text("rankCnt", 40), summary: text("desc", 3000))
        }
        guard Set(books.map(\.bookID)).count == books.count else { throw WebNovelFeedError.invalidResponse }
        var published = ""
        if selection.chart == .tickets, let month = chosen("yearmonth") as? String, month.count == 6, month.allSatisfy({ $0.isASCII && $0.isNumber }),
           let number = Int(month.suffix(2)), (1...12).contains(number) {
            published = "\(month.prefix(4))年\(number)月"
        }
        return WebNovelList(selection: selection, published: published, fetchedAt: now, books: books)
    }
}

/// Catalog uploads of web novels wrap the title in notes such as 《…》, （精校版）
/// or "作者：…". These compare what is left once those are taken off.
enum WebNovelText {
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func letters(_ text: String) -> String { String(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
    private static func withoutNotes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|【[^】]*】"#, with: " ", options: .regularExpression)
    }
    static func title(_ text: String) -> String {
        var value = folded(text)
        if let open = value.firstIndex(of: "《"), let close = value[open...].firstIndex(of: "》") {
            value = String(value[value.index(after: open)..<close])
        }
        value = withoutNotes(value)
        if let credit = value.range(of: "作者") { value = String(value[..<credit.lowerBound]) }
        for word in ["精校版", "校对版", "精校", "全本", "完本", "全集", "txt", "epub"] { value = value.replacingOccurrences(of: word, with: " ") }
        return letters(value)
    }
    static func author(_ text: String) -> String {
        var value = withoutNotes(folded(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let credit = value.range(of: "作者") { value = String(value[credit.upperBound...]) }
        if value.hasSuffix("著") { value.removeLast() }
        return letters(value)
    }
    /// The same book with the same author can be added at once; an upload with no
    /// author, or a longer title that begins the same way (a sequel, a box set), is
    /// only offered for the reader to check.
    static func rank(_ novel: WebNovel, editions: [ZLibraryBook]) -> [BestsellerEdition] {
        let wanted = title(novel.title), writer = author(novel.author)
        guard !wanted.isEmpty, !writer.isEmpty else { return [] }
        var seen: Set<String> = []
        return editions.compactMap { book -> BestsellerEdition? in
            guard seen.insert(book.id).inserted else { return nil }
            let candidate = title(book.title), credit = author(book.author)
            let sameAuthor = credit.contains(writer)
            if candidate == wanted, sameAuthor { return BestsellerEdition(book: book, confidence: .titleAndAuthor) }
            if candidate == wanted, credit.isEmpty { return BestsellerEdition(book: book, confidence: .possible) }
            if candidate.hasPrefix(wanted), sameAuthor { return BestsellerEdition(book: book, confidence: .possible) }
            return nil
        }.sorted(by: BestsellerEdition.preferred)
    }
    static func same(_ book: Book, as novel: WebNovel) -> Bool {
        title(book.title) == title(novel.title) && author(book.author).contains(author(novel.author))
    }
}
