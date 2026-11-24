import Foundation

/// Where a Chinese chart comes from: 起点's web-novel charts or 微信读书's book charts.
enum WebNovelSource: String, CaseIterable, Codable, Identifiable {
    case qidian, weread
    var id: String { rawValue }
    var title: String { self == .qidian ? "起点" : "微信读书" }
    var fullName: String { self == .qidian ? "起点中文网" : "微信读书" }
    var charts: [WebNovelChart] { WebNovelChart.allCases.filter { $0.source == self } }
}

/// The charts Leaf shows. The raw value is the chart's name in its site's address.
enum WebNovelChart: String, CaseIterable, Codable, Identifiable {
    case tickets = "yuepiao", sales = "hotsales", reading = "readindex", recommended = "rec"
    case top = "all", rising, newBooks = "newbook", acclaimed = "newrating_publish"
    var id: String { rawValue }
    var source: WebNovelSource { [.top, .rising, .newBooks, .acclaimed].contains(self) ? .weread : .qidian }
    var title: String {
        switch self {
        case .tickets: return "月票榜"
        case .sales: return "畅销榜"
        case .reading: return "阅读指数榜"
        case .recommended: return "推荐票榜"
        case .top: return "总榜"
        case .rising: return "飙升榜"
        case .newBooks: return "新书榜"
        case .acclaimed: return "神作榜"
        }
    }
    /// A label short enough for four segments on a narrow phone.
    var shortTitle: String { self == .reading ? "阅读指数" : self == .top ? title : String(title.dropLast()) }
    var meaning: String {
        switch self {
        case .tickets: return "monthly reader votes"
        case .sales: return "sales"
        case .reading: return "reading index"
        case .recommended: return "recommendation votes"
        case .top: return "the 200 most read books"
        case .rising: return "published books rising fastest"
        case .newBooks: return "newly published books"
        case .acclaimed: return "published books with the highest recommendation rate"
        }
    }
    /// Only 起点's recommendation chart is published for a week, a month and all time.
    var hasPeriods: Bool { self == .recommended }
}

enum WebNovelPeriod: Int, CaseIterable, Codable, Identifiable {
    case week = 3, month = 2, allTime = 1
    var id: Int { rawValue }
    var title: String { self == .week ? "周榜" : self == .month ? "月榜" : "总榜" }
    /// The name Ask Leaf's tool uses.
    var key: String { self == .week ? "week" : self == .month ? "month" : "all_time" }
}

/// 起点's categories. 微信读书's charts are shown for the whole site only.
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

/// One chart as the reader chose it: which chart and, on 起点, which category and period.
struct WebNovelSelection: Hashable, Codable {
    var chart: WebNovelChart
    var category: Int
    var period: WebNovelPeriod
    var source: WebNovelSource { chart.source }
    init(chart: WebNovelChart = .tickets, category: Int = WebNovelCategory.everything.id, period: WebNovelPeriod = .week) {
        self.chart = chart
        let listed = chart.source == .qidian && WebNovelCategory.all.contains { $0.id == category }
        self.category = listed ? category : WebNovelCategory.everything.id
        self.period = chart.hasPeriods ? period : .week
    }
    /// The chart's own page, for the reader to open.
    var pageURL: URL {
        guard source == .qidian else { return URL(string: "https://weread.qq.com/web/category/\(chart.rawValue)")! }
        var path = "https://m.qidian.com/rank/\(chart.rawValue)/catid\(category)/"
        if chart.hasPeriods { path += "\(period.rawValue)/" }
        return URL(string: path)!
    }
    /// What Leaf requests. 起点 serves its page; 微信读书 serves 20 books from `offset` as data.
    func requestURL(offset: Int = 0) -> URL {
        source == .qidian ? pageURL : URL(string: "https://weread.qq.com/web/bookListInCategory/\(chart.rawValue)?maxIndex=\(offset)&rank=1")!
    }
    var caption: String {
        guard source == .qidian else { return chart.title }
        return ([chart.title] + (chart.hasPeriods ? [period.title] : []) + [WebNovelCategory.titled(category)]).joined(separator: " · ")
    }
}

