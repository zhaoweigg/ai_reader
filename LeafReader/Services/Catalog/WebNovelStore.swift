import Foundation
import Combine

/// The 起点 web-novel charts behind Discover's 网文 section. Like the bestseller
/// lists, this is public metadata with its own cache, apart from any catalog search.
@MainActor final class WebNovelStore: ObservableObject {
    /// Whether Discover is showing the 网文 section.
    @Published var showing = false
    @Published var chart: WebNovelChart { didSet { defaults.set(chart.rawValue, forKey: "webnovels.chart") } }
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
    private static let cacheKey = "webnovels.cache.v1", cachedCharts = 8

    var selection: WebNovelSelection { WebNovelSelection(chart: chart, category: category, period: period) }
    var selected: WebNovelList? { list(selection) }
    var books: [WebNovel] { selected?.books ?? [] }
    var isLoading: Bool { loading.contains(selection) }
    var error: String? { errors[selection] }
    func list(_ selection: WebNovelSelection) -> WebNovelList? { lists.first { $0.selection == selection } }

    init(defaults: UserDefaults = .standard, service: any WebNovelServing = QidianChartClient(), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.service = service; self.now = now
        chart = WebNovelChart(rawValue: defaults.string(forKey: "webnovels.chart") ?? "") ?? .tickets
        // A category the site no longer lists falls back to 全站.
        category = WebNovelSelection(category: defaults.object(forKey: "webnovels.category") as? Int ?? WebNovelCategory.everything.id).category
        // A period chosen for 推荐票榜 is kept while another chart is shown.
        period = WebNovelPeriod(rawValue: defaults.integer(forKey: "webnovels.period")) ?? .week
        if let data = defaults.data(forKey: Self.cacheKey), data.count <= 500_000,
           let cached = try? JSONDecoder().decode([WebNovelList].self, from: data) {
            lists = cached.suffix(Self.cachedCharts).filter { list in
                !list.books.isEmpty && list.books.count <= QidianChartClient.pageSize
                    && list.books.enumerated().allSatisfy { $0.element.rank == $0.offset + 1 }
            }
        }
    }

    func load(force: Bool = false) async { await load(selection, force: force) }
    func load(_ requested: WebNovelSelection, force: Bool = false) async {
        if let request = requests[requested] { await request.1.value; return }
        if !force, let saved = list(requested) {
            let age = now().timeIntervalSince(saved.fetchedAt)
            if age >= 0 && age < 6 * 3600 { return }
        }
        let id = UUID(), provider = service
        loading.insert(requested); errors[requested] = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                if self.requests[requested]?.0 == id { self.loading.remove(requested); self.requests[requested] = nil }
            }
            do {
                let result = try await provider.list(requested)
                try Task.checkCancellation(); guard self.requests[requested]?.0 == id else { return }
                // The newest chart goes last; the oldest falls out of the cache.
                self.lists.removeAll { $0.selection == requested }; self.lists.append(result)
                self.lists = Array(self.lists.suffix(Self.cachedCharts))
                self.defaults.set(try? JSONEncoder().encode(self.lists), forKey: Self.cacheKey)
            } catch {
                guard self.requests[requested]?.0 == id, !Task.isCancelled, !ZLibraryStore.isCancellation(error) else { return }
                self.errors[requested] = (error as? WebNovelFeedError ?? .unavailable).localizedDescription
            }
        }
        requests[requested] = (id, task)
        await task.value
    }

    func existing(_ novel: WebNovel, in library: LibraryStore, candidates: [ZLibraryBook] = []) -> Book? {
        let sources = Set(candidates.map(\.sourceID))
        return library.books.first { ($0.catalogSource.map(sources.contains) ?? false) || WebNovelText.same($0, as: novel) }
    }
}
