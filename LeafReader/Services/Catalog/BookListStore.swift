import Foundation
import Combine

/// Discover's 豆瓣, Gutenberg, Apple Books, prize and Open Library lists. Like the
/// bestseller and 中文 charts, this is public metadata with its own cache, apart from
/// any catalog search.
@MainActor final class BookListStore: ObservableObject {
    /// Whether Discover is showing one of these lists.
    @Published var showing = false
    @Published var source: BookListSource { didSet { defaults.set(source.rawValue, forKey: "booklists.source") } }
    /// The list last chosen in each source, so coming back returns to it.
    @Published private var charts: [BookListSource: BookListChart]
    @Published var country: BookListCountry { didSet { defaults.set(country.rawValue, forKey: "booklists.country") } }
    @Published private(set) var lists: [BookList] = []
    @Published private(set) var loading: Set<BookListSelection> = []
    @Published private(set) var errors: [BookListSelection: String] = [:]
    @Published var viewingBook: ListedBook?
    /// A Gutenberg book being added from its free EPUB.
    @Published private(set) var downloadingID: String?
    @Published private(set) var downloadError: String?
    private let defaults: UserDefaults
    private let service: any BookListServing
    private let now: () -> Date
    private var requests: [BookListSelection: (UUID, Task<Void, Never>)] = [:]
    private var download: Task<Void, Never>?
    private static let cacheKey = "booklists.cache.v1", cachedLists = 10
    /// How far "Load more" goes down a long list.
    static let mostBooks = 250

    var chart: BookListChart {
        get { charts[source] ?? source.charts[0] }
        set { charts[newValue.source] = newValue; defaults.set(newValue.rawValue, forKey: "booklists.chart.\(newValue.source.rawValue)") }
    }
    var selection: BookListSelection { BookListSelection(chart: chart, country: country) }
    var selected: BookList? { list(selection) }
    var books: [ListedBook] { selected?.books ?? [] }
    var isLoading: Bool { loading.contains(selection) }
    var error: String? { errors[selection] }
    var canLoadMore: Bool { selected.map { $0.hasMore && $0.books.count < Self.mostBooks } ?? false }
    func list(_ selection: BookListSelection) -> BookList? { lists.first { $0.selection == selection } }

    init(defaults: UserDefaults = .standard, service: any BookListServing = BookListClient(), now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.service = service; self.now = now
        source = BookListSource(rawValue: defaults.string(forKey: "booklists.source") ?? "") ?? .douban
        var chosen: [BookListSource: BookListChart] = [:]
        for site in BookListSource.allCases {
            if let saved = BookListChart(rawValue: defaults.string(forKey: "booklists.chart.\(site.rawValue)") ?? ""), saved.source == site { chosen[site] = saved }
        }
        charts = chosen
        country = BookListCountry(rawValue: defaults.string(forKey: "booklists.country") ?? "") ?? Self.localCountry
        if let data = defaults.data(forKey: Self.cacheKey), data.count <= 1_000_000,
           let cached = try? JSONDecoder().decode([BookList].self, from: data) {
            lists = cached.suffix(Self.cachedLists).filter { list in
                !list.books.isEmpty && list.books.count <= 50 && !list.selection.chart.isBundled
                    && list.books.enumerated().allSatisfy { $0.element.rank == $0.offset + 1 && $0.element.source == list.selection.source }
            }
        }
    }
    /// The reader's own Apple Books store, when Leaf offers it.
    private static var localCountry: BookListCountry {
        BookListCountry(rawValue: (Locale.current.region?.identifier ?? "US").lowercased()) ?? .us
    }

    /// Shows a source's list in Discover.
    func show(_ source: BookListSource) { self.source = source; showing = true }