/// A book on a chart. The name dates from the 起点 web-novel charts; 微信读书's books use it too.
struct WebNovel: Codable, Equatable, Identifiable {
    let rank: Int
    let bookID: String
    let title: String
    let author: String
    let category: String
    let subcategory: String
    /// The site's own wording, such as "86.29万字"; 微信读书 gives none.
    let length: String
    /// What the chart counts, such as "6.48万月票" or "93.0% 推荐 · 今日 1.1万人在读"; some charts publish none.
    let figure: String
    let summary: String
    var source: WebNovelSource = .qidian
    /// 微信读书 names each book's cover and page; 起点's follow from the book's number.
    var cover: URL? = nil
    var link: URL? = nil
    /// 微信读书's recommendation rate in thousandths, how many readers rated it, and its verdict such as 神作.
    var ratingPermille: Int? = nil
    var ratingCount: Int? = nil
    var ratingTitle: String? = nil
    var id: String { source.rawValue + ":" + bookID }
    var coverURL: URL? { cover ?? (source == .qidian ? URL(string: "https://bookcover.yuewen.com/qdbimg/349573/\(bookID)/180") : nil) }
    var sourceURL: URL { link ?? URL(string: source == .qidian ? "https://m.qidian.com/book/\(bookID)/" : "https://weread.qq.com/")! }
    var byline: String { [author, category, length].filter { !$0.isEmpty }.joined(separator: " · ") }
}

struct WebNovelList: Codable, Equatable {
    let selection: WebNovelSelection
    /// The month a 月票榜 counts, such as "2026年11月"; empty for the other charts.
    let published: String
    let fetchedAt: Date
    let books: [WebNovel]
    /// Whether the site has more of this chart after these books.
    var hasMore = false
}

enum WebNovelFeedError: LocalizedError, Equatable {
    case unavailable, invalidResponse, rateLimited
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The chart could not be loaded. Try again."
        case .invalidResponse: return "The site returned an unfamiliar page. A chart loaded earlier has been kept."
        case .rateLimited: return "The site is limiting requests. Try again later."
        }
    }
}

protocol WebNovelServing {
    /// The chart from its first book, or the books that follow the first `offset`.
    func list(_ selection: WebNovelSelection, offset: Int) async throws -> WebNovelList
}

/// Reads one public chart page. No account, no cookies kept.
struct WebNovelClient: WebNovelServing {
    var session: URLSession = URLSession(configuration: .ephemeral)
    static let pageSize = 20

    func list(_ selection: WebNovelSelection, offset: Int) async throws -> WebNovelList {
        var request = URLRequest(url: selection.requestURL(offset: offset), timeoutInterval: 25)
        request.setValue("LeafReader/1.42 (book discovery)", forHTTPHeaderField: "User-Agent")
        request.setValue(selection.source == .qidian ? "text/html" : "application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw WebNovelFeedError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 429: throw WebNovelFeedError.rateLimited
        default: throw WebNovelFeedError.unavailable // 202 is 起点's browser check
        }
        switch selection.source {
        case .qidian: return try QidianChart.parse(data, selection: selection)
        case .weread: return try WeReadChart.parse(data, selection: selection, offset: offset)
        }
    }
}

