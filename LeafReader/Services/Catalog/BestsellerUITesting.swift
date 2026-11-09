#if DEBUG
import Foundation
import UIKit

actor UITestBestsellerClient: BestsellerServing {
    private var attempts: [BestsellerSource: Int] = [:]
    func lists(source: BestsellerSource, apiKey: String?) async throws -> [BestsellerList] {
        try await Task.sleep(for: .milliseconds(160)); try Task.checkCancellation()
        attempts[source, default: 0] += 1
        if UITesting.flag("LEAF_UI_BESTSELLERS_FEED_FAILURE"), attempts[source] == 1 { throw BestsellerFeedError.unavailable }
        return BestsellerGenre.allCases.map { genre in
            let values = Self.samples(genre)
            let ordered = source == .nyt ? Array(values.reversed()) : values
            return BestsellerList(source: source, genre: genre, published: "November 4, 2026", fetchedAt: Date(), books: ordered.enumerated().map { index, b in
                BestsellerBook(source: source, genre: genre, rank: index + 1, title: b.title, author: b.author, summary: b.summary, isbns: b.isbns, sourceURL: b.sourceURL)
            }, relayURL: source == .nyt && apiKey == nil ? BestsellerFeedClient.publicNYTURL(genre) : nil)
        }
    }
    nonisolated static func samples(_ genre: BestsellerGenre = .nonfiction) -> [BestsellerBook] {
        let rows: [(String, String, String)] = genre == .nonfiction ? [
            ("Simply Ina", "Ina Garten", "9780593234174"), ("The American Way of Killing", "Malcolm Gladwell", "9780316603782"),
            ("Blockers", "Michael Lewis", "9781324131656"), ("Abandoning a Cat", "Haruki Murakami", "9798217208692"),
            ("The Rush", "Nathaniel Philbrick", "9780525562238"), ("Sleeping Beauties", "David Byrne", "9780593655276")
        ] : [
            ("A Court of Splintered Harmony", "Sarah J. Maas", "9781639739134"), ("Miss Wolcott’s Ghost", "Louise Penny", "9781250412607"),
            ("The Calamity Club", "Kathryn Stockett", "9781954118812"), ("The Pirate Queen", "Ariel Lawhon", "9780385550345"),
            ("Threshing Day", "Rebecca Yarros", "9781682818084"), ("Peck & Peck", "Bonnie Garmus", "9781668251065")
        ]
        return rows.enumerated().map { index, r in
            BestsellerBook(source: .indie, genre: genre, rank: index + 1, title: r.0, author: r.1,
                           summary: "An offline discovery fixture for \(r.0). It exercises book metadata, edition matching, and returning to the library.",
                           isbns: [r.2], sourceURL: URL(string: "https://www.indiebound.org/book/\(r.2)")!)
        }
    }
    nonisolated static func editions(_ entry: BestsellerBook) -> [ZLibraryBook] {
        let number = entry.genre.rawValue + String(entry.rank)
        let first = ZLibraryBook(remoteID: "best-" + number, hash: "fixture" + number, title: entry.title, author: entry.author,
                                 fileExtension: "txt", size: "18 KB", language: "English", year: "2026", coverURL: nil,
                                 summary: entry.summary, isbns: entry.isbns)
        if entry.title == "The American Way of Killing" || entry.title == "A Court of Splintered Harmony" {
            return [first, ZLibraryBook(remoteID: first.remoteID + "-other", hash: first.hash + "other", title: first.title, author: first.author,
                                        fileExtension: "txt", size: "22 KB", language: "English", year: "2025", coverURL: nil, summary: entry.summary)]
        }
        return [first]
    }
    nonisolated static func search(_ query: String) -> [ZLibraryBook] {
        let normalized = BestsellerText.normalized(query)
        return (samples() + samples(.fiction)).flatMap { entry -> [ZLibraryBook] in
            if entry.title == "The Rush", normalized != "the rush" { return [] }
            guard entry.isbns.contains(query) || normalized.contains(BestsellerText.normalized(entry.title)) || BestsellerText.normalized(entry.title).contains(normalized) else { return [] }
            return editions(entry)
        }
    }
    @MainActor static func cover(_ entry: BestsellerBook) -> UIImage? {
        guard let isbn = entry.isbns.first, let root = Bundle.main.url(forResource: "Samples", withExtension: nil) else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent("BestsellerFixtures/\(isbn).jpg").path)
    }
    nonisolated static func download(_ book: ZLibraryBook, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        progress(0.15); try await Task.sleep(for: .milliseconds(UITesting.flag("LEAF_UI_BESTSELLERS_SLOW_DOWNLOAD") ? 8_000 : 800)); try Task.checkCancellation()
        if UITesting.flag("LEAF_UI_BESTSELLERS_DOWNLOAD_FAILURE") { throw ZLibraryError.service("The fixture download failed. Try again.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let text = "\(book.title)\n\n" + String(repeating: "This original Leaf test passage checks that a discovered book imports and opens with its own saved reading position. ", count: 90)
        try text.write(to: url, atomically: true, encoding: .utf8); progress(1); return url
    }
}
#endif