    func load(force: Bool = false) async { await load(selection, force: force) }
    func load(_ requested: BookListSelection, force: Bool = false) async {
        if let request = requests[requested] { await request.1.value; return }
        if !force, let saved = list(requested) {
            let age = now().timeIntervalSince(saved.fetchedAt)
            if requested.chart.isBundled || (age >= 0 && age < 6 * 3600) { return }
        }
        await request(requested, after: nil)
    }
    /// The next books of a list that has more, added under the ones already shown.
    func loadMore() async {
        let requested = selection
        guard requests[requested] == nil, canLoadMore, let shown = list(requested) else { return }
        await request(requested, after: shown)
    }
    private func request(_ requested: BookListSelection, after shown: BookList?) async {
        let id = UUID(), provider = service
        loading.insert(requested); errors[requested] = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                if self.requests[requested]?.0 == id { self.loading.remove(requested); self.requests[requested] = nil }
            }
            do {
                var result: BookList
                // Prize winners are carried in the app.
                if requested.chart.isBundled { result = PrizeWinners.list(requested) }
                else { result = try await provider.list(requested, offset: shown?.next ?? 0) }
                try Task.checkCancellation(); guard self.requests[requested]?.0 == id else { return }
                if let shown {
                    guard self.list(requested) == shown else { return }
                    // A list can move between two requests; a book already shown is not listed twice.
                    let known = Set(shown.books.map(\.bookID)), added = result.books.filter { !known.contains($0.bookID) }
                    result = BookList(selection: requested, published: shown.published, fetchedAt: shown.fetchedAt,
                                      books: shown.books + added, next: added.isEmpty ? nil : result.next)
                }
                result = Self.numbered(result)
                // The newest list goes last; the oldest falls out of the cache.
                self.lists.removeAll { $0.selection == requested }; self.lists.append(result)
                self.lists = Array(self.lists.suffix(Self.cachedLists))
                self.save()
            } catch {
                guard self.requests[requested]?.0 == id, !Task.isCancelled, !ZLibraryStore.isCancellation(error) else { return }
                self.errors[requested] = (error as? BookListFeedError ?? .unavailable).localizedDescription
            }
        }
        requests[requested] = (id, task)
        await task.value
    }
    /// Ranks run 1, 2, 3… down the list, whatever the source skipped. Prize lists keep their years.
    private static func numbered(_ list: BookList) -> BookList {
        let books = list.books.enumerated().map { index, book in var book = book; book.rank = index + 1; return book }
        return BookList(selection: list.selection, published: list.published, fetchedAt: list.fetchedAt, books: books, next: list.next)
    }
    /// Only the first page of each list is kept between launches; "Load more" fetches the rest again.
    private func save() {
        let firstPages = lists.filter { !$0.selection.chart.isBundled }.map { list -> BookList in
            guard list.books.count > 50 else { return list }
            let kept = Array(list.books.prefix(50))
            return BookList(selection: list.selection, published: list.published, fetchedAt: list.fetchedAt, books: kept, next: nil)
        }
        defaults.set(try? JSONEncoder().encode(firstPages), forKey: Self.cacheKey)
    }

    func existing(_ book: ListedBook, in library: LibraryStore, candidates: [ZLibraryBook] = []) -> Book? {
        let sources = Set(candidates.map(\.sourceID) + [book.gutenbergSource].compactMap { $0 })
        return library.books.first { book2 in
            if let source = book2.catalogSource, sources.contains(source) { return true }
            if book.isChinese { return WebNovelText.title(book2.title) == WebNovelText.title(book.title) && WebNovelText.author(book2.author).contains(WebNovelText.author(book.author)) }
            return BestsellerText.compatibleTitles(book2.title, book.title) && BestsellerText.normalized(book2.author) == BestsellerText.normalized(book.author)
        }
    }

    /// Adds a Project Gutenberg book from its free EPUB. No account is needed.
    func addFree(_ book: ListedBook, library: LibraryStore) {
        guard download == nil, book.epub != nil, let catalogID = book.gutenbergSource else { return }
        downloadingID = book.id; downloadError = nil
        let provider = service
        download = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadingID = nil; self.download = nil }
            do {
                let file = try await provider.download(book)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                try Task.checkCancellation()
                _ = try await library.importCatalogBook(file, catalogID: catalogID, title: book.title, author: book.author)
            } catch {
                guard !Task.isCancelled, !ZLibraryStore.isCancellation(error) else { return }
                self.downloadError = (error as? BookListFeedError)?.downloadDescription ?? error.localizedDescription
            }
        }
    }
    func cancelDownload() { download?.cancel() }
    func resetDownloadResult() { downloadError = nil }
}

extension BookListFeedError {
    var downloadDescription: String {
        switch self {
        case .maintenance: return "Project Gutenberg is down for maintenance. Try again later."
        case .rateLimited: return "Project Gutenberg is limiting downloads. Try again later."
        case .invalidResponse: return "Project Gutenberg didn’t send an EPUB for this book."
        case .unavailable, .noChart: return "The book couldn’t be downloaded. Check your connection and try again."
        }
    }
}

extension BookListServing {
    /// Project Gutenberg's EPUB, saved to a temporary folder of its own.
    func download(_ book: ListedBook) async throws -> URL {
        guard let url = book.epub, url.host?.hasSuffix("gutenberg.org") == true else { throw BookListFeedError.unavailable }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue(BookListClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/epub+zip", forHTTPHeaderField: "Accept")
        let (file, response) = try await URLSession(configuration: .ephemeral).download(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BookListFeedError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 403, 429: throw BookListFeedError.rateLimited
        case 503: throw BookListFeedError.maintenance
        default: throw BookListFeedError.unavailable
        }
        // An EPUB is a zip file; a maintenance or error page is not.
        let handle = try FileHandle(forReadingFrom: file)
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        try? handle.close()
        guard head == Data("PK".utf8) else { try? FileManager.default.removeItem(at: file); throw BookListFeedError.invalidResponse }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Gutenberg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(book.title.unicodeScalars.filter { CharacterSet.alphanumerics.union(.whitespaces).contains($0) }.prefix(80))
        let target = folder.appendingPathComponent((name.isEmpty ? "Gutenberg \(book.bookID)" : name) + ".epub")
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}
