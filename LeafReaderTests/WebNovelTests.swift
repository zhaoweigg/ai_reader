import XCTest
@testable import LeafReader

private actor ChartPages: WebNovelServing {
    var calls: [WebNovelSelection] = []
    var offsets: [Int] = []
    var fail = false
    /// The chart moved between two requests: the next page starts with the last book already shown.
    var repeatsABook = false
    func setFailing(_ value: Bool) { fail = value }
    func setRepeatsABook(_ value: Bool) { repeatsABook = value }
    func list(_ selection: WebNovelSelection, offset: Int) async throws -> WebNovelList {
        calls.append(selection); offsets.append(offset)
        if fail { throw WebNovelFeedError.invalidResponse }
        guard selection.source == .weread else {
            let novel = WebNovel(rank: 1, bookID: "\(calls.count)", title: selection.caption, author: "作者", category: "仙侠", subcategory: "",
                                 length: "10万字", figure: "", summary: "")
            return WebNovelList(selection: selection, published: "", fetchedAt: Date(), books: [novel])
        }
        // 微信读书 serves 20 books a request for as long as the chart goes on (here, 200).
        let books = (1...20).map { place -> WebNovel in
            let rank = offset + place, repeated = repeatsABook && offset > 0 && place == 1
            return WebNovel(rank: rank, bookID: "b\(repeated ? rank - 1 : rank)", title: "书\(rank)", author: "作者", category: "文学", subcategory: "",
                            length: "", figure: "", summary: "", source: .weread)
        }
        return WebNovelList(selection: selection, published: "", fetchedAt: Date(), books: books, hasMore: offset + 20 < 200)
    }
}

