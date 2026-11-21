import Foundation

/// The parts of Leaf every Ask Leaf chat can read, wherever it was opened: the
/// catalog, the bestseller lists, the web-novel charts, the library, saved places and the text of books
/// read so far. Each tool reads its store when it runs, loading what a screen
/// has not loaded yet, and never changes what that screen shows.
@MainActor struct ChatAppData {
    let catalog: ZLibraryStore
    let bestsellers: BestsellerStore
    let webNovels: WebNovelStore
    let library: LibraryStore
    /// The book open in this chat's reader; search_book covers it, so
    /// search_my_books leaves it out.
    var openBook: UUID? = nil
}

extension AgentTool {
    static let app: [AgentTool] = [
        AgentTool(name: "get_catalog_feed",
                  description: "Read a Z-Library catalog list: \"popular\" (most popular) or \"recommended\" (for the reader's connected account). Works even if Discover has not been opened; a list loaded earlier is reused unless refresh is true. Returns books with book_id for get_catalog_book.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["feed"], "properties": [
                    "feed": ["type": "string", "enum": ZLibraryFeed.allCases.map(\.rawValue)],
                    "refresh": ["type": "boolean", "description": "Load the list again instead of reusing it (default false)."],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Number of books to return (default 20)."]]]),
        AgentTool(name: "search_catalog",
                  description: "Search the Z-Library catalog by title, author or topic, without changing the reader's Discover screen. Returns the first page of matching editions with book_id for get_catalog_book.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["query"], "properties": [
                    "query": ["type": "string", "minLength": 1, "maxLength": 200],
                    "order": ["type": "string", "enum": [ZLibrarySearchOrder.bestMatch, .popular, .recentlyAdded, .year].map(\.rawValue),
                              "description": "Sort order (default bestmatch)."],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Number of books to return (default 10)."]]]),
        AgentTool(name: "get_catalog_book",
                  description: "Details and description of one catalog book, by a book_id from get_catalog_feed or search_catalog in this chat.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["book_id"], "properties": [
                    "book_id": ["type": "string", "minLength": 1, "maxLength": 200]]]),
        AgentTool(name: "get_bestsellers",
                  description: "Read a current hardcover bestseller list with each book's rank, author and short description. Works even if the bestseller screen has not been opened.",
                  parameters: ["type": "object", "additionalProperties": false, "properties": [
                    "source": ["type": "string", "enum": BestsellerSource.allCases.map(\.rawValue), "description": "indie (American Booksellers Association) or nyt (The New York Times). Default: the one the reader last viewed."],
                    "category": ["type": "string", "enum": BestsellerGenre.allCases.map(\.rawValue), "description": "Default: the one the reader last viewed."],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Number of books to return (default 15)."]]]),
        AgentTool(name: "get_web_novel_chart",
                  description: "Read a current 起点中文网 (Qidian) chart of Chinese web novels with each book's rank, author, category, length and synopsis. Works even if the 网文 screen has not been opened.",
                  parameters: ["type": "object", "additionalProperties": false, "properties": [
                    "chart": ["type": "string", "enum": WebNovelChart.allCases.map(\.rawValue),
                              "description": WebNovelChart.allCases.map { "\($0.rawValue): \($0.title), \($0.meaning)" }.joined(separator: "; ") + ". Default: the one the reader last viewed."],
                    "category": ["type": "string", "enum": WebNovelCategory.all.map(\.title), "description": "全站 is every category. Default: the one the reader last viewed."],
                    "period": ["type": "string", "enum": WebNovelPeriod.allCases.map(\.key), "description": "Only for rec. Default: the one the reader last viewed."],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 20, "description": "Number of books to return (default 20)."]]]),
        AgentTool(name: "list_library",
                  description: "List the books in the reader's Leaf library with reading progress, status, favorites and counts of bookmarks and highlights.",
                  parameters: ["type": "object", "additionalProperties": false, "properties": [
                    "status": ["type": "string", "enum": ["all", "reading", "finished", "not_started", "favorites"], "description": "Default all."],
                    "query": ["type": "string", "maxLength": 100, "description": "Only books whose title or author contains this."],
                    "sort": ["type": "string", "enum": ["recent", "title", "progress"], "description": "Default recent (last opened first)."],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Number of books to return (default 30)."]]]),
        AgentTool(name: "search_saved",
                  description: "Find the reader's bookmarks, highlights and notes across all books, newest first. Without terms, lists the newest.",
                  parameters: ["type": "object", "additionalProperties": false, "properties": [
                    "terms": ["type": "array", "maxItems": 6, "items": ["type": "string", "minLength": 1, "maxLength": 40],
                              "description": "Words to find in the saved text, note, chapter, label or book title. Case-insensitive."],
                    "kind": ["type": "string", "enum": ["all", "bookmarks", "highlights", "notes"], "description": "Default all."],
                    "book": ["type": "string", "maxLength": 100, "description": "Only books whose title or author contains this."],
                    "max_items": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Number of entries to return (default 15)."]]]),
        AgentTool(name: "search_my_books",
                  description: "Search the text of the reader's other books, each only up to where the reader stopped. Only books whose text Leaf prepared on this device (by opening Ask Leaf while reading them) can be searched; the result lists the books that cannot.",
                  parameters: ["type": "object", "additionalProperties": false, "required": ["terms"], "properties": [
                    "terms": ["type": "array", "minItems": 1, "maxItems": 6, "items": ["type": "string", "minLength": 1, "maxLength": 40],
                              "description": "Alternative words to find. Case-insensitive exact match; use exact characters for Chinese."],
                    "book": ["type": "string", "maxLength": 100, "description": "Only books whose title or author contains this."],
                    "max_results": ["type": "integer", "minimum": 1, "maximum": 12, "description": "Number of passages to return in all (default 8)."]]])
    ]
}

/// Runs the app-wide tools for one reply. Catalog books listed in this reply are
/// remembered so get_catalog_book can find them by book_id.
@MainActor final class AppChatTools {
    let data: ChatAppData
    private var catalogBooks: [String: ZLibraryBook] = [:]
    private var indexes: [String: BookTextIndex] = [:]
    /// Books whose saved text search_my_books reads in one call, most recently opened first.
    static let bookSearchLimit = 12

    init(_ data: ChatAppData) { self.data = data }

    /// The tools that may run: search_my_books returns book text, so it needs passage sharing.
    static func tools(sharePassages: Bool) -> [AgentTool] {
        sharePassages ? AgentTool.app : AgentTool.app.filter { $0.name != "search_my_books" }
    }

    /// Runs an app tool, or returns nil when `name` is not one. The step is the
    /// short line the trace and the reply's caption show.
    func run(_ name: String, _ arguments: [String: Any], sharePassages: Bool,
             activity: ((String) -> Void)?) async throws -> (output: String, step: String)? {
        switch name {
        case "get_catalog_feed": return try await feed(arguments, activity: activity)
        case "search_catalog": return try await searchCatalog(arguments, activity: activity)
        case "get_catalog_book": return try await catalogBook(arguments, activity: activity)
        case "get_bestsellers": return await bestsellers(arguments, activity: activity)
        case "get_web_novel_chart": return await webNovels(arguments, activity: activity)
        case "list_library": activity?("Looking at your library…"); return listLibrary(arguments)
        case "search_saved": activity?("Looking through your saved places…"); return searchSaved(arguments, sharePassages: sharePassages)
        case "search_my_books":
            guard sharePassages else { return (json(["error": "Searching book text needs passage sharing, which is off in AI settings."]), "book search off") }
            return searchBooks(arguments, activity: activity)
        default: return nil
        }
    }

    // MARK: Catalog

    private func feed(_ arguments: [String: Any], activity: ((String) -> Void)?) async throws -> (output: String, step: String) {
        guard let feed = (arguments["feed"] as? String).flatMap(ZLibraryFeed.init(rawValue:)) else {
            return (json(["error": "feed must be popular or recommended."]), "catalog feed: bad arguments")
        }
        activity?(feed == .popular ? "Loading popular books…" : "Loading recommendations…")
        let limit = Self.integer(arguments["max_items"], default: 20, in: 1...30)
        do {
            let (books, cached) = try await data.catalog.chatFeed(feed, refresh: arguments["refresh"] as? Bool ?? false)
            var body = listing(books, limit: limit)
            body["list"] = feed.title
            body["loaded"] = cached ? "earlier in this launch" : "just now"
            return (json(body), "read \(feed.title.lowercased()) (\(min(limit, books.count)))")
        } catch {
            try rethrowCancellation(error)
            return (json(["error": ZLibraryStore.chatErrorMessage(error)]), "\(feed.title.lowercased()) unavailable")
        }
    }
    private func searchCatalog(_ arguments: [String: Any], activity: ((String) -> Void)?) async throws -> (output: String, step: String) {
        let query = String((arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !query.isEmpty else { return (json(["error": "Provide query."]), "catalog search: bad arguments") }
        let order = (arguments["order"] as? String).flatMap(ZLibrarySearchOrder.init(rawValue:)) ?? .bestMatch
        let limit = Self.integer(arguments["max_items"], default: 10, in: 1...30)
        activity?("Searching the catalog for “\(query)”…")
        do {
            let books = try await data.catalog.chatSearch(query, order: order)
            var body = listing(books, limit: limit)
            body["search"] = query; body["sorted_by"] = order.title
            return (json(body), "searched the catalog for “\(query)” (\(min(limit, books.count)))")
        } catch {
            try rethrowCancellation(error)
            return (json(["error": ZLibraryStore.chatErrorMessage(error)]), "catalog search unavailable")
        }
    }
    private func catalogBook(_ arguments: [String: Any], activity: ((String) -> Void)?) async throws -> (output: String, step: String) {
        let id = arguments["book_id"] as? String ?? ""
        guard let book = catalogBooks[id] else {
            return (json(["error": "Unknown book_id. Use one returned by get_catalog_feed or search_catalog in this reply."]), "catalog book: unknown id")
        }
        activity?("Reading about \(book.title)…")
        let owned = Set(data.library.books.compactMap(\.catalogSource))
        do {
            let detailed = try await data.catalog.details(book, description: true)
            var item = Self.catalogItem(detailed, owned: owned.contains(detailed.sourceID))
            if let summary = detailed.summary, !summary.isEmpty { item["description"] = String(summary.prefix(4000)) }
            else { item["description_note"] = "The catalog has no description for this book." }
            if let isbns = detailed.isbns, !isbns.isEmpty { item["isbns"] = Array(isbns.prefix(4)) }
            return (json(item), "details for \(book.title)")
        } catch {
            try rethrowCancellation(error)
            var item = Self.catalogItem(book, owned: owned.contains(book.sourceID))
            item["error"] = "Details could not be loaded (\(ZLibraryStore.chatErrorMessage(error))). Answer from the listing."
            return (json(item), "details for \(book.title) unavailable")
        }
    }
    private func listing(_ books: [ZLibraryBook], limit: Int) -> [String: Any] {
        let owned = Set(data.library.books.compactMap(\.catalogSource))
        for book in books.prefix(limit) { catalogBooks[book.id] = book }
        var body: [String: Any] = ["total_items": books.count,
                                   "items": books.prefix(limit).enumerated().map { index, book in
                                       var item = Self.catalogItem(book, owned: owned.contains(book.sourceID)); item["rank"] = index + 1; return item }]
        if books.isEmpty { body["note"] = "The catalog returned no books." }
        return body
    }
    static func catalogItem(_ book: ZLibraryBook, owned: Bool) -> [String: Any] {
        var item = ChatScreen.catalogItem(book, rank: 0, owned: owned)
        item.removeValue(forKey: "rank"); item["book_id"] = book.id
        return item
    }

    // MARK: Bestsellers

    private func bestsellers(_ arguments: [String: Any], activity: ((String) -> Void)?) async -> (output: String, step: String) {
        let store = data.bestsellers
        let source = (arguments["source"] as? String).flatMap(BestsellerSource.init(rawValue:)) ?? store.source
        let genre = (arguments["category"] as? String).flatMap(BestsellerGenre.init(rawValue:)) ?? store.genre
        let limit = Self.integer(arguments["max_items"], default: 15, in: 1...30)
        activity?("Loading the \(source.title) bestsellers…")
        await store.load(source: source)
        guard let list = store.lists.first(where: { $0.source == source && $0.genre == genre }) else {
            let reason = store.errors[source] ?? "The list is not available right now."
            return (json(["error": reason, "source": source.title, "category": genre.title]), "\(source.title) bestsellers unavailable")
        }
        var body: [String: Any] = [
            "source": source.attribution, "category": genre.caption, "list_date": list.published, "total_items": list.books.count,
            "items": list.books.prefix(limit).map { book -> [String: Any] in
                var item: [String: Any] = ["rank": book.rank, "title": book.title, "author": book.author]
                if !book.summary.isEmpty { item["description"] = String(book.summary.prefix(600)) }
                if data.library.books.contains(where: { BestsellerText.compatibleTitles($0.title, book.title) && BestsellerText.normalized($0.author) == BestsellerText.normalized(book.author) }) {
                    item["in_library"] = true
                }
                return item
            }]
        if let error = store.errors[source] { body["status"] = "Showing the list loaded earlier; refreshing failed: \(error)" }
        return (json(body), "read \(source.title) \(genre.title.lowercased()) bestsellers (\(min(limit, list.books.count)))")
    }

    // MARK: Web novels

    private func webNovels(_ arguments: [String: Any], activity: ((String) -> Void)?) async -> (output: String, step: String) {
        let store = data.webNovels
        let selection = WebNovelSelection(
            chart: (arguments["chart"] as? String).flatMap(WebNovelChart.init(rawValue:)) ?? store.chart,
            category: (arguments["category"] as? String).flatMap { title in WebNovelCategory.all.first { $0.title == title }?.id } ?? store.category,
            period: (arguments["period"] as? String).flatMap { key in WebNovelPeriod.allCases.first { $0.key == key } } ?? store.period)
        let limit = Self.integer(arguments["max_items"], default: 20, in: 1...20)
        activity?("Loading 起点’s \(selection.chart.title)…")
        await store.load(selection)
        guard let list = store.list(selection) else {
            let reason = store.errors[selection] ?? "The chart is not available right now."
            return (json(["error": reason, "source": "起点中文网", "chart": selection.caption]), "\(selection.chart.title) unavailable")
        }
        var body = ChatScreen.webNovelChart(list, library: data.library, limit: limit, synopsis: 600)
        if let error = store.errors[selection] { body["status"] = "Showing the chart loaded earlier; refreshing failed: \(error)" }
        return (json(body), "read 起点 \(selection.chart.title) (\(min(limit, list.books.count)))")
    }

    // MARK: Library and saved places

    private func books(matching query: String?) -> [Book] {
        let query = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return data.library.books }
        return data.library.books.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query) }
    }
    private func listLibrary(_ arguments: [String: Any]) -> (output: String, step: String) {
        var books = books(matching: arguments["query"] as? String)
        switch arguments["status"] as? String {
        case "reading": books = books.filter { !$0.isFinished && $0.lastOpenedAt != nil }
        case "finished": books = books.filter(\.isFinished)
        case "not_started": books = books.filter { $0.lastOpenedAt == nil }
        case "favorites": books = books.filter(\.isFavorite)
        default: break
        }
        switch arguments["sort"] as? String {
        case "title": books.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "progress": books.sort { $0.progress > $1.progress }
        default: books.sort { ($0.lastOpenedAt ?? .distantPast, $0.importedAt) > ($1.lastOpenedAt ?? .distantPast, $1.importedAt) }
        }
        let limit = Self.integer(arguments["max_items"], default: 30, in: 1...100)
        var body: [String: Any] = ["total_items": books.count, "library_size": data.library.books.count,
                                   "items": books.prefix(limit).enumerated().map { ChatScreen.libraryItem($1, rank: $0 + 1) }]
        if books.count > limit { body["note"] = "Showing \(limit) of \(books.count); ask for more with max_items." }
        return (json(body), "listed the library (\(min(limit, books.count)))")
    }
    private func searchSaved(_ arguments: [String: Any], sharePassages: Bool) -> (output: String, step: String) {
        let terms = ReadingAgentToolbox.terms(arguments).map { $0.lowercased() }
        let books = books(matching: arguments["book"] as? String)
        let kind = arguments["kind"] as? String ?? "all"
        var entries: [ChatScreen.SavedEntry] = []
        if kind == "all" || kind == "bookmarks" { entries += ChatScreen.savedEntries(books, highlights: false) }
        if kind != "bookmarks" { entries += ChatScreen.savedEntries(books, highlights: true).filter { kind != "notes" || $0.annotation?.hasNote == true } }
        entries.sort { Self.saved($0) > Self.saved($1) }
        if !terms.isEmpty {
            entries = entries.filter { entry in
                // Highlighted text and notes are matched only when they may be shared.
                var fields = [entry.book.title, entry.book.author, entry.bookmark?.label ?? "", entry.annotation?.chapter ?? ""]
                if sharePassages, let annotation = entry.annotation { fields += [annotation.text, annotation.note] }
                let text = fields.joined(separator: "\n").lowercased()
                return terms.contains { text.contains($0) }
            }
        }
        let limit = Self.integer(arguments["max_items"], default: 15, in: 1...50)
        var body: [String: Any] = ["total_items": entries.count,
                                   "items": entries.prefix(limit).enumerated().map { ChatScreen.savedItem($1, rank: $0 + 1, sharePassages: sharePassages, length: 600) }]
        if !sharePassages { body["note_on_passages"] = "Highlighted text and notes are hidden and not searched because passage sharing is off." }
        return (json(body), terms.isEmpty ? "listed saved places (\(min(limit, entries.count)))" : "searched saved places (\(entries.count))")
    }
    private static func saved(_ entry: ChatScreen.SavedEntry) -> Date { entry.bookmark?.createdAt ?? entry.annotation?.createdAt ?? .distantPast }

    // MARK: Other books' text

    private func searchBooks(_ arguments: [String: Any], activity: ((String) -> Void)?) -> (output: String, step: String) {
        let terms = ReadingAgentToolbox.terms(arguments)
        guard !terms.isEmpty else { return (json(["error": "Provide at least one term in terms."]), "book search: bad arguments") }
        guard let root = data.library.disk?.root else { return (json(["error": "The library is not available."]), "book search unavailable") }
        let quoted = terms.map { "“\($0)”" }.joined(separator: ", ")
        activity?("Searching your books for \(quoted)…")
        let limit = Self.integer(arguments["max_results"], default: 8, in: 1...12)
        let candidates = books(matching: arguments["book"] as? String)
            .filter { $0.id != data.openBook && !$0.locator.isEmpty }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        var hits: [(book: Book, hit: BookTextIndex.Hit)] = [], searched: [[String: Any]] = [], unavailable: [String] = []
        for book in candidates {
            let directory = root.appendingPathComponent("ChatIndex/\(book.fingerprint)/v1", isDirectory: true)
            guard let position = BookTextIndex.savedPosition(in: directory), position.covers(locator: book.locator, progress: book.progress) else {
                unavailable.append(book.title); continue
            }
            guard searched.count < Self.bookSearchLimit else { continue }
            let index = indexes[book.fingerprint] ?? BookTextIndex(savedIn: directory)
            indexes[book.fingerprint] = index
            let coverage = index.loadSaved(through: position.boundary)
            let found = index.search(terms, within: position.boundary, limit: min(limit, 4)).hits
            hits += found.map { (book, $0) }
            searched.append(["book": book.title, "author": book.author, "matches": found.count,
                             "searched_to_percent": Int((position.progress * 100).rounded(.down)), "complete": coverage.complete])
        }
        hits.sort { $0.hit.terms > $1.hit.terms }
        var body: [String: Any] = [
            "results": hits.prefix(limit).map { ["book": $0.book.title, "author": $0.book.author, "chapter": $0.hit.chapter, "text": $0.hit.text] },
            "books_searched": searched,
            "note": "Each book is searched only up to where the reader was when Ask Leaf last prepared it."
        ]
        if !unavailable.isEmpty {
            body["books_not_searchable"] = Array(unavailable.prefix(20))
            body["not_searchable_note"] = "These books' text is not prepared on this device. Opening Ask Leaf while reading one prepares it."
        }
        if candidates.count - unavailable.count > Self.bookSearchLimit {
            body["more_books"] = "Only the \(Self.bookSearchLimit) most recently opened books were searched; name a book to search it."
        }
        return (json(body), "searched your books for \(quoted) (\(min(limit, hits.count)))")
    }

    // MARK: Helpers

    private func rethrowCancellation(_ error: Error) throws {
        if ZLibraryStore.isCancellation(error) || Task.isCancelled { throw CancellationError() }
    }
    private func json(_ value: Any) -> String { ReadingAgentToolbox.json(value) }
    static func integer(_ value: Any?, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        let number = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? fallback
        return min(range.upperBound, max(range.lowerBound, number))
    }
}
