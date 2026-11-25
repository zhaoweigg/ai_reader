#if DEBUG
import Foundation

/// Offline 豆瓣, Gutenberg, Apple Books and Open Library lists with invented books; the
/// prize lists are the app's own. The mock catalog has one sure edition for 长河, so a
/// 豆瓣 row can be added at once, and none for the others.
actor UITestBookListClient: BookListServing {
    private var attempts = 0
    func list(_ selection: BookListSelection, offset: Int) async throws -> BookList {
        if selection.chart.isBundled { return PrizeWinners.list(selection) }
        try await Task.sleep(for: .milliseconds(160)); try Task.checkCancellation()
        attempts += 1
        if UITesting.flag(.bookListsFailure), attempts == 1 { throw BookListFeedError.unavailable }
        let rows = Self.rows(selection)
        // Pages of three, so Load more is exercised.
        let page = Array(rows.dropFirst(offset).prefix(3))
        let next = offset + page.count
        return BookList(selection: selection, published: selection.source == .apple ? "Updated Nov 24, 2026" : "", fetchedAt: Date(),
                        books: page.enumerated().map { index, book in var book = book; book.rank = offset + index + 1; return book },
                        next: next < rows.count ? next : nil)
    }
    func download(_ book: ListedBook) async throws -> URL {
        try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation()
        if UITesting.flag(.bookListsFailure), book.bookID == "90002" { throw BookListFeedError.maintenance }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Gutenberg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(book.title + ".txt")
        let text = "\(book.title)\n\n" + String(repeating: "This invented public-domain passage checks that a free list book imports and opens in Leaf. ", count: 80)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    static func rows(_ selection: BookListSelection) -> [ListedBook] {
        switch selection.chart {
        case .doubanTop250:
            return [("长河", "沈从文", 9.4, 120_000, "一条河，几户人家"), ("边城旧事", "林晚", 9.2, 86_000, "渡口边的四季"),
                    ("北方的河", "张承", 9.1, 54_000, "向北，再向北"), ("雾中灯塔", "顾远", 9.0, 31_000, "守灯人的一生")]
                .enumerated().map { index, row in
                    ListedBook(rank: index + 1, bookID: "3000\(index + 1)", title: row.0, author: row.1, source: .douban,
                               detail: "人民文学出版社 · 2012-8", figure: String(format: "%.1f · %@人评价", row.2, ListText.count(row.3)),
                               quote: row.4, rating: row.2, ratingCount: row.3)
                }
        case .doubanLatest:
            return [("春日来信", "许知"), ("海边书店", "白禾")].enumerated().map { index, row in
                ListedBook(rank: index + 1, bookID: "3100\(index + 1)", title: row.0, author: row.1, source: .douban, detail: "2026-11 · 新星出版社")
            }
        case .gutenbergPopular:
            return [("The Lantern Keeper", "Edith Marlowe"), ("A Winter Garden", "Thomas Hale"), ("Letters from the Moor", "Ann Brierley"),
                    ("The Quiet Harbour", "James Penrose")].enumerated().map { index, row in
                ListedBook(rank: index + 1, bookID: "9000\(index + 1)", title: row.0, author: row.1, source: .gutenberg, detail: "English",
                           figure: "\(ListText.count(20_000 - index * 3000)) downloads this month",
                           summary: "An invented public-domain novel used by Leaf's tests.",
                           link: URL(string: "https://www.gutenberg.org/ebooks/9000\(index + 1)"),
                           epub: URL(string: "https://www.gutenberg.org/ebooks/9000\(index + 1).epub3.images"))
            }
        case .appleTopPaid, .appleTopFree:
            let paid = selection.chart == .appleTopPaid
            return [(paid ? "The Glass Orchard" : "Free Sample Stories", "Mira Vale"), (paid ? "Harbor Lights" : "Morning Pages", "Owen Pike")]
                .enumerated().map { index, row in
                    ListedBook(rank: index + 1, bookID: "6000\(index + 1)", title: row.0 + (selection.country == .us ? "" : " (\(selection.country.rawValue.uppercased()))"),
                               author: row.1, source: .apple, detail: "Fiction & Literature · 2026")
                }
        default:
            return [("The Map of Small Hours", "Ruth Calder"), ("Field Notes", "Ian Moss")].enumerated().map { index, row in
                ListedBook(rank: index + 1, bookID: "OL\(index + 1)W", title: row.0, author: row.1, source: .openLibrary,
                           detail: "First published 2019", figure: "\(12 - index) editions")
            }
        }
    }
    nonisolated static func search(_ query: String) -> [ZLibraryBook] {
        guard query.contains("长河") else { return [] }
        return [ZLibraryBook(remoteID: "list-changhe", hash: "fixturechanghe", title: "长河", author: "沈从文", fileExtension: "epub",
                             size: "1.2 MB", language: "Chinese", year: "2012", coverURL: nil, summary: "一条河，几户人家。")]
    }
}
#endif
