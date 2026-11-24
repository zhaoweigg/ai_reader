import XCTest
@testable import LeafReader

private struct ReviewCredentials: ChatCredentialStore {
    func read(account: String) throws -> String? { nil }
    func write(_ key: String?, account: String) throws {}
}

/// Answers each lookup with the next result it was given, and counts them.
private actor ScriptedReviews: BookReviewServing {
    private var results: [BookReviews]
    private(set) var calls: [(BookReviewQuery, String?)] = []
    init(_ results: [BookReviews]) { self.results = results }
    func reviews(_ query: BookReviewQuery, nytKey: String?) async -> BookReviews {
        calls.append((query, nytKey))
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

/// An AI with the agent interface that searches the web once, then answers.
@MainActor private final class SearchingProvider: ToolChatProvider {
    var systems: [String] = [], tools: [[String]] = [], questions: [String] = []
    nonisolated func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatError.invalidResponse) }
    }
    nonisolated func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        let question = items.compactMap { item -> String? in if case .turn(let turn) = item { return turn.content }; return nil }.last ?? ""
        let names = tools.map(\.name)
        Task { @MainActor in self.systems.append(system); self.tools.append(names); self.questions.append(question) }
        return AsyncThrowingStream { continuation in
            if allowTools, names.contains(AgentTool.webSearchName) { continuation.yield(.webSearch("Project Hail Mary reviews")) }
            continuation.yield(.text("**Liked:** the science.\n**Mixed:** the voice.\n**Who it’s for:** puzzle lovers.\n**Sources:** [A review](https://example.com/r)"))
            continuation.yield(.finished(truncated: false)); continuation.finish()
        }
    }
}

