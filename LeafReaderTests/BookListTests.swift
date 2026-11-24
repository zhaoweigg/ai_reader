import XCTest
@testable import LeafReader

private actor ListPages: BookListServing {
    var offsets: [Int] = []
    var fail = false
    func setFailing(_ value: Bool) { fail = value }
    /// Gutendex-like pages of four rows, of which the source skips one, for twelve rows in all;
    /// the second page repeats the last book of the first.
    func list(_ selection: BookListSelection, offset: Int) async throws -> BookList {
        offsets.append(offset)
        if fail { throw BookListFeedError.maintenance }
        let ids = offset == 0 ? ["1", "2", "3"] : offset == 4 ? ["3", "5", "6"] : ["9", "10", "11"]
        let books = ids.enumerated().map { index, id in
            ListedBook(rank: offset + index + 1, bookID: id, title: "Book \(id)", author: "Author", source: selection.source)
        }
        return BookList(selection: selection, published: "", fetchedAt: Date(), books: books, next: offset + 4 < 12 ? offset + 4 : nil)
    }
    func download(_ book: ListedBook) async throws -> URL { throw BookListFeedError.unavailable }
}

@MainActor final class BookListTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "BookListTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Discover lists arrangement

    func testDiscoverStartsWithTodaysListsThen豆瓣AndGutenbergAndKeepsOneListOn() {
        let store = DiscoverListsStore(defaults: defaults())
        XCTAssertEqual(store.shown, [.popular, .recommended, .nyt, .indie, .qidian, .weread, .douban, .gutenberg])
        XCTAssertEqual(store.hidden, [.apple, .prizes, .openLibrary])
        for list in store.shown.dropFirst() { store.setShown(list, false) }
        XCTAssertEqual(store.shown, [.popular])
        store.setShown(.popular, false)
        XCTAssertEqual(store.shown, [.popular], "the last list cannot be hidden")
        store.setShown(.prizes, true)
        XCTAssertEqual(store.shown, [.popular, .prizes], "a list switched on goes to the end")
    }

    func testArrangementIsSavedSyncedAndReadBackWithUnknownAndNewListsHandled() {
        let d = defaults(), store = DiscoverListsStore(defaults: d)
        store.setShown(.apple, true); store.setShown(.nyt, false)
        store.move(from: IndexSet(integer: store.shown.firstIndex(of: .apple)!), to: 0)
        XCTAssertEqual(store.shown.first, .apple)
        let saved = d.stringArray(forKey: DiscoverListsStore.key)
        XCTAssertEqual(saved?.first, "apple"); XCTAssertTrue(saved?.contains("-nyt") == true)
        XCTAssertTrue(SyncedSettings.keys.contains(DiscoverListsStore.key), "the arrangement syncs")
        XCTAssertFalse(SyncedSettings.keys.contains(DiscoverListsStore.selectedKey), "the last chip is this device's")
        XCTAssertEqual(DiscoverListsStore(defaults: d).shown, store.shown)

        // A list this version does not know is dropped; a list the saved value never mentioned keeps its initial place.
        let read = DiscoverListsStore.arrangement(["prizes", "-popular", "jjwxc", "prizes"])
        XCTAssertEqual(read.shown.first, .prizes)
        XCTAssertTrue(read.hidden.contains(.popular)); XCTAssertTrue(read.shown.contains(.douban)); XCTAssertTrue(read.hidden.contains(.apple))
        XCTAssertEqual(Set(read.shown + read.hidden).count, DiscoverList.allCases.count)
        XCTAssertEqual(DiscoverListsStore.arrangement(DiscoverList.allCases.map { "-" + $0.rawValue }).shown.count, 1, "never none")
    }

    func testAnotherDevicesArrangementAppliesAsSoonAsItArrives() {
        let d = defaults(), store = DiscoverListsStore(defaults: d)
        d.set(["douban", "qidian", "-popular"], forKey: DiscoverListsStore.key)
        XCTAssertEqual(Array(store.shown.prefix(2)), [.douban, .qidian])
        XCTAssertTrue(store.hidden.contains(.popular))
        store.remember(.qidian); XCTAssertEqual(store.remembered, .qidian)
        store.setShown(.qidian, false); XCTAssertNil(store.remembered, "a hidden list is not reopened")
    }

    // MARK: Parsers

    func testDoubanTop250ReadsTitleAuthorScoreAndOneLineAndPagesTo250() throws {
        let row = #"""
        <tr class="item"><td><a class="nbg" href="https://book.douban.com/subject/1007305/"><img src="https://img3.doubanio.com/view/subject/s/public/s1070959.jpg" width="90" /></a></td>
        <td><div class="pl2"><a href="https://book.douban.com/subject/1007305/" onclick=&#34;moreurl(this)&#34; title="红楼梦">红楼梦</a></div>
        <p class="pl">(清)曹雪芹 / 人民文学出版社 / 1982-3 / 59.70元</p>
        <div class="star clearfix"><span class="allstar50"></span><span class="rating_nums">9.7</span><span class="pl">(
            471956人评价
        )</span></div><p class="quote"><span class="inq">都云作者痴，谁解其中味？</span></p></td></tr>
        """#
        let other = row.replacingOccurrences(of: "1007305", with: "4913064").replacingOccurrences(of: "红楼梦", with: "活着")
        let page = (0..<25).map { $0 == 1 ? other : row.replacingOccurrences(of: "1007305", with: "\(2000 + $0)") }.joined()
        let list = try DoubanLists.parseTop250(Data(page.utf8), selection: BookListSelection(chart: .doubanTop250), offset: 25)
        let first = try XCTUnwrap(list.books.first)
        XCTAssertEqual(first.rank, 26); XCTAssertEqual(first.title, "红楼梦"); XCTAssertEqual(first.author, "(清)曹雪芹")
        XCTAssertEqual(first.detail, "人民文学出版社 · 1982-3", "the price stays on 豆瓣")
        XCTAssertEqual(first.figure, "9.7 · 471,956人评价"); XCTAssertEqual(first.quote, "都云作者痴，谁解其中味？")
        XCTAssertEqual(first.cover?.host, "img3.doubanio.com"); XCTAssertEqual(first.link?.absoluteString, "https://book.douban.com/subject/2000/")
        XCTAssertEqual(list.books[1].title, "活着"); XCTAssertEqual(list.next, 50)
        let translated = row.replacingOccurrences(of: "(清)曹雪芹 / 人民文学出版社 / 1982-3 / 59.70元", with: "[英] J·K·罗琳 / 苏农 / 人民文学出版社 / 2008-12-1 / 498.00元")
        let harry = try DoubanLists.parseTop250(Data(translated.utf8), selection: BookListSelection(chart: .doubanTop250), offset: 0)
        XCTAssertEqual(harry.books[0].detail, "人民文学出版社 · 2008-12-1", "the translator stays on 豆瓣")
        XCTAssertTrue(first.isChinese)
        let last = try DoubanLists.parseTop250(Data(page.utf8), selection: BookListSelection(chart: .doubanTop250), offset: 225)
        XCTAssertNil(last.next, "Top 250 ends at 250")
        XCTAssertThrowsError(try DoubanLists.parseTop250(Data("<html>请登录</html>".utf8), selection: BookListSelection(chart: .doubanTop250), offset: 0))
    }

    func testDouban新书速递ReadsItsCardsAndFollowsThePaginator() throws {
        let card = #"""
        <li class="media clearfix"><div class="media__img"><a href="https://book.douban.com/subject/38612696/"><img class="subject-cover" src="https://img3.doubanio.com/view/subject/s/public/s35616557.jpg"/></a></div>
        <div class="media__body"><h2 class="clearfix"><a class="fleft" href="https://book.douban.com/subject/38612696/">绿色密封蜡</a></h2>
        <p class="subject-abstract color-gray">
            [法]柯莱特 / 2026-9 / 海峡文艺出版社 / 38.00 / 平装
        </p><p class="clearfix w250 subject-rating"><span class="font-small fleft">8.2</span><span class="fleft ml8 color-gray">(33人评价)</span></p></div></li>
        """#
        let cards = (0..<20).map { card.replacingOccurrences(of: "38612696", with: "\(500 + $0)") }.joined()
        let html = cards + #"<div class="paginator"><a href="?subcat=全部&amp;p=2&amp;updated_at=">2</a></div>"#
        let list = try DoubanLists.parseLatest(Data(html.utf8), selection: BookListSelection(chart: .doubanLatest), offset: 0)
        XCTAssertEqual(list.books.count, 20); XCTAssertEqual(list.next, 20)
        let book = list.books[0]
        XCTAssertEqual(book.title, "绿色密封蜡"); XCTAssertEqual(book.author, "[法]柯莱特")
        XCTAssertEqual(book.detail, "2026-9 · 海峡文艺出版社"); XCTAssertEqual(book.figure, "8.2 · 33人评价")
        XCTAssertNil(try DoubanLists.parseLatest(Data(cards.utf8), selection: BookListSelection(chart: .doubanLatest), offset: 20).next,
                     "no next page without a link to it")
        let shortPage = cards.components(separatedBy: #"<li class="media clearfix">"#).dropFirst(2).map { #"<li class="media clearfix">"# + $0 }.joined()
            + #"<a href="?subcat=全部&amp;p=2&amp;updated_at=">2</a>"#
        XCTAssertEqual(try DoubanLists.parseLatest(Data(shortPage.utf8), selection: BookListSelection(chart: .doubanLatest), offset: 0).next, 20,
                       "a page of nineteen still leads to the next twenty places")
    }

    func testGutenbergKeepsBooksWithAnEPUBAndNamesAuthorsTheUsualWay() throws {
        let json = #"""
        {"count": 3, "next": "https://gutendex.com/books/?page=2&sort=popular", "results": [
          {"id": 1342, "title": "Pride and Prejudice", "authors": [{"name": "Austen, Jane"}], "languages": ["en"], "media_type": "Text",
           "summaries": ["A novel of manners. (This is an automatically generated summary.)"], "download_count": 208430,
           "formats": {"application/epub+zip": "https://www.gutenberg.org/ebooks/1342.epub3.images", "image/jpeg": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg"}},
          {"id": 9, "title": "A Sound Recording", "authors": [], "languages": ["en"], "media_type": "Sound", "formats": {}},
          {"id": 84, "title": "Frankenstein", "authors": [{"name": "Shelley, Mary Wollstonecraft"}], "languages": ["en", "fr"], "media_type": "Text",
           "formats": {"application/epub+zip": "https://www.gutenberg.org/ebooks/84.epub3.images"}}
        ]}
        """#
        let list = try GutenbergList.parse(Data(json.utf8), selection: BookListSelection(chart: .gutenbergPopular), offset: 0)
        XCTAssertEqual(list.books.map(\.title), ["Pride and Prejudice", "Frankenstein"])
        XCTAssertEqual(list.books.map(\.rank), [1, 2])
        XCTAssertEqual(list.books[0].author, "Jane Austen"); XCTAssertEqual(list.books[1].author, "Mary Wollstonecraft Shelley")
        XCTAssertEqual(list.books[0].summary, "A novel of manners.")
        XCTAssertEqual(list.books[0].figure, "208,430 downloads this month")
        XCTAssertEqual(list.books[1].detail, "English, French")
        XCTAssertEqual(list.books[0].gutenbergSource, "gutenberg:1342")
        XCTAssertEqual(list.next, 3, "the next page starts after every row the source sent, kept or not")
        XCTAssertEqual(GutenbergList.name("Plato"), "Plato")
        XCTAssertEqual(GutenbergList.name("Smollett, T. (Tobias)"), "Tobias Smollett")
    }

    func testAppleBooksReadsItsStoresChartAndAsksForLargerArtwork() throws {
        let json = #"""
        {"feed": {"country": "gb", "updated": "Tue, 24 Nov 2026 21:28:31 +0000", "results": [
          {"artistName": "Suzanne Collins", "id": "6504027655", "name": "Sunrise on the Reaping", "releaseDate": "2025-03-18",
           "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/Publication221/v4/b2/9781546171478.jpg/100x152bb.png",
           "genres": [{"name": "Books"}, {"name": "Dystopian Fiction for Young Adults"}], "url": "https://books.apple.com/gb/book/id6504027655"}
        ]}}
        """#
        let selection = BookListSelection(chart: .appleTopPaid, country: .gb)
        let list = try AppleBooksList.parse(Data(json.utf8), selection: selection)
        let book = try XCTUnwrap(list.books.first)
        XCTAssertEqual(book.author, "Suzanne Collins"); XCTAssertEqual(book.detail, "Dystopian Fiction for Young Adults · 2025")
        XCTAssertTrue(book.cover?.absoluteString.hasSuffix("/300x456bb.png") == true)
        XCTAssertTrue(list.published.hasPrefix("Updated"))
        XCTAssertEqual(selection.requestURL(offset: 0)?.absoluteString, "https://rss.marketingtools.apple.com/api/v2/gb/books/top-paid/50/books.json")
        XCTAssertThrowsError(try AppleBooksList.parse(Data(json.utf8), selection: BookListSelection(chart: .appleTopPaid, country: .us)),
                             "another store's chart is not shown as this one")
        XCTAssertEqual(BookListSelection(chart: .doubanTop250, country: .jp).country, .us, "only Apple's charts depend on the store")
        let empty = #"{"feed": {"country": "tw", "results": []}}"#
        XCTAssertThrowsError(try AppleBooksList.parse(Data(empty.utf8), selection: BookListSelection(chart: .appleTopPaid, country: .tw))) {
            XCTAssertEqual($0 as? BookListFeedError, .noChart)
        }
    }

    func testOpenLibraryTrendingReadsWorksCoversAndAnISBN() throws {
        let json = #"""
        {"works": [{"key": "/works/OL17930368W", "title": "Atomic Habits", "author_name": ["James Clear"], "cover_i": 12539702,
                    "edition_count": 42, "first_publish_year": 2016,
                    "editions": {"docs": [{"availability": {"isbn": "9781847941831"}}]}},
                   {"key": "/works/OL17930368W", "title": "Atomic Habits", "author_name": ["James Clear"]},
                   {"key": "/authors/OL1A", "title": "Not a work"}]}
        """#
        let list = try OpenLibraryList.parse(Data(json.utf8), selection: BookListSelection(chart: .openLibraryWeekly))
        XCTAssertEqual(list.books.count, 1)
        let book = list.books[0]
        XCTAssertEqual(book.figure, "42 editions"); XCTAssertEqual(book.detail, "First published 2016")
        XCTAssertEqual(book.cover?.absoluteString, "https://covers.openlibrary.org/b/id/12539702-M.jpg")
        XCTAssertEqual(book.isbns, ["9781847941831"]); XCTAssertFalse(book.isChinese)
    }

    func testEveryPrizeListHasWinnersNewestFirst() {
        for chart in BookListSource.prizes.charts {
            let list = PrizeWinners.list(BookListSelection(chart: chart))
            XCTAssertGreaterThan(list.books.count, 10, chart.title)
            let years = list.books.compactMap(\.year)
            XCTAssertEqual(years.count, list.books.count, chart.title)
            XCTAssertEqual(years, years.sorted(by: >), chart.title)
            XCTAssertTrue(list.books.allSatisfy { !$0.title.isEmpty && !$0.author.isEmpty }, chart.title)
            XCTAssertEqual(Set(list.books.map(\.bookID)).count, list.books.count, chart.title)
        }
        let booker = PrizeWinners.list(BookListSelection(chart: .booker))
        XCTAssertEqual(booker.books.first?.title, "The End of Everything"); XCTAssertEqual(booker.books.first?.figure, "Won 2026")
        let maoDun = PrizeWinners.list(BookListSelection(chart: .maoDun))
        XCTAssertTrue(maoDun.books.contains { $0.title == "平凡的世界" && $0.year == 1991 })
        XCTAssertTrue(maoDun.books[0].isChinese); XCTAssertFalse(booker.books[0].isChinese)
    }

    // MARK: Store

    func testLoadMoreNumbersBooksInOrderSkipsRepeatsAndStopsAtTheEnd() async throws {
        let d = defaults(), service = ListPages(), store = BookListStore(defaults: d, service: service)
        store.show(.gutenberg)
        await store.load()
        XCTAssertEqual(store.books.map(\.bookID), ["1", "2", "3"]); XCTAssertTrue(store.canLoadMore)
        await store.loadMore()
        XCTAssertEqual(store.books.map(\.bookID), ["1", "2", "3", "5", "6"], "a book already shown is not listed twice")
        XCTAssertEqual(store.books.map(\.rank), [1, 2, 3, 4, 5])
        await store.loadMore()
        XCTAssertEqual(store.books.count, 8); XCTAssertFalse(store.canLoadMore)
        let offsets = await service.offsets
        XCTAssertEqual(offsets, [0, 4, 8], "each page starts where the source's last one ended")

        // Kept between launches, and not asked again while fresh.
        let reopened = BookListStore(defaults: d, service: service)
        XCTAssertEqual(reopened.source, .gutenberg)
        await reopened.load()
        XCTAssertEqual(reopened.books.count, 8)
        let after = await service.offsets
        XCTAssertEqual(after.count, 3)

        // A failure keeps the list shown and says why.
        await service.setFailing(true)
        await reopened.load(force: true)
        XCTAssertEqual(reopened.books.count, 8); XCTAssertEqual(reopened.error, BookListFeedError.maintenance.errorDescription)
    }

    func testEachSourceKeepsItsListAndPrizesNeedNoRequest() async {
        let d = defaults(), service = ListPages(), store = BookListStore(defaults: d, service: service)
        store.show(.prizes); store.chart = .hugo
        await store.load()
        XCTAssertEqual(store.books.first?.title, "The Everlasting")
        let offsets = await service.offsets
        XCTAssertTrue(offsets.isEmpty)
        store.show(.douban); store.chart = .doubanLatest
        store.show(.prizes); XCTAssertEqual(store.chart, .hugo)
        XCTAssertEqual(BookListStore(defaults: d, service: service).chart, .hugo)
        store.show(.douban); XCTAssertEqual(store.chart, .doubanLatest)
    }

    func testDiscoverChipsDriveEachListsStore() {
        let d = defaults(), credentials = KeychainChatCredentials(service: "com.leafreader.tests.\(UUID())")
        let catalog = ZLibraryStore(defaults: d, credentials: credentials, client: UITestZLibraryClient(), discoversFromLibrary: false)
        let bestsellers = BestsellerStore(defaults: d, credentials: credentials, service: UITestBestsellerClient(), allowsAutomaticShelf: false)
        let novels = WebNovelStore(defaults: d, service: UITestWebNovelClient()), lists = BookListStore(defaults: d, service: ListPages())
        for list in DiscoverList.allCases {
            list.show(catalog: catalog, bestsellers: bestsellers, novels: novels, lists: lists)
            XCTAssertEqual(DiscoverList.current(catalog: catalog, bestsellers: bestsellers, novels: novels, lists: lists), list)
            XCTAssertEqual([bestsellers.showingBestsellers, novels.showing, lists.showing].filter { $0 }.count, [.popular, .recommended].contains(list) ? 0 : 1)
        }
    }

    func testAskLeafReadsTheListOnScreenAndTheOpenBook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root, seedSamples: false), d = defaults()
        let credentials = KeychainChatCredentials(service: "com.leafreader.tests.\(UUID())")
        let catalog = ZLibraryStore(defaults: d, credentials: credentials, client: UITestZLibraryClient(), discoversFromLibrary: false)
        let lists = BookListStore(defaults: d, service: UITestBookListClient())
        lists.show(.douban); await lists.load()
        let screen = ChatScreen.discover(catalog, library: library, bookLists: lists)
        let view = screen.view(2, true)
        XCTAssertEqual(view["source"] as? String, "豆瓣读书"); XCTAssertEqual(view["list"] as? String, "豆瓣读书 Top 250")
        XCTAssertEqual((view["items"] as? [[String: Any]])?.map { $0["title"] as? String }, ["长河", "边城旧事"])
        XCTAssertEqual((view["items"] as? [[String: Any]])?.first?["one_line"] as? String, "一条河，几户人家")
        XCTAssertEqual(view["more_available"] as? Bool, true)
        let second = try await screen.details(2, true)
        XCTAssertEqual(second?["title"] as? String, "边城旧事")
        lists.show(.prizes); lists.chart = .booker; await lists.load()
        let prizes = ChatScreen.discover(catalog, library: library, bookLists: lists).view(1, true)
        XCTAssertEqual((prizes["items"] as? [[String: Any]])?.first?["year_won"] as? Int, 2026)
        XCTAssertNotNil(prizes["note"])
        lists.show(.gutenberg); await lists.load(); lists.viewingBook = lists.books.first
        let open = ChatScreen.discover(catalog, library: library, bookLists: lists).view(1, true)["open_book"] as? [String: Any]
        XCTAssertEqual(open?["title"] as? String, "The Lantern Keeper"); XCTAssertNotNil(open?["free_epub"])
    }
}
