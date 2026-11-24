#if DEBUG
import Foundation

/// Offline 起点 and 微信读书 charts with invented books, and the catalog editions the
/// mock catalog returns for them: one sure match, one to choose from, one with none.
actor UITestWebNovelClient: WebNovelServing {
    private var attempts = 0
    func list(_ selection: WebNovelSelection, offset: Int) async throws -> WebNovelList {
        try await Task.sleep(for: .milliseconds(160)); try Task.checkCancellation()
        attempts += 1
        if UITesting.flag(.webNovelsFeedFailure), attempts == 1 { throw WebNovelFeedError.unavailable }
        if selection.source == .weread { return Self.weread(selection, offset: offset) }
        var rows = Self.samples
        if selection.category != WebNovelCategory.everything.id { rows = rows.filter { $0.category == WebNovelCategory.titled(selection.category) } }
        // Each chart and period has its own order, so a switch is visible.
        if selection.chart != .tickets { rows.reverse() }
        if selection.chart.hasPeriods, selection.period == .allTime, rows.count > 1 { let first = rows.removeFirst(); rows.append(first) }
        let unit = selection.chart == .tickets ? "万月票" : selection.chart == .recommended ? "万推荐" : ""
        return WebNovelList(selection: selection, published: selection.chart == .tickets ? "2026年11月" : "", fetchedAt: Date(),
            books: rows.enumerated().map { index, row in
                WebNovel(rank: index + 1, bookID: row.bookID, title: row.title, author: row.author, category: row.category, subcategory: row.subcategory,
                         length: row.length, figure: unit.isEmpty ? "" : "\(6 - index).\(index)\(unit)", summary: row.summary)
            })
    }
    /// 微信读书 the way the site serves it: titles and authors with its own notes, a
    /// rating and today's readers, and the chart in pages (four books here).
    static func weread(_ selection: WebNovelSelection, offset: Int) -> WebNovelList {
        let rows = selection.chart == .top ? samples : samples.reversed()
        let noted = ["星海拾荒者": ("星海拾荒者（全三册）", "青柠茶"), "长夜书局": ("长夜书局", "[英]墨白")]
        let page = Array(rows.enumerated()).dropFirst(offset).prefix(4)
        return WebNovelList(selection: selection, published: "", fetchedAt: Date(), books: page.map { index, row in
            let names = noted[row.title] ?? (row.title, row.author)
            return WebNovel(rank: index + 1, bookID: "w" + row.bookID, title: names.0, author: names.1, category: row.category,
                            subcategory: row.subcategory, length: "", figure: "\(96 - index).0% 推荐 · 今日 \(3000 - index * 400)人在读",
                            summary: row.summary, source: .weread, ratingPermille: 960 - index * 10, ratingCount: 52_000 - index * 4000,
                            ratingTitle: index == 0 ? "神作" : nil)
        }, hasMore: offset + 4 < rows.count)
    }
    static let samples: [WebNovel] = [
        ("星海拾荒者", "青柠茶", "科幻", "星际文明", "128.5万字", "废土边缘的拾荒少年捡到一枚会说话的导航核心，从此踏上横穿星海的归途。沿途的每一座空间站，都藏着旧时代留下的一道谜题。"),
        ("长夜书局", "墨白", "悬疑灵异", "诡秘悬疑", "86.2万字", "凌晨才开门的旧书店，只卖给有心事的人。每一本被买走的书，都会在第二天夜里把故事还回来。"),
        ("山河旧梦", "顾北", "历史", "架空历史", "305.7万字", "一位落第书生在边城做起了驿丞，靠着一张舆图和三寸不烂之舌，在乱世里为一城百姓谋一条活路。"),
        ("剑起云深处", "半盏清茶", "仙侠", "古典仙侠", "412.3万字", "云深不知处，有人十年磨一剑。少年下山那天，才知道山外的江湖早已不讲剑理。"),
        ("都市烟火录", "陈小满", "都市", "都市生活", "64.9万字", "从夜市小摊到街角小馆，一个厨子用一口锅记下一座城的人情冷暖。"),
        ("机械与花", "南舟", "科幻", "未来世界", "97.4万字", "负责照看温室的旧型号机器人，想在停机之前弄明白一件事：花为什么要开。")
    ].enumerated().map { index, row in
        WebNovel(rank: index + 1, bookID: "90000000\(index + 1)", title: row.0, author: row.1, category: row.2, subcategory: row.3,
                 length: row.4, figure: "", summary: row.5)
    }
    nonisolated static func editions(_ novel: WebNovel) -> [ZLibraryBook] {
        func edition(_ suffix: String, title: String, author: String, size: String) -> ZLibraryBook {
            ZLibraryBook(remoteID: "novel-\(novel.bookID)\(suffix)", hash: "fixture\(novel.bookID)\(suffix)", title: title, author: author,
                         fileExtension: "txt", size: size, language: "Chinese", year: "2026", coverURL: nil, summary: novel.summary)
        }
        switch novel.title {
        case "山河旧梦": return []
        // The way uploads are usually titled: wrapped, annotated and credited in the title.
        case "星海拾荒者": return [edition("", title: "《星海拾荒者》（精校版）作者：青柠茶", author: "青柠茶", size: "3.1 MB")]
        case "长夜书局": return [edition("", title: novel.title, author: novel.author, size: "2.2 MB"),
                                 edition("-2", title: novel.title + "2：白昼来客", author: novel.author, size: "1.4 MB")]
        default: return [edition("", title: novel.title, author: novel.author, size: "2 MB")]
        }
    }
    nonisolated static func search(_ query: String) -> [ZLibraryBook] {
        samples.filter { query.contains($0.title) }.flatMap(editions)
    }
}
#endif