/// 微信读书's chart data: 20 books a request, each with its rating, readers today, cover and page.
enum WeReadChart {
    /// Accepted only as a full page that continues the ranking where `offset` left off.
    static func parse(_ data: Data, selection: WebNovelSelection, offset: Int = 0, now: Date = Date()) throws -> WebNovelList {
        guard !data.isEmpty, data.count <= 3_000_000, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["books"] as? [[String: Any]], let more = root["hasMore"] as? Int,
              !rows.isEmpty, rows.count <= WebNovelClient.pageSize, more == 0 || rows.count == WebNovelClient.pageSize
        else { throw WebNovelFeedError.invalidResponse }
        let books = try rows.enumerated().map { index, row -> WebNovel in
            guard let info = row["bookInfo"] as? [String: Any], row["searchIdx"] as? Int == offset + index + 1 else { throw WebNovelFeedError.invalidResponse }
            func text(_ key: String, _ limit: Int) -> String {
                let value = (info[key] as? String ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                return String(value.trimmingCharacters(in: .whitespaces).prefix(limit))
            }
            let id = text("bookId", 40), title = text("title", 200), author = text("author", 100)
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }), !title.isEmpty, !author.isEmpty
            else { throw WebNovelFeedError.invalidResponse }
            // "精品小说-科幻小说": the shelf, then the kind of book.
            let shelves = text("category", 80).components(separatedBy: "-")
            var figures: [String] = []
            if let rating = info["newRating"] as? Int, (1...1000).contains(rating) { figures.append(String(format: "%.1f%% 推荐", Double(rating) / 10)) }
            if let readers = row["readingCount"] as? Int, readers > 0 {
                figures.append("今日 " + (readers >= 10_000 ? String(format: "%.1f万", Double(readers) / 10_000) : String(readers)) + "人在读")
            }
            return WebNovel(rank: offset + index + 1, bookID: id, title: title, author: author, category: shelves.last ?? "",
                            subcategory: shelves.count > 1 ? shelves[0] : "", length: "", figure: figures.joined(separator: " · "),
                            summary: text("intro", 3000), source: .weread,
                            cover: address(info["cover"], hosts: ["weread.qq.com", "myqcloud.com", "qqmail.com", "qpic.cn"]),
                            link: address(info["deepLink"], hosts: ["weread.qq.com"]),
                            ratingPermille: (info["newRating"] as? Int).flatMap { (1...1000).contains($0) ? $0 : nil },
                            ratingCount: (info["newRatingCount"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                            ratingTitle: ((info["newRatingDetail"] as? [String: Any])?["title"] as? String).map { String($0.prefix(20)) })
        }
        guard Set(books.map(\.bookID)).count == books.count else { throw WebNovelFeedError.invalidResponse }
        return WebNovelList(selection: selection, published: "", fetchedAt: now, books: books, hasMore: more != 0)
    }
    /// An https address on one of the site's own hosts, or nothing.
    private static func address(_ value: Any?, hosts: [String]) -> URL? {
        guard let text = value as? String, text.utf8.count <= 500, let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
}

/// 起点's mobile chart page.
enum QidianChart {
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
              rows.count == min(WebNovelClient.pageSize, total), !rows.isEmpty else { throw WebNovelFeedError.invalidResponse }
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

/// Catalog uploads wrap a title in notes such as 《…》, （精校版） or "作者：…", and the
/// charts add their own, such as （全三册） or [英] before an author. These compare what
/// is left once those are taken off.
enum WebNovelText {
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func letters(_ text: String) -> String { String(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
    private static func withoutNotes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]|【[^】]*】"#, with: " ", options: .regularExpression)
    }
    /// `mainOnly` leaves out a subtitle, the part after a colon.
    static func title(_ text: String, mainOnly: Bool = false) -> String {
        var value = folded(text)
        if let open = value.firstIndex(of: "《"), let close = value[open...].firstIndex(of: "》") {
            value = String(value[value.index(after: open)..<close])
        }
        value = withoutNotes(value)
        if let credit = value.range(of: "作者") { value = String(value[..<credit.lowerBound]) }
        if mainOnly, let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        for word in ["精校版", "校对版", "精校", "全本", "完本", "全集", "txt", "epub"] { value = value.replacingOccurrences(of: word, with: " ") }
        return letters(value)
    }
    static func author(_ text: String) -> String {
        var value = withoutNotes(folded(text)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let credit = value.range(of: "作者") { value = String(value[credit.upperBound...]) }
        if value.hasSuffix("著") { value.removeLast() }
        return letters(value)
    }
    /// The same book with the same author can be added at once. An upload with no author
    /// or only the author's surname, a longer title that begins the same way (a sequel,
    /// a box set), or one that differs only in its subtitle is offered for the reader to check.
    static func rank(_ novel: WebNovel, editions: [ZLibraryBook]) -> [BestsellerEdition] {
        let wanted = title(novel.title), main = title(novel.title, mainOnly: true), writer = author(novel.author)
        guard !wanted.isEmpty, !main.isEmpty, !writer.isEmpty else { return [] }
        var seen: Set<String> = []
        return editions.compactMap { book -> BestsellerEdition? in
            guard seen.insert(book.id).inserted else { return nil }
            let candidate = title(book.title), credit = author(book.author)
            let sameAuthor = credit.contains(writer)
            // "纪德" for "[法]安德烈·纪德": the same person, but worth a look.
            let likelyAuthor = sameAuthor || (credit.count >= 2 && writer.hasSuffix(credit))
            if candidate == wanted, sameAuthor { return BestsellerEdition(book: book, confidence: .titleAndAuthor) }
            if candidate == wanted, credit.isEmpty || likelyAuthor { return BestsellerEdition(book: book, confidence: .possible) }
            if likelyAuthor, candidate.hasPrefix(wanted) || title(book.title, mainOnly: true) == main {
                return BestsellerEdition(book: book, confidence: .possible)
            }
            return nil
        }.sorted(by: BestsellerEdition.preferred)
    }
    static func same(_ book: Book, as novel: WebNovel) -> Bool {
        title(book.title) == title(novel.title) && author(book.author).contains(author(novel.author))
    }
}
