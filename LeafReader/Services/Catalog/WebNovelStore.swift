import Foundation
import Combine

/// The charts behind Discover's 中文 section: 起点's web-novel charts and 微信读书's
/// book charts. Like the bestseller lists, this is public metadata with its own
/// cache, apart from any catalog search.
@MainActor final class WebNovelStore: ObservableObject {
    /// Whether Discover is showing the 中文 section.
    @Published var showing = false
    @Published var source: WebNovelSource { didSet { defaults.set(source.rawValue, forKey: "webnovels.source") } }
    /// The chart last chosen on each site, so switching sites returns to it.
    @Published private var charts: [WebNovelSource: WebNovelChart]
    @Published var category: Int { didSet { defaults.set(category, forKey: "webnovels.category") } }
    @Published var period: WebNovelPeriod { didSet { defaults.set(period.rawValue, forKey: "webnovels.period") } }
    @Published private(set) var lists: [WebNovelList] = []
    @Published private(set) var loading: Set<WebNovelSelection> = []
    @Published private(set) var errors: [WebNovelSelection: String] = [:]
    @Published var viewingBook: WebNovel?
    private let defaults: UserDefaults
    private let service: any WebNovelServing
    private let now: () -> Date
    private var requests: [WebNovelSelection: (UUID, Task<Void, Never>)] = [:]
    private static let cacheKey = "webnovels.cache.v2", cachedCharts = 8
    /// How far "Load more" goes down a long chart.
    static let mostBooks = 100
    private static func chartKey(_ source: WebNovelSource) -> String { source == .qidian ? "webnovels.chart" : "webnovels.\(source.rawValue).chart" }

    /// The chart shown for the chosen site.
    var chart: WebNovelChart {
        get { charts[source] ?? source.charts[0] }
        set { charts[newValue.source] = newValue; defaults.set(newValue.rawValue, forKey: Self.chartKey(newValue.source)) }
    }
    var selection: WebNovelSelection { WebNovelSelection(chart: chart, category: category, period: period) }
    var selected: WebNovelList? { list(selection) }
    var books: [WebNovel] { selected?.books ?? [] }
    var isLoading: Bool { loading.contains(selection) }
    var error: String? { errors[selection] }
    var canLoadMore: Bool { selected.map { $0.hasMore && $0.books.count < Self.mostBooks } ?? false }
    func list(_ selection: WebNovelSelection) -> WebNovelList? { lists.first { $0.selection == selection } }

    init(defaults: UserDefaults = .standard, service: any WebNovelServing = WebNovelClient(), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.service = service; self.now = now
        source = WebNovelSource(rawValue: defaults.string(forKey: "webnovels.source") ?? "") ?? .qidian
        var chosen: [WebNovelSource: WebNovelChart] = [:]
        for site in WebNovelSource.allCases {
            if let saved = WebNovelChart(rawValue: defaults.string(forKey: Self.chartKey(site)) ?? ""), saved.source == site { chosen[site] = saved }
        }
        charts = chosen
        // A category the site no longer lists falls back to 全站.
        category = WebNovelSelection(category: defaults.object(forKey: "webnovels.category") as? Int ?? WebNovelCategory.everything.id).category
        // A period chosen for 推荐票榜 is kept while another chart is shown.
        period = WebNovelPeriod(rawValue: defaults.integer(forKey: "webnovels.period")) ?? .week
        if let data = defaults.data(forKey: Self.cacheKey), data.count <= 500_000,
           let cached = try? JSONDecoder().decode([WebNovelList].self, from: data) {
            lists = cached.suffix(Self.cachedCharts).filter { list in
                !list.books.isEmpty && list.books.count <= WebNovelClient.pageSize
                    && list.books.enumerated().allSatisfy { $0.element.rank == $0.offset + 1 && $0.element.source == list.selection.source }
            }
        }
        // 1.41 kept its charts in a shape without a site; they are simply loaded again.
        if defaults.object(forKey: "webnovels.cache.v1") != nil { defaults.removeObject(forKey: "webnovels.cache.v1") }
    }

    func load(force: Bool = false) async { await load(selection, force: force) }
    func load(_ requested: WebNovelSelection, force: Bool = false) async {
        if let request = requests[requested] { await request.1.value; return }
        if !force, let saved = list(requested) {
            let age = now().timeIntervalSince(saved.fetchedAt)
            if age >= 0 && age < 6 * 3600 { return }
        }
        await request(requested, after: nil)
    }
    /// The next books of a chart that has more, added under the ones already shown.
    func loadMore() async {
        let requested = selection
        guard requests[requested] == nil, canLoadMore, let shown = list(requested) else { return }
        await request(requested, after: shown)
    }
    private func request(_ requested: WebNovelSelection, after shown: WebNovelList?) async {
        let id = UUID(), provider = service
        loading.insert(requested); errors[requested] = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                if self.requests[requested]?.0 == id { self.loading.remove(requested); self.requests[requested] = nil }
            }
            do {
                var result = try await provider.list(requested, offset: shown?.books.count ?? 0)
                try Task.checkCancellation(); guard self.requests[requested]?.0 == id else { return }
                if let shown {
                    guard self.list(requested) == shown else { return }
                    // A chart can move between two requests; a book already shown is not listed twice.
                    let known = Set(shown.books.map(\.bookID)), added = result.books.filter { !known.contains($0.bookID) }
                    result = WebNovelList(selection: requested, published: shown.published, fetchedAt: shown.fetchedAt,
                                          books: shown.books + added, hasMore: result.hasMore && !added.isEmpty)
                }
                // The newest chart goes last; the oldest falls out of the cache.
                self.lists.removeAll { $0.selection == requested }; self.lists.append(result)
                self.lists = Array(self.lists.suffix(Self.cachedCharts))
                self.save()
            } catch {
                guard self.requests[requested]?.0 == id, !Task.isCancelled, !ZLibraryStore.isCancellation(error) else { return }
                self.errors[requested] = (error as? WebNovelFeedError ?? .unavailable).localizedDescription
            }
        }
        requests[requested] = (id, task)
        await task.value
    }
    /// Only the first page of each chart is kept between launches; "Load more" fetches the rest again.
    private func save() {
        let firstPages = lists.map { list in
            list.books.count <= WebNovelClient.pageSize ? list : WebNovelList(selection: list.selection, published: list.published,
                fetchedAt: list.fetchedAt, books: Array(list.books.prefix(WebNovelClient.pageSize)), hasMore: true)
        }
        defaults.set(try? JSONEncoder().encode(firstPages), forKey: Self.cacheKey)
    }

    func existing(_ novel: WebNovel, in library: LibraryStore, candidates: [ZLibraryBook] = []) -> Book? {
        let sources = Set(candidates.map(\.sourceID))
        return library.books.first { ($0.catalogSource.map(sources.contains) ?? false) || WebNovelText.same($0, as: novel) }
    }
}
