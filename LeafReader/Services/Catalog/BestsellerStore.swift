import Foundation
import Combine

struct BestsellerSearchContext {
    let generation: UUID
    let query: String
    let books: [ZLibraryBook]
    let status: [String]
}

/// Public discovery metadata has its own cache and never changes a Z-Library search.
@MainActor final class BestsellerStore: ObservableObject {
    @Published var source: BestsellerSource { didSet { defaults.set(source.rawValue, forKey: "bestsellers.source") } }
    @Published var genre: BestsellerGenre { didSet { defaults.set(genre.rawValue, forKey: "bestsellers.genre") } }
    @Published var showingBestsellers = false
    @Published private(set) var lists: [BestsellerList] = []
    @Published private(set) var loading: Set<BestsellerSource> = []
    @Published private(set) var errors: [BestsellerSource: String] = [:]
    @Published private(set) var nytConnected = false
    @Published private(set) var configurationError: String?
    @Published var viewingBook: BestsellerBook?
    @Published var catalogSearch: BestsellerSearchContext?
    let matching = BestsellerMatching()
    let allowsAutomaticShelf: Bool
    private let defaults: UserDefaults
    private let credentials: any ChatCredentialStore
    private let service: any BestsellerServing
    private var requests: [BestsellerSource: (UUID, Task<Void, Never>)] = [:]
    private let now: () -> Date
    var selected: BestsellerList? { lists.first { $0.source == source && $0.genre == genre } }
    var books: [BestsellerBook] { selected?.books ?? [] }
    var isLoading: Bool { loading.contains(source) }
    var error: String? { errors[source] }
    var needsNYTConnection: Bool { source == .nyt && !nytConnected }

    init(defaults: UserDefaults = .standard,
         credentials: any ChatCredentialStore = KeychainChatCredentials(service: "com.weizhao.leafreader.nytbooks"),
         service: any BestsellerServing = BestsellerFeedClient(), allowsAutomaticShelf: Bool = true,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.credentials = credentials; self.service = service
        self.allowsAutomaticShelf = allowsAutomaticShelf; self.now = now
        source = BestsellerSource(rawValue: defaults.string(forKey: "bestsellers.source") ?? "") ?? .indie
        genre = BestsellerGenre(rawValue: defaults.string(forKey: "bestsellers.genre") ?? "") ?? .nonfiction
        if let data = defaults.data(forKey: "bestsellers.cache.v1"), data.count <= 500_000,
           let saved = try? JSONDecoder().decode([BestsellerList].self, from: data), saved.count <= 4 {
            lists = saved.filter { list in
                list.books.count <= 30 && list.books.allSatisfy { $0.source == list.source && $0.genre == list.genre && (1...30).contains($0.rank) }
            }
        }
        nytConnected = ((try? credentials.read(account: "nyt-books")) ?? nil)?.isEmpty == false
        #if DEBUG
        if let fixture = service as? UITestBestsellerClient { nytConnected = fixture.nytAvailable }
        #endif
    }

    func saveNYTKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 256, key.allSatisfy({ $0.isASCII && !$0.isWhitespace && !$0.isNewline }) else {
            throw NSError(domain: "LeafNYT", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter the API key without spaces or line breaks."])
        }
        try credentials.write(key.isEmpty ? nil : key, account: "nyt-books")
        requests[.nyt]?.1.cancel(); requests[.nyt] = nil; loading.remove(.nyt)
        nytConnected = !key.isEmpty; configurationError = nil; errors[.nyt] = nil
        if key.isEmpty { lists.removeAll { $0.source == .nyt }; saveCache() }
    }

    func load(force: Bool = false) async { await load(source: source, force: force) }
    func loadShelf(force: Bool = false) async { if allowsAutomaticShelf { await load(force: force) } }
    func load(source requested: BestsellerSource, force: Bool = false) async {
        if let request = requests[requested] { await request.1.value; return }
        if !force, let saved = lists.first(where: { $0.source == requested }) {
            let age = now().timeIntervalSince(saved.fetchedAt)
            if age >= 0 && age < 6 * 3600 { return }
        }
        var key: String?
        do { key = try credentials.read(account: "nyt-books") }
        catch {
            if requested == .nyt { errors[requested] = "Unlock the device to read your NYT Books connection, then try again."; return }
        }
        if requested == .nyt {
            nytConnected = key?.isEmpty == false
            #if DEBUG
            if let fixture = service as? UITestBestsellerClient { nytConnected = fixture.nytAvailable }
            #endif
        }
        let id = UUID(), provider = service
        loading.insert(requested); errors[requested] = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                if self.requests[requested]?.0 == id { self.loading.remove(requested); self.requests[requested] = nil }
            }
            do {
                let result = try await provider.lists(source: requested, apiKey: key)
                try Task.checkCancellation(); guard self.requests[requested]?.0 == id else { return }
                self.lists.removeAll { $0.source == requested }; self.lists.append(contentsOf: result)
                self.saveCache()
            } catch {
                guard self.requests[requested]?.0 == id, !Task.isCancelled, !ZLibraryStore.isCancellation(error) else { return }
                self.errors[requested] = (error as? BestsellerFeedError ?? .unavailable).localizedDescription
            }
        }
        requests[requested] = (id, task)
        await task.value
    }
    private func saveCache() { defaults.set(try? JSONEncoder().encode(lists), forKey: "bestsellers.cache.v1") }
    func rankings(title: String, author: String) -> [BestsellerBook] {
        lists.flatMap(\.books).filter { BestsellerText.compatibleTitles($0.title, title) && BestsellerText.normalized($0.author) == BestsellerText.normalized(author) }
            .sorted { $0.rank < $1.rank }
    }
    func existing(_ book: BestsellerBook, in library: LibraryStore, candidates: [ZLibraryBook] = []) -> Book? {
        let sources = Set(candidates.map(\.sourceID))
        return library.books.first {
            ($0.catalogSource.map(sources.contains) ?? false) ||
                (BestsellerText.compatibleTitles($0.title, book.title) && BestsellerText.normalized($0.author) == BestsellerText.normalized(book.author))
        }
    }
}