@MainActor final class BookReviewTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "BookReviewTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testOpenLibraryGivesTheRatingItsStarsAndReadingCountsAndATitleSearchMustMatchTheAuthor() throws {
        let json = #"{"numFound":2,"docs":[{"key":"/works/OL21745884W","title":"Project Hail Mary","author_name":["Andy Weir"],"ratings_average":4.5373135,"ratings_count":201,"ratings_count_1":1,"ratings_count_2":5,"ratings_count_3":11,"ratings_count_4":52,"ratings_count_5":132,"want_to_read_count":1192,"already_read_count":308}]}"#
        let byISBN = BookReviewQuery(title: "Project Hail Mary", author: "Andy Weir", isbns: ["9780593135204"])
        let rating = try XCTUnwrap(OpenLibraryRatings.parse(Data(json.utf8), query: byISBN))
        XCTAssertEqual(rating.site, .openLibrary); XCTAssertEqual(rating.score, "4.5"); XCTAssertEqual(rating.count, "201 ratings")
        XCTAssertEqual(rating.distribution?.first ?? 0, 132.0 / 201, accuracy: 0.001); XCTAssertEqual(rating.distribution?.count, 5)
        XCTAssertEqual(rating.notes, ["1,192 want to read", "308 have read"])
        XCTAssertEqual(rating.url?.absoluteString, "https://openlibrary.org/works/OL21745884W")
        // By title, another author's book of the same name is not this one.
        XCTAssertNotNil(try OpenLibraryRatings.parse(Data(json.utf8), query: BookReviewQuery(title: "Project Hail Mary", author: "Andy Weir")))
        XCTAssertNil(try OpenLibraryRatings.parse(Data(json.utf8), query: BookReviewQuery(title: "Project Hail Mary", author: "Someone Else")))
        XCTAssertNil(try OpenLibraryRatings.parse(Data(#"{"docs":[{"key":"/works/OL1W","title":"Unrated","ratings_count":0}]}"#.utf8), query: byISBN))
        XCTAssertThrowsError(try OpenLibraryRatings.parse(Data("<html>".utf8), query: byISBN))
    }

    func testDoubanPageGivesItsScoreStarsAndMostUsefulShortReviews() throws {
        func item(_ votes: Int, _ stars: Int, _ text: String) -> String {
            #"<li class="comment-item" data-cid="1"><div class="comment"><h3><span class="comment-vote"><span id="c-1" class="vote-count">\#(votes)</span></span><span class="comment-info"><a href="https://www.douban.com/people/x/">reader</a><span class="user-stars allstar\#(stars)0 rating" title=""></span></span></h3><p class="comment-content"><span class="short">\#(text)</span></p></div></li>"#
        }
        let html = """
        <span property="v:itemreviewed">三体</span><strong class="ll rating_num" property="v:average"> 8.9 </strong>
        <span property="v:votes">519564</span>\(["62.6", "29.7", "6.5", "0.8", "0.5"].map { #"<span class="rating_per">\#($0)%</span>"# }.joined())
        <ul>\(item(531, 3, "物理名词&amp;设定很多")) \(item(13066, 5, "想象力一流")) \(item(9, 1, ""))</ul>
        """
        let address = URL(string: "https://book.douban.com/subject/2567698/")!
        let book = try DoubanBooks.parse(Data(html.utf8), address: address)
        let rating = try XCTUnwrap(book.rating)
        XCTAssertEqual(rating.score, "8.9"); XCTAssertEqual(rating.stars ?? 0, 4.45, accuracy: 0.001); XCTAssertEqual(rating.count, "519,564 ratings")
        XCTAssertEqual(rating.distribution?.first ?? 0, 0.626, accuracy: 0.0001); XCTAssertEqual(rating.url, address)
        // The most useful first; an empty review is left out; no reader's name is kept.
        XCTAssertEqual(book.reviews, [ReaderReview(stars: 5, text: "想象力一流", helpful: 13066), ReaderReview(stars: 3, text: "物理名词&设定很多", helpful: 531)])
        XCTAssertEqual(book.reviewsURL.absoluteString, "https://book.douban.com/subject/2567698/comments/")
        // Too few ratings for a score: the reviews still count.
        let unrated = try DoubanBooks.parse(Data(#"<span property="v:itemreviewed">新书</span><strong class="ll rating_num" property="v:average">  </strong>\#(item(4, 4, "好看"))"#.utf8), address: address)
        XCTAssertNil(unrated.rating); XCTAssertEqual(unrated.reviews.count, 1)
        XCTAssertThrowsError(try DoubanBooks.parse(Data(html.utf8), address: URL(string: "https://www.douban.com/misc/sorry")!))
        XCTAssertThrowsError(try DoubanBooks.parse(Data("<html>check</html>".utf8), address: address))
    }

    func testDoubanSuggestionsAreMatchedByTitleAndAuthor() throws {
        func rows(_ books: [(String, String, String)]) -> Data {
            Data(ReadingAgentToolbox.json(books.map { ["title": $0.0, "author_name": $0.1, "id": $0.2, "type": "b"] }).utf8)
        }
        let query = BookReviewQuery(title: "诡秘之主", author: "爱潜水的乌贼")
        XCTAssertEqual(try DoubanBooks.match(rows([("诡秘之主 1", "爱潜水的乌贼", "35051813"), ("诡秘之主", "爱潜水的乌贼", "33424453")]), query: query), "33424453")
        // Only a printed volume is listed: that is the book.
        XCTAssertEqual(try DoubanBooks.match(rows([("诡秘之主（全18册）", "爱潜水的乌贼", "38531098")]), query: query), "38531098")
        XCTAssertEqual(try DoubanBooks.match(rows([("诡秘之主 2", "爱潜水的乌贼", "35051814")]), query: query), "35051814")
        XCTAssertNil(try DoubanBooks.match(rows([("诡秘之主", "另一位作者", "1"), ("诡秘之主同人", "爱潜水的乌贼", "2")]), query: query))
    }

    func testWeReadSearchGivesTheSameBooksRateAndTheChartRowCarriesItsOwn() throws {
        let search = #"{"books":[{"bookInfo":{"bookId":"40542611","title":"三体：史上最称职的面壁者","author":"火炀","newRating":774,"newRatingCount":63}},{"bookInfo":{"bookId":"695233","title":"三体全集（全三册）","author":"刘慈欣","newRating":930,"newRatingCount":296101,"newRatingDetail":{"title":"神作"},"deepLink":"https://weread.qq.com/book-detail?type=1&v=ce0"}}]}"#
        let rating = try XCTUnwrap(WeReadRatings.parse(Data(search.utf8), query: BookReviewQuery(title: "三体全集", author: "刘慈欣")))
        XCTAssertEqual(rating.score, "93.0%"); XCTAssertEqual(rating.count, "recommended · 296,101 ratings"); XCTAssertEqual(rating.verdict, "神作")
        XCTAssertEqual(rating.url?.host, "weread.qq.com")
        XCTAssertNil(try WeReadRatings.parse(Data(search.utf8), query: BookReviewQuery(title: "三体全集", author: "别人")))
        // A chart row keeps the numbers, so its book page shows them without another request.
        let chart = #"{"books":[{"searchIdx":1,"readingCount":11623,"bookInfo":{"bookId":"695233","title":"三体全集（全三册）","author":"刘慈欣","category":"精品小说-科幻小说","intro":"…","newRating":930,"newRatingCount":296101,"newRatingDetail":{"title":"神作"}}}],"hasMore":0}"#
        let novel = try XCTUnwrap(WeReadChart.parse(Data(chart.utf8), selection: WebNovelSelection(chart: .top)).books.first)
        XCTAssertEqual(novel.wereadRating?.score, "93.0%"); XCTAssertEqual(novel.wereadRating?.verdict, "神作")
        XCTAssertEqual(BookReviewQuery(novel).listed, novel.wereadRating)
    }

    func testNYTReviewsKeepOnlyItsOwnLinks() throws {
        let json = #"{"status":"OK","results":[{"url":"https://www.nytimes.com/2021/05/04/books/review/project-hail-mary.html","publication_dt":"2021-05-04","byline":"By Critic","summary":"A space rescue."},{"url":"https://example.com/not-nyt","byline":"x"},{"url":"http://www.nytimes.com/insecure"}]}"#
        let reviews = try NYTReviews.parse(Data(json.utf8))
        XCTAssertEqual(reviews.count, 1); XCTAssertEqual(reviews[0].published, "2021-05-04"); XCTAssertEqual(reviews[0].outlet, "The New York Times")
        XCTAssertThrowsError(try NYTReviews.parse(Data(#"{"status":"ERROR","results":[]}"#.utf8)))
    }

    func testOneBookHasOneEntryWhicheverPageOrEditionOpensIt() {
        XCTAssertEqual(BookReviewQuery(title: "A", author: "B", isbns: ["0-593-13520-2"]).key, BookReviewQuery(title: "A, again", author: "C", isbns: ["9780593135204"]).key)
        XCTAssertEqual(BookReviewQuery(title: "三体全集（全三册）", author: "刘慈欣").key, BookReviewQuery(title: "三体全集", author: "[中]刘慈欣").key)
        XCTAssertTrue(BookReviewQuery(title: "三体", author: "刘慈欣").isChinese); XCTAssertFalse(BookReviewQuery(title: "Dune", author: "Frank Herbert").isChinese)
        let catalog = ZLibraryBook(remoteID: "1", hash: "h", title: "Dune", author: "Frank Herbert", fileExtension: "epub", size: "1 MB", language: "English",
                                   year: "1965", coverURL: nil, rating: 4.2, ratingCount: 52, qualityScore: 4.8, isbns: ["9780441013593"])
        let listed = BookReviewQuery(catalog).listed
        XCTAssertEqual(listed?.site, .zlibrary); XCTAssertEqual(listed?.score, "4.2"); XCTAssertEqual(listed?.count, "52 ratings")
        XCTAssertEqual(listed?.notes, ["File quality 4.8"]); XCTAssertNil(listed?.stars, "Z-Library's scale is not turned into stars")
    }

    func testAWeekIsKeptAFailedSiteIsAskedAgainAfterAnHourAndKeepsWhatItSaidBefore() async {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var clock = start
        let douban = BookRating(site: .douban, score: "8.9", stars: 4.45, count: "10 ratings")
        let review = ReaderReview(stars: 5, text: "好看", helpful: 3)
        let full = BookReviews(ratings: [douban], readerReviews: [review], readerReviewsSite: .douban,
                               readerReviewsURL: URL(string: "https://book.douban.com/subject/1/comments/"), fetchedAt: start)
        let failed = BookReviews(unavailable: [.douban], fetchedAt: start)
        let service = ScriptedReviews([full, failed, full])
        let defaults = defaults()
        let store = BookReviewStore(defaults: defaults, service: service, nytKey: { "nyt-key" }, now: { clock })
        let query = BookReviewQuery(title: "三体", author: "刘慈欣")
        await store.load(query)
        XCTAssertEqual(store.reviews(for: query)?.ratings, [douban])
        var calls = await service.calls
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].1, "nyt-key")
        clock = start.addingTimeInterval(6 * 86_400); await store.load(query)
        calls = await service.calls; XCTAssertEqual(calls.count, 1, "A week is kept")
        // Asked again; 豆瓣 does not answer, so what it said before stays, marked for retry.
        await store.load(query, force: true)
        XCTAssertEqual(store.reviews(for: query)?.ratings, [douban]); XCTAssertEqual(store.reviews(for: query)?.readerReviews, [review])
        XCTAssertEqual(store.reviews(for: query)?.unavailable, [.douban])
        clock = clock.addingTimeInterval(30 * 60); await store.load(query)
        calls = await service.calls; XCTAssertEqual(calls.count, 2, "Not again within the hour")
        clock = clock.addingTimeInterval(31 * 60); await store.load(query)
        calls = await service.calls; XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(store.reviews(for: query)?.unavailable, [])
        // A newer score on the list replaces the one kept, without asking the sites.
        let listed = WeReadRatings.rating(permille: 912, count: 9, verdict: nil, url: nil)!
        await store.load(BookReviewQuery(title: "三体", author: "刘慈欣", listed: listed))
        XCTAssertEqual(store.reviews(for: query)?.ratings.first, listed)
        calls = await service.calls; XCTAssertEqual(calls.count, 3)
        // Kept across launches.
        let reopened = BookReviewStore(defaults: defaults, service: service, now: { clock })
        XCTAssertEqual(reopened.reviews(for: query)?.readerReviews, [review])
    }

    func testTheSummaryIsAskedWithOnlyWebSearchAndIsKept() async throws {
        let provider = SearchingProvider(), defaults = defaults()
        let settings = AISettingsStore(defaults: defaults, credentials: ReviewCredentials(), providerOverride: provider)
        let store = BookReviewStore(defaults: defaults, service: ScriptedReviews([BookReviews(fetchedAt: Date())]))
        let query = BookReviewQuery(title: "Project Hail Mary", author: "Andy Weir", isbns: ["9780593135204"])
        await store.load(query)
        await store.summarize(query, settings: settings)
        let summary = try XCTUnwrap(store.summary(for: query))
        XCTAssertTrue(summary.searchedWeb); XCTAssertTrue(summary.text.hasPrefix("**Liked:** the science."))
        XCTAssertNil(store.summarizing[query.key]); XCTAssertNil(store.summaryErrors[query.key])
        try await eventually { !provider.tools.isEmpty }
        XCTAssertEqual(provider.tools.first, [AgentTool.webSearchName], "Web search is the summary's only tool")
        XCTAssertTrue(provider.questions[0].hasPrefix(BookReviewSummarizer.question)); XCTAssertTrue(provider.questions[0].contains("9780593135204"))
        XCTAssertTrue(provider.systems[0].contains("English")); XCTAssertTrue(provider.systems[0].contains("untrusted"))
        XCTAssertTrue(BookReviewSummarizer.request(BookReviewQuery(title: "三体", author: "刘慈欣"), reviews: nil).system.contains("**好评：**"))
        XCTAssertEqual(BookReviewStore(defaults: defaults).summary(for: query), summary, "Kept until the reader asks again")
        // Without an AI set up, the reason is shown and nothing is kept.
        let unset = AISettingsStore(defaults: self.defaults(), credentials: ReviewCredentials())
        let other = BookReviewQuery(title: "Dune", author: "Frank Herbert")
        await store.summarize(other, settings: unset)
        XCTAssertNil(store.summary(for: other)); XCTAssertNotNil(store.summaryErrors[other.key])
    }
}