@MainActor final class WebNovelTests: XCTestCase {
    /// A chart page as 起点's mobile site serves it: the data sits in one JSON script.
    private func page(chart: String = "yuepiao", category: Int = -1, period: Int? = nil, month: String? = "202611", pageNumber: Int = 1,
                      total: Int = 1000, rows: [[String: Any]]? = nil) -> Data {
        let records = rows ?? (1...20).map { row($0) }
        var filters: [[String: Any]] = [["key": "catId", "selectedIndex": category == -1 ? 0 : 1,
                                         "items": [["text": "全站", "value": -1], ["text": "仙侠", "value": 22]]]]
        if let month { filters.append(["key": "yearmonth", "selectedIndex": 0, "items": [["text": "当月", "value": month], ["text": "10月", "value": "202610"]]]) }
        if let period {
            let items: [[String: Any]] = [["text": "周榜", "value": 3], ["text": "月榜", "value": 2], ["text": "总榜", "value": 1]]
            filters.append(["key": "rankPeriod", "selectedIndex": items.firstIndex { $0["value"] as? Int == period } ?? 0, "items": items])
        }
        let context: [String: Any] = ["pageContext": [
            "routeParams": ["pageType": chart, "gender": "male"],
            "pageProps": ["pageData": ["total": total, "pageNum": pageNumber, "records": records, "filters": filters]]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        return Data("<html><body><div id=\"app\"></div><script id=\"vite-plugin-ssr_pageContext\" type=\"application/json\">\(json)</script></body></html>".utf8)
    }
    private func row(_ rank: Int, id: String? = nil, title: String? = nil) -> [String: Any] {
        ["rankNum": rank, "bid": id ?? "10\(rank)", "bName": title ?? "书名\(rank)", "bAuth": "作者\(rank)", "cat": "仙侠", "subCat": "修真文明",
         "cnt": "\(rank)0.5万字", "rankCnt": "\(21 - rank)万月票", "desc": "  简介\(rank)  ", "catId": 22]
    }
    private func defaults() -> UserDefaults {
        let name = "LeafWebNovels.\(UUID())", d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }; return d
    }
    private func novel(_ title: String = "诡秘之主", author: String = "爱潜水的乌贼") -> WebNovel {
        WebNovel(rank: 1, bookID: "1010868264", title: title, author: author, category: "玄幻", subcategory: "", length: "446万字", figure: "", summary: "")
    }
    private func edition(_ id: String, _ title: String, _ author: String, format: String = "txt") -> ZLibraryBook {
        ZLibraryBook(remoteID: id, hash: id, title: title, author: author, fileExtension: format, size: "1 MB", language: "Chinese", year: "2020", coverURL: nil)
    }

    func testChartPageGivesTheFullRankingWithItsMonthCoverAndBookAddress() throws {
        let list = try QidianChart.parse(page(), selection: WebNovelSelection())
        XCTAssertEqual(list.books.map(\.rank), Array(1...20))
        XCTAssertEqual(list.published, "2026年11月")
        let first = try XCTUnwrap(list.books.first)
        XCTAssertEqual([first.title, first.author, first.category, first.subcategory, first.length, first.figure, first.summary],
                       ["书名1", "作者1", "仙侠", "修真文明", "10.5万字", "20万月票", "简介1"])
        XCTAssertEqual(first.byline, "作者1 · 仙侠 · 10.5万字")
        XCTAssertEqual(first.coverURL?.absoluteString, "https://bookcover.yuewen.com/qdbimg/349573/101/180")
        XCTAssertEqual(first.sourceURL.absoluteString, "https://m.qidian.com/book/101/")

        // A small category has fewer than a page of books; that is a whole chart, not a cut-off one.
        let small = WebNovelSelection(chart: .recommended, category: 22, period: .allTime)
        let short = try QidianChart.parse(page(chart: "rec", category: 22, period: 1, month: nil, total: 3, rows: (1...3).map { row($0) }), selection: small)
        XCTAssertEqual(short.books.count, 3); XCTAssertEqual(short.published, "")
    }

    func testAPageThatIsNotTheChartAskedForOrIsIncompleteIsRejected() {
        func rejected(_ data: Data, _ reason: String, _ selection: WebNovelSelection = WebNovelSelection(), line: UInt = #line) {
            XCTAssertThrowsError(try QidianChart.parse(data, selection: selection), reason, line: line) {
                XCTAssertEqual($0 as? WebNovelFeedError, .invalidResponse, line: line)
            }
        }
        rejected(Data("<html><script src=\"/probe.js\"></script></html>".utf8), "the site's browser check")
        rejected(page(chart: "hotsales"), "another chart")
        rejected(page(category: 22), "another category")
        rejected(page(chart: "rec", period: 2, month: nil), "another period", WebNovelSelection(chart: .recommended, period: .week))
        rejected(page(pageNumber: 2), "a later page")
        rejected(page(rows: (1...19).map { row($0) }), "a cut-off chart")
        rejected(page(rows: (1...20).map { row($0 == 7 ? 8 : $0) }), "a gap in the ranks")
        rejected(page(rows: (1...20).map { row($0, id: $0 == 5 ? "104" : nil) }), "the same book twice")
        rejected(page(rows: (1...20).map { row($0, id: $0 == 5 ? "../x" : nil) }), "an identifier that is not a number")
        rejected(page(rows: (1...20).map { row($0, title: $0 == 5 ? "  " : nil) }), "a book without a title")
        rejected(page(total: 0, rows: []), "an empty chart")
    }

    func testEachChartCategoryAndPeriodHasItsOwnAddress() {
        XCTAssertEqual(WebNovelSelection().requestURL().absoluteString, "https://m.qidian.com/rank/yuepiao/catid-1/")
        XCTAssertEqual(WebNovelSelection(chart: .sales, category: 9).requestURL().absoluteString, "https://m.qidian.com/rank/hotsales/catid9/")
        XCTAssertEqual(WebNovelSelection(chart: .recommended, category: 22, period: .allTime).requestURL().absoluteString, "https://m.qidian.com/rank/rec/catid22/1/")
        // 微信读书 serves data 20 books at a time and has a page of its own for the reader; it has no categories or periods here.
        let acclaimed = WebNovelSelection(chart: .acclaimed, category: 22, period: .month)
        XCTAssertEqual(acclaimed, WebNovelSelection(chart: .acclaimed)); XCTAssertEqual(acclaimed.source, .weread); XCTAssertEqual(acclaimed.caption, "神作榜")
        XCTAssertEqual(acclaimed.requestURL(offset: 40).absoluteString, "https://weread.qq.com/web/bookListInCategory/newrating_publish?maxIndex=40&rank=1")
        XCTAssertEqual(acclaimed.pageURL.absoluteString, "https://weread.qq.com/web/category/newrating_publish")
        XCTAssertEqual(WebNovelSource.weread.charts.map(\.shortTitle), ["总榜", "飙升", "新书", "神作"])
        XCTAssertEqual(WebNovelSource.qidian.charts.map(\.shortTitle), ["月票", "畅销", "阅读指数", "推荐票"])
        // Only 推荐票榜 has periods, and a category the site does not list means 全站.
        XCTAssertEqual(WebNovelSelection(chart: .reading, category: 31337, period: .month), WebNovelSelection(chart: .reading))
        XCTAssertEqual(WebNovelSelection(chart: .recommended, period: .month).caption, "推荐票榜 · 月榜 · 全站")
    }

    /// 微信读书's chart data: 20 books from `offset`, each with its place, rating, readers, cover and page.
    private func wereadPage(offset: Int = 0, count: Int = 20, hasMore: Int = 1, change: (Int, inout [String: Any], inout [String: Any]) -> Void = { _, _, _ in }) -> Data {
        let books = (1...max(count, 1)).prefix(count).map { place -> [String: Any] in
            let rank = offset + place
            var info: [String: Any] = ["bookId": "69\(rank)", "title": "书名\(rank)（全三册）", "author": "[英]作者\(rank)", "category": "精品小说-科幻小说",
                                       "intro": "【获奖】\n  简介\(rank)  ", "newRating": 930, "newRatingCount": 100,
                                       "cover": "https://cdn.weread.qq.com/weread/cover/80/t6_\(rank).jpg",
                                       "deepLink": "https://weread.qq.com/book-detail?type=1&v=abc\(rank)"]
            var row: [String: Any] = ["searchIdx": rank, "readingCount": rank == 1 ? 10618 : 969]
            change(rank, &row, &info); row["bookInfo"] = info
            return row
        }
        return try! JSONSerialization.data(withJSONObject: ["books": books, "hasMore": hasMore, "totalCount": offset + count + 20])
    }
    func testWeReadPageGivesRatingReadersCoverAndBookPageAndContinuesTheRanking() throws {
        let top = WebNovelSelection(chart: .top)
        let first = try WeReadChart.parse(wereadPage(), selection: top)
        XCTAssertEqual(first.books.map(\.rank), Array(1...20)); XCTAssertTrue(first.hasMore); XCTAssertEqual(first.published, "")
        let book = try XCTUnwrap(first.books.first)
        XCTAssertEqual([book.title, book.author, book.category, book.subcategory, book.length, book.summary],
                       ["书名1（全三册）", "[英]作者1", "科幻小说", "精品小说", "", "【获奖】 简介1"])
        XCTAssertEqual(book.figure, "93.0% 推荐 · 今日 1.1万人在读"); XCTAssertEqual(first.books[1].figure, "93.0% 推荐 · 今日 969人在读")
        XCTAssertEqual(book.byline, "[英]作者1 · 科幻小说"); XCTAssertEqual(book.id, "weread:691"); XCTAssertEqual(book.source, .weread)
        XCTAssertEqual(book.coverURL?.absoluteString, "https://cdn.weread.qq.com/weread/cover/80/t6_1.jpg")
        XCTAssertEqual(book.sourceURL.absoluteString, "https://weread.qq.com/book-detail?type=1&v=abc1")

        // The next request continues where the first stopped; the last page may be short.
        let last = try WeReadChart.parse(wereadPage(offset: 180, count: 7, hasMore: 0), selection: top, offset: 180)
        XCTAssertEqual(last.books.map(\.rank), Array(181...187)); XCTAssertFalse(last.hasMore)

        // A cover or book page that is not on the site's own hosts is left out, not followed.
        let foreign = try WeReadChart.parse(wereadPage { rank, _, info in
            if rank == 1 { info["cover"] = "https://covers.example/1.jpg"; info["deepLink"] = "http://weread.qq.com/x" }
            if rank == 2 { info["cover"] = "https://wfqqreader-1252317822.image.myqcloud.com/cover/2.jpg"; info["newRating"] = 0 }
        }, selection: top)
        XCTAssertNil(foreign.books[0].coverURL); XCTAssertEqual(foreign.books[0].sourceURL.absoluteString, "https://weread.qq.com/")
        XCTAssertEqual(foreign.books[1].coverURL?.host, "wfqqreader-1252317822.image.myqcloud.com")
        XCTAssertEqual(foreign.books[1].figure, "今日 969人在读", "a book not yet rated shows only its readers")
    }
    func testWeReadDataThatIsNotTheNextFullPageIsRejected() {
        func rejected(_ data: Data, _ reason: String, offset: Int = 0, line: UInt = #line) {
            XCTAssertThrowsError(try WeReadChart.parse(data, selection: WebNovelSelection(chart: .rising), offset: offset), reason, line: line) {
                XCTAssertEqual($0 as? WebNovelFeedError, .invalidResponse, line: line)
            }
        }
        rejected(Data("<html>请先登录</html>".utf8), "a page instead of data")
        rejected(wereadPage(offset: 20), "a page from somewhere else in the chart")
        rejected(wereadPage(), "the first page again", offset: 20)
        rejected(wereadPage(count: 12), "a short page that claims there is more")
        rejected(wereadPage(count: 0, hasMore: 0), "no books")
        rejected(wereadPage { rank, row, _ in if rank == 5 { row["searchIdx"] = 9 } }, "a gap in the places")
        rejected(wereadPage { rank, _, info in if rank == 5 { info["bookId"] = "694" } }, "the same book twice")
        rejected(wereadPage { rank, _, info in if rank == 5 { info["bookId"] = "../x" } }, "an identifier with other characters")
        rejected(wereadPage { rank, _, info in if rank == 5 { info["author"] = " " } }, "a book without an author")
    }

    func testUploadsOfTheSameNovelMatchWhileSequelsAndUncreditedCopiesNeedChecking() {
        let ranked = WebNovelText.rank(novel(), editions: [
            edition("wrapped", "《诡秘之主》（精校版）作者：爱潜水的乌贼", "爱潜水的乌贼"),
            edition("credited", "诡秘之主【全本】", "[中] 爱潜水的乌贼 著", format: "epub"),
            edition("sequel", "诡秘之主2：宿命之环", "爱潜水的乌贼"),
            edition("nameless", "诡秘之主", ""),
            edition("other-author", "诡秘之主", "别人"),
            edition("other-book", "长夜余火", "爱潜水的乌贼"),
            edition("wrapped", "《诡秘之主》（精校版）作者：爱潜水的乌贼", "爱潜水的乌贼")])
        XCTAssertEqual(ranked.map(\.book.remoteID), ["credited", "wrapped", "nameless", "sequel"], "sure matches first, EPUB before TXT; no duplicates")
        XCTAssertEqual(ranked.map(\.confidence), [.titleAndAuthor, .titleAndAuthor, .possible, .possible])
        // One sure edition can be added at once; a lone sequel or uncredited copy cannot.
        XCTAssertNotNil(BestsellerMatchState.ready(Array(ranked.prefix(1))).automatic)
        XCTAssertNil(BestsellerMatchState.ready(Array(ranked.suffix(1))).automatic)
        XCTAssertTrue(WebNovelText.rank(novel("1984：从川菜馆开始", author: "轻语江湖"), editions: [edition("colon", "1984:从川菜馆开始", "轻语江湖")]).first?.confidence == .titleAndAuthor)

        // 微信读书's own notes come off too: a set's （全三册）, 全集, and the country before a translated author.
        let set = WebNovelText.rank(novel("三体全集（全三册）", author: "刘慈欣"), editions: [edition("plain", "三体", "刘慈欣"), edition("whole", "三体全集", "刘慈欣")])
        XCTAssertEqual(set.map(\.confidence), [.titleAndAuthor, .titleAndAuthor])
        let gide = novel("窄门（足本无删减，名家经典译本）", author: "[法]安德烈·纪德")
        XCTAssertEqual(WebNovelText.rank(gide, editions: [edition("full", "窄门", "安德烈·纪德"), edition("surname", "窄门", "纪德"), edition("other", "窄门", "别人")]).map(\.confidence),
                       [.titleAndAuthor, .possible], "a surname alone is the same book only after a look")
        // A catalog copy without the chart's subtitle is offered, not added unseen.
        let subtitled = novel("毛选的顶级思维：普通人学得会的36堂认知进阶课", author: "韦海生")
        XCTAssertEqual(WebNovelText.rank(subtitled, editions: [edition("short", "毛选的顶级思维", "韦海生"), edition("unrelated", "毛选的底层逻辑", "韦海生")]).map(\.book.remoteID), ["short"])
        XCTAssertEqual(WebNovelText.rank(subtitled, editions: [edition("short", "毛选的顶级思维", "韦海生")]).first?.confidence, .possible)

        var owned = Book(id: UUID(), title: "《诡秘之主》（精校版）作者：爱潜水的乌贼", author: "爱潜水的乌贼", fileName: "a.txt", format: .txt, fingerprint: "a")
        XCTAssertTrue(WebNovelText.same(owned, as: novel()))
        owned.author = ""
        XCTAssertFalse(WebNovelText.same(owned, as: novel()), "a title alone does not make it the same book")
    }

    func testEachChartIsCachedKeptThroughAFailedRefreshAndTheChoiceIsRemembered() async {
        let d = defaults(), service = ChartPages(), store = WebNovelStore(defaults: d, service: service)
        await store.load(); await store.load()
        var calls = await service.calls
        XCTAssertEqual(calls, [WebNovelSelection()], "a chart loaded within six hours is reused")
        XCTAssertEqual(store.books.first?.title, "月票榜 · 全站")

        store.chart = .recommended; store.period = .allTime; store.category = 22
        await store.load()
        XCTAssertEqual(store.books.first?.title, "推荐票榜 · 总榜 · 仙侠")
        await service.setFailing(true); await store.load(force: true)
        XCTAssertEqual(store.books.first?.title, "推荐票榜 · 总榜 · 仙侠", "the chart loaded earlier stays")
        XCTAssertEqual(store.error, WebNovelFeedError.invalidResponse.localizedDescription)
        store.chart = .tickets
        XCTAssertNil(store.error, "one chart's failure is not shown on another")
        XCTAssertTrue(store.books.isEmpty, "a chart not loaded yet is never filled in with another one")

        let reopened = WebNovelStore(defaults: d, service: service)
        XCTAssertEqual(reopened.selection, WebNovelSelection(chart: .tickets, category: 22))
        XCTAssertEqual(reopened.period, .allTime, "the period chosen for 推荐票榜 is kept for when it is shown again")
        XCTAssertEqual(reopened.list(WebNovelSelection(chart: .recommended, category: 22, period: .allTime))?.books.first?.title, "推荐票榜 · 总榜 · 仙侠")
        calls = await service.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testEachSiteKeepsItsOwnChartAndLoadMoreAddsToALongOne() async {
        let d = defaults(), service = ChartPages(), store = WebNovelStore(defaults: d, service: service)
        XCTAssertEqual(store.source, .qidian, "起点 stays the site shown until the reader picks the other")
        store.chart = .sales
        store.source = .weread
        XCTAssertEqual(store.chart, .top); XCTAssertEqual(store.selection.category, WebNovelCategory.everything.id)
        store.chart = .rising
        store.source = .qidian; XCTAssertEqual(store.chart, .sales)
        store.source = .weread; XCTAssertEqual(store.chart, .rising)

        await store.load()
        XCTAssertEqual(store.books.count, 20); XCTAssertTrue(store.canLoadMore)
        await service.setRepeatsABook(true)
        await store.loadMore()
        XCTAssertEqual(store.books.map(\.rank), Array(1...20) + Array(22...40), "a book the chart moved onto the next page is not listed twice")
        var offsets = await service.offsets
        XCTAssertEqual(offsets, [0, 20])

        // Between launches only the first page is kept; the site and both charts are remembered.
        let reopened = WebNovelStore(defaults: d, service: service)
        XCTAssertEqual(reopened.source, .weread); XCTAssertEqual(reopened.chart, .rising)
        XCTAssertEqual(reopened.books.map(\.rank), Array(1...20)); XCTAssertTrue(reopened.canLoadMore)
        reopened.source = .qidian; XCTAssertEqual(reopened.chart, .sales)

        // A long chart stops growing at a hundred books.
        await service.setRepeatsABook(false)
        store.chart = .top; await store.load()
        for _ in 0..<6 { await store.loadMore() }
        XCTAssertEqual(store.books.count, WebNovelStore.mostBooks); XCTAssertFalse(store.canLoadMore)
        offsets = await service.offsets
        XCTAssertEqual(offsets.suffix(5), [0, 20, 40, 60, 80])

        // A failed "Load more" keeps what is shown and says so.
        store.chart = .acclaimed; await store.load()
        await service.setFailing(true); await store.loadMore()
        XCTAssertEqual(store.books.count, 20); XCTAssertNotNil(store.error)
    }

    func testAskLeafReadsAChartItWasNeverShownAndTheOneOnScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root, seedSamples: false), d = defaults()
        let credentials = KeychainChatCredentials(service: "com.leafreader.tests.\(UUID())")
        let novels = WebNovelStore(defaults: d, service: UITestWebNovelClient())
        let catalog = ZLibraryStore(defaults: d, credentials: credentials, client: UITestZLibraryClient(), discoversFromLibrary: false)
        let bestsellers = BestsellerStore(defaults: d, credentials: credentials, service: UITestBestsellerClient(), allowsAutomaticShelf: false)
        let toolbox = ReadingAgentToolbox(book: nil, app: ChatAppData(catalog: catalog, bestsellers: bestsellers, webNovels: novels, library: library)) { _ in "{}" }
        XCTAssertTrue(novels.lists.isEmpty)
        let output = try await toolbox.run(AgentToolCall(id: "1", name: "get_web_novel_chart", arguments: #"{"chart":"rec","category":"科幻","period":"all_time","max_items":1}"#))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(body["chart"] as? String, "推荐票榜 · 总榜 · 科幻")
        XCTAssertEqual(body["total_items"] as? Int, 2)
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?["title"] as? String, "星海拾荒者")
        XCTAssertEqual(items.first?["length"] as? String, "128.5万字"); XCTAssertNotNil(items.first?["synopsis"])
        XCTAssertEqual(toolbox.steps, ["read 起点 推荐票榜 (1)"])
        XCTAssertEqual(novels.selection, WebNovelSelection(), "reading a chart for the chat does not change the reader's screen")

        // 微信读书 charts are read the same way, by the chart's name alone.
        let weread = try await toolbox.run(AgentToolCall(id: "2", name: "get_web_novel_chart", arguments: #"{"chart":"all","max_items":2}"#))
        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(weread.utf8)) as? [String: Any])
        XCTAssertEqual(read["source"] as? String, "微信读书 (WeChat Read)"); XCTAssertEqual(read["chart"] as? String, "总榜")
        XCTAssertEqual(read["more_available"] as? Bool, true); XCTAssertNil(read["note"])
        let listed = try XCTUnwrap(read["items"] as? [[String: Any]])
        XCTAssertEqual(listed.first?["title"] as? String, "星海拾荒者（全三册）"); XCTAssertEqual(listed.first?["count"] as? String, "96.0% 推荐 · 今日 3000人在读")
        XCTAssertNil(listed.first?["length"])
        XCTAssertEqual(toolbox.steps.last, "read 微信读书 总榜 (2)")
        XCTAssertEqual(novels.source, .qidian)

        // On the 中文 section, "what is on screen" is the chart being shown.
        novels.showing = true; await novels.load()
        let screen = ChatScreen.discover(catalog, library: library, bestsellers: bestsellers, webNovels: novels)
        let view = screen.view(5, true)
        XCTAssertEqual(view["list"] as? String, "中文榜单 (Chinese charts)")
        XCTAssertEqual(view["chart"] as? String, "月票榜 · 全站"); XCTAssertEqual(view["month"] as? String, "2026年11月")
        XCTAssertEqual((view["items"] as? [[String: Any]])?.map { $0["title"] as? String }, ["星海拾荒者", "长夜书局", "山河旧梦", "剑起云深处", "都市烟火录"])
        let third = try await screen.details(3, true)
        XCTAssertEqual(third?["title"] as? String, "山河旧梦"); XCTAssertEqual(third?["subcategory"] as? String, "架空历史")
        novels.viewingBook = novels.books[1]
        XCTAssertEqual((screen.view(5, true)["open_book"] as? [String: Any])?["title"] as? String, "长夜书局")
    }
}
