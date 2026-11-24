import Foundation

#if DEBUG
/// Ratings and reviews for UI tests, in the shape each site gives them, without the network.
/// English books get Open Library's ratings and, with an ISBN, a critic's review; Chinese
/// books get 豆瓣's score and short reviews and, unless the list carried it, 微信读书's rate.
struct UITestBookReviewClient: BookReviewServing {
    /// Books whose first lookup has already failed, for the try-again case.
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock(); private var failed: Set<String> = []
        func firstFailure(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failed.insert(key).inserted }
    }
    private static let attempts = Attempts()

    func reviews(_ query: BookReviewQuery, nytKey: String?) async -> BookReviews {
        try? await Task.sleep(for: .milliseconds(500))
        var result = BookReviews(fetchedAt: Date())
        if let listed = query.listed { result.ratings.append(listed) }
        let failsDouban = UITesting.flag(.bookReviewsFailure) && Self.attempts.firstFailure(query.key)
        if query.isChinese {
            if failsDouban { result.unavailable = [.douban] } else {
                result.ratings.append(BookRating(site: .douban, score: "8.6", stars: 4.3, count: "12,345 ratings",
                                                 distribution: [0.52, 0.33, 0.11, 0.03, 0.01], url: URL(string: "https://book.douban.com/subject/1000001/")))
                result.readerReviews = [
                    ReaderReview(stars: 5, text: "开篇就把人拉进去，后半段的反转让人忍不住一口气读完。", helpful: 1204),
                    ReaderReview(stars: 4, text: "设定很有想象力，人物稍显单薄，但不影响好看。", helpful: 516),
                    ReaderReview(stars: 3, text: "节奏偏慢，前三十章需要一点耐心。", helpful: 88)
                ]
                result.readerReviewsSite = .douban
                result.readerReviewsURL = URL(string: "https://book.douban.com/subject/1000001/comments/")
                result.readerReviewsTotal = Self.doubanTotal
            }
            if query.listed?.site != .weread {
                result.ratings.append(WeReadRatings.rating(permille: 912, count: 8_420, verdict: "好评如潮", url: nil)!)
            }
        } else {
            if failsDouban { result.unavailable = [.openLibrary] } else {
                result.ratings.append(BookRating(site: .openLibrary, score: "4.3", stars: 4.3, count: "1,204 ratings",
                                                 distribution: [0.55, 0.28, 0.1, 0.05, 0.02], notes: ["3,410 want to read"],
                                                 url: URL(string: "https://openlibrary.org/works/OL1000001W")))
            }
            if !query.isbns.isEmpty {
                result.critics = [CriticReview(outlet: BookReviewSite.nyt.title, byline: "By A. Fixture", published: "2026-05-04",
                                               summary: "A quiet, generous novel about paying attention.",
                                               url: URL(string: "https://www.nytimes.com/2026/05/04/books/review/fixture.html")!)]
            }
        }
        return result
    }

    /// 豆瓣's feed for the fixture book: 26 short reviews, the first page repeating the three
    /// on the book page. With the failure flag, the first request for more does not answer.
    static let doubanTotal = 26
    func moreReaderReviews(_ site: BookReviewSite, url: URL, start: Int) async throws -> ReaderReviewPage {
        try? await Task.sleep(for: .milliseconds(400))
        if UITesting.flag(.bookReviewsFailure), Self.attempts.firstFailure("more|\(url.absoluteString)") { throw BookReviewError.unavailable }
        let shown = ["开篇就把人拉进去，后半段的反转让人忍不住一口气读完。", "设定很有想象力，人物稍显单薄，但不影响好看。", "节奏偏慢，前三十章需要一点耐心。"]
        let feed = shown + (4...Self.doubanTotal).map { "第\($0)条短评：读到这里依然想知道接下来会发生什么。" }
        let page = feed.dropFirst(start).prefix(DoubanComments.pageSize)
        let reviews = page.enumerated().map { ReaderReview(stars: 5 - (start + $0.offset) % 3, text: $0.element, helpful: max(1, 900 - (start + $0.offset) * 30)) }
        let next = start + page.count
        return ReaderReviewPage(reviews: reviews, total: Self.doubanTotal, next: next < Self.doubanTotal ? next : nil)
    }
}
#endif
