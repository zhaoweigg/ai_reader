import Foundation
import Combine

/// One list Discover can show as a chip. The raw value is what the synced setting stores.
enum DiscoverList: String, CaseIterable, Identifiable {
    case popular, recommended, nyt, indie, qidian, weread, douban, gutenberg, apple, prizes, openLibrary = "openlibrary"
    var id: String { rawValue }
    /// The chip's label.
    var title: String {
        switch self {
        case .popular: return "Popular"
        case .recommended: return "For you"
        case .nyt: return "NYT"
        case .indie: return "Indie"
        case .qidian: return "起点"
        case .weread: return "微信读书"
        case .douban: return "豆瓣"
        case .gutenberg: return "Gutenberg"
        case .apple: return "Apple Books"
        case .prizes: return "Prize winners"
        case .openLibrary: return "Open Library"
        }
    }
    /// The Discover lists sheet's longer name.
    var name: String {
        switch self {
        case .popular: return "Popular"
        case .recommended: return "For you"
        case .nyt: return "NYT Best Sellers"
        case .indie: return "Indie Bestsellers"
        case .qidian: return "起点"
        case .weread: return "微信读书"
        case .douban: return "豆瓣读书"
        case .gutenberg: return "Project Gutenberg"
        case .apple: return "Apple Books"
        case .prizes: return "Prize winners"
        case .openLibrary: return "Open Library trending"
        }
    }
    /// What the list holds, under its name in the sheet.
    var detail: String {
        switch self {
        case .popular: return "Z-Library’s most downloaded"
        case .recommended: return "Z-Library picks for your account"
        case .nyt: return "Hardcover fiction and nonfiction"
        case .indie: return "Independent bookstores’ hardcovers"
        case .qidian: return "月票 · 畅销 · 阅读指数 · 推荐票"
        case .weread: return "总榜 · 飙升 · 新书 · 神作"
        case .douban: return "Top 250 · 新书速递"
        case .gutenberg: return "Free classics to add as EPUB"
        case .apple: return "Top paid · Top free · by country"
        case .prizes: return "Booker, Pulitzer, Hugo and more"
        case .openLibrary: return "Today · This week · This month"
        }
    }
    var symbol: String {
        switch self {
        case .popular: return "flame"
        case .recommended: return "sparkles"
        case .nyt, .indie, .apple: return "chart.bar"
        case .qidian, .weread, .douban: return "character.book.closed"
        case .gutenberg: return "building.columns"
        case .prizes: return "rosette"
        case .openLibrary: return "books.vertical"
        }
    }
    /// Lists that come from the public list store rather than Z-Library or the older stores.
    var bookListSource: BookListSource? {
        switch self {
        case .douban: return .douban
        case .gutenberg: return .gutenberg
        case .apple: return .apple
        case .prizes: return .prizes
        case .openLibrary: return .openLibrary
        default: return nil
        }
    }
    init(_ source: BookListSource) {
        switch source {
        case .douban: self = .douban
        case .gutenberg: self = .gutenberg
        case .apple: self = .apple
        case .prizes: self = .prizes
        case .openLibrary: self = .openLibrary
        }
    }
    /// Today's lists in today's order, then 豆瓣 and Gutenberg. The rest start hidden.
    static let initiallyShown: [DiscoverList] = [.popular, .recommended, .nyt, .indie, .qidian, .weread, .douban, .gutenberg]
}

/// Which lists Discover shows and in what order. The arrangement is one synced
/// setting, so another device's change applies here as soon as it arrives.
@MainActor final class DiscoverListsStore: ObservableObject {
    /// Every list once, shown ones first in the reader's order.
    @Published private(set) var shown: [DiscoverList]
    @Published private(set) var hidden: [DiscoverList]
    /// Synced. Shown lists by raw value, then hidden ones prefixed with "-", so a list
    /// added in a later version can be told apart from one the reader hid.
    static let key = "discover.lists"
    /// This device's last chip.
    static let selectedKey = "discover.list"
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = Self.arrangement(defaults.stringArray(forKey: Self.key))
        shown = saved.shown; hidden = saved.hidden
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Reads a saved arrangement. Unknown entries are dropped; lists it does not mention
    /// keep their initial place; at least one list is always shown.
    nonisolated static func arrangement(_ saved: [String]?) -> (shown: [DiscoverList], hidden: [DiscoverList]) {
        guard let saved, !saved.isEmpty else {
            return (DiscoverList.initiallyShown, DiscoverList.allCases.filter { !DiscoverList.initiallyShown.contains($0) })
        }
        var shown: [DiscoverList] = [], hidden: [DiscoverList] = []
        for entry in saved.prefix(64) {
            let off = entry.hasPrefix("-")
            guard let list = DiscoverList(rawValue: off ? String(entry.dropFirst()) : entry), !shown.contains(list), !hidden.contains(list) else { continue }
            if off { hidden.append(list) } else { shown.append(list) }
        }
        for list in DiscoverList.allCases where !shown.contains(list) && !hidden.contains(list) {
            if DiscoverList.initiallyShown.contains(list) { shown.append(list) } else { hidden.append(list) }
        }
        if shown.isEmpty { shown = [hidden.removeFirst()] }
        return (shown, hidden)
    }
    private func reload() {
        let value = Self.arrangement(defaults.stringArray(forKey: Self.key))
        if value.shown != shown { shown = value.shown }
        if value.hidden != hidden { hidden = value.hidden }
    }
    private func save() {
        let value = shown.map(\.rawValue) + hidden.map { "-" + $0.rawValue }
        if defaults.stringArray(forKey: Self.key) != value { defaults.set(value, forKey: Self.key) }
    }
    func isShown(_ list: DiscoverList) -> Bool { shown.contains(list) }
    /// Showing a list adds it at the end; the last shown list cannot be hidden.
    func setShown(_ list: DiscoverList, _ show: Bool) {
        if show {
            guard let index = hidden.firstIndex(of: list) else { return }
            hidden.remove(at: index); shown.append(list)
        } else {
            guard shown.count > 1, let index = shown.firstIndex(of: list) else { return }
            shown.remove(at: index); hidden.insert(list, at: 0)
        }
        save()
    }
    func move(from source: IndexSet, to destination: Int) {
        var lists = shown
        let moving = source.sorted().filter(lists.indices.contains).map { lists[$0] }
        guard !moving.isEmpty else { return }
        let before = source.filter { $0 < destination }.count
        lists.removeAll { moving.contains($0) }
        lists.insert(contentsOf: moving, at: min(max(0, destination - before), lists.count))
        shown = lists; save()
    }
    func restoreInitialLists() {
        let initial = Self.arrangement(nil)
        shown = initial.shown; hidden = initial.hidden; save()
    }
    /// The chip last chosen on this device, if it is still shown.
    var remembered: DiscoverList? {
        DiscoverList(rawValue: defaults.string(forKey: Self.selectedKey) ?? "").flatMap { shown.contains($0) ? $0 : nil }
    }
    func remember(_ list: DiscoverList) { defaults.set(list.rawValue, forKey: Self.selectedKey) }
}
