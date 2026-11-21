import XCTest
@testable import LeafReader

private actor ChartPages: WebNovelServing {
    var calls: [WebNovelSelection] = []
    var fail = false
    func setFailing(_ value: Bool) { fail = value }
    func list(_ selection: WebNovelSelection) async throws -> WebNovelList {
        calls.append(selection)
        if fail { throw WebNovelFeedError.invalidResponse }
        let novel = WebNovel(rank: 1, bookID: "\(calls.count)", title: selection.caption, author: "作者", category: "仙侠", subcategory: "",
                             length: "10万字", figure: "", summary: "")
        return WebNovelList(selection: selection, published: "", fetchedAt: Date(), books: [novel])
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
        let list = try QidianChartClient.parse(page(), selection: WebNovelSelection())
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
        let short = try QidianChartClient.parse(page(chart: "rec", category: 22, period: 1, month: nil, total: 3, rows: (1...3).map { row($0) }), selection: small)
        XCTAssertEqual(short.books.count, 3); XCTAssertEqual(short.published, "")
    }

    func testAPageThatIsNotTheChartAskedForOrIsIncompleteIsRejected() {
        func rejected(_ data: Data, _ selection: WebNovelSelection = WebNovelSelection(), _ reason: String, line: UInt = #line) {
            XCTAssertThrowsError(try QidianChartClient.parse(data, selection: selection), reason, line: line) {
                XCTAssertEqual($0 as? WebNovelFeedError, .invalidResponse, line: line)
            }
        }
        rejected(Data("<html><script src=\"/probe.js\"></script></html>".utf8), "the site's browser check")
        rejected(page(chart: "hotsales"), "another chart")
        rejected(page(category: 22), "another category")
        rejected(page(chart: "rec", period: 2, month: nil), WebNovelSelection(chart: .recommended, period: .week), "another period")
        rejected(page(pageNumber: 2), "a later page")
        rejected(page(rows: (1...19).map { row($0) }), "a cut-off chart")
        rejected(page(rows: (1...20).map { row($0 == 7 ? 8 : $0) }), "a gap in the ranks")
        rejected(page(rows: (1...20).map { row($0, id: $0 == 5 ? "104" : nil) }), "the same book twice")
        rejected(page(rows: (1...20).map { row($0, id: $0 == 5 ? "../x" : nil) }), "an identifier that is not a number")
        rejected(page(rows: (1...20).map { row($0, title: $0 == 5 ? "  " : nil) }), "a book without a title")
        rejected(page(total: 0, rows: []), "an empty chart")
    }

    func testEachChartCategoryAndPeriodHasItsOwnAddress() {
        XCTAssertEqual(WebNovelSelection().url.absoluteString, "https://m.qidian.com/rank/yuepiao/catid-1/")
        XCTAssertEqual(WebNovelSelection(chart: .sales, category: 9).url.absoluteString, "https://m.qidian.com/rank/hotsales/catid9/")
        XCTAssertEqual(WebNovelSelection(chart: .recommended, category: 22, period: .allTime).url.absoluteString, "https://m.qidian.com/rank/rec/catid22/1/")
        // Only 推荐票榜 has periods, and a category the site does not list means 全站.
        XCTAssertEqual(WebNovelSelection(chart: .reading, category: 31337, period: .month), WebNovelSelection(chart: .reading))
        XCTAssertEqual(WebNovelSelection(chart: .recommended, period: .month).caption, "推荐票榜 · 月榜 · 全站")
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

        // On the 网文 section, "what is on screen" is the chart being shown.
        novels.showing = true; await novels.load()
        let screen = ChatScreen.discover(catalog, library: library, bestsellers: bestsellers, webNovels: novels)
        let view = screen.view(5, true)
        XCTAssertEqual(view["list"] as? String, "网文 (Chinese web novels)")
        XCTAssertEqual(view["chart"] as? String, "月票榜 · 全站"); XCTAssertEqual(view["month"] as? String, "2026年11月")
        XCTAssertEqual((view["items"] as? [[String: Any]])?.map { $0["title"] as? String }, ["星海拾荒者", "长夜书局", "山河旧梦", "剑起云深处", "都市烟火录"])
        let third = try await screen.details(3, true)
        XCTAssertEqual(third?["title"] as? String, "山河旧梦"); XCTAssertEqual(third?["subcategory"] as? String, "架空历史")
        novels.viewingBook = novels.books[1]
        XCTAssertEqual((screen.view(5, true)["open_book"] as? [String: Any])?["title"] as? String, "长夜书局")
    }
}
