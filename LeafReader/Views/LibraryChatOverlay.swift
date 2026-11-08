import SwiftUI

/// Ask Leaf on one of the app's tabs: the general conversation or a book's,
/// opened from the floating button. Each tab owns one; it closes when the tab does.
@MainActor final class TabChat: ObservableObject {
    @Published private(set) var session: ReaderChatSession?
    @Published private(set) var book: Book?
    @Published var isMoving = false
    @Published var choosingConversation = false
    var conversation: String { book?.fingerprint ?? "general" }
    func open(_ book: Book?, directory: URL?) {
        // Close the previous owner before creating a second session for its database.
        guard session?.flush() != false else { return }
        session?.close()
        self.book = book
        session = ReaderChatSession(directory: directory, conversation: book?.fingerprint ?? "leaf.library.general.v1")
    }
    func close() { session?.close(); session = nil; book = nil }
}

/// The floating Ask Leaf button and panel over a tab, whose screen the chat can read.
struct TabChatHost: ViewModifier {
    @ObservedObject var chat: TabChat
    /// Identifies the tap-away area that ends moving the button.
    let finishMovingIdentifier: String
    let screen: @MainActor () -> ChatScreen
    var onOpen: () -> Void = {}
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewportHeight: CGFloat = 0
    private var directory: URL? { library.disk?.root.appendingPathComponent("ChatHistory", isDirectory: true) }

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size) { _, size in viewportHeight = size.height }
                }
            }
            .ignoresSafeArea(.keyboard)
            .overlay {
                if let session = chat.session {
                    LibraryChatOverlay(session: session, book: chat.book, fullHeight: viewportHeight, screen: screen,
                        onClose: chat.close, onChoose: { chat.choosingConversation = true })
                } else {
                    if chat.isMoving {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { chat.isMoving = false }
                            .accessibilityLabel("Finish moving Ask Leaf").accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier(finishMovingIdentifier)
                            .accessibilityAction { chat.isMoving = false }
                    }
                    ReaderChatLauncher(isMoving: $chat.isMoving, location: .library) {
                        onOpen(); chat.open(nil, directory: directory)
                    }
                }
            }
            .sheet(isPresented: $chat.choosingConversation) {
                LibraryChatConversationPicker(books: library.books.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) },
                    selected: chat.conversation, onChoose: { chat.open($0, directory: directory) })
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { chat.isMoving = false; chat.session?.flush() }
            }
            .onChange(of: library.books.map(\.fingerprint)) { _, fingerprints in
                if let book = chat.book, !fingerprints.contains(book.fingerprint) { chat.open(nil, directory: directory) }
            }
            .onDisappear { chat.close(); chat.isMoving = false }
    }
}

/// Opens history without opening a renderer or loading a book's chapters.
struct LibraryChatOverlay: View {
    @ObservedObject var session: ReaderChatSession
    let book: Book?
    let fullHeight: CGFloat
    /// The tab's screen, read by the agent's view tools when a reply needs it.
    var screen: (@MainActor () -> ChatScreen)?
    let onClose: () -> Void
    let onChoose: () -> Void
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var settings: AISettingsStore
    @State private var panel: Panel?
    private enum Panel: String, Identifiable { case settings, button; var id: String { rawValue } }

    var body: some View {
        ResizableChatPanel(session: session, location: .library, fullHeight: fullHeight, bookTitle: book?.title ?? "",
            context: book == nil ? .general : .libraryBook, onChooseConversation: onChoose,
            onClose: onClose, onSettings: { session.stop(); panel = .settings }, onButtonSettings: { panel = .button },
            onSend: {
                session.send(settings: settings, missingContextNotice: nil, screen: screen?()) {
                    // A quoted draft already has its own snapshot. Otherwise only
                    // the selected book's metadata is sent, never an unseen passage.
                    book.map { ReadingChatContext(title: $0.title, author: $0.author, chapter: "", text: "", source: "library_metadata", locator: "") }
                }
            })
        .sheet(item: $panel) { value in
            NavigationStack {
                Group {
                    switch value {
                    case .settings: AISettingsView()
                    case .button: ReaderChatButtonSettings()
                    }
                }.toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Close") { panel = nil } }
                }
            }.environment(\.leafTheme, theme).tint(theme.accent)
        }
    }
}

struct LibraryChatConversationPicker: View {
    let books: [Book]
    let selected: String
    let onChoose: (Book?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.leafTheme) private var theme
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("General chat", author: "Separate from your book conversations", book: nil)
                }.listRowBackground(theme.surface)
                Section("Book conversations") {
                    ForEach(books.filter { query.isEmpty || "\($0.title) \($0.author)".localizedCaseInsensitiveContains(query) }) { book in
                        choice(book.title, author: book.author, book: book)
                    }
                }.listRowBackground(theme.surface)
            }.leafFormStyle().searchable(text: $query, prompt: "Find a book")
                .navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .toolbarBackground(theme.canvas, for: .navigationBar)
        }.environment(\.leafTheme, theme).tint(theme.accent)
    }
    private func choice(_ title: String, author: String, book: Book?) -> some View {
        Button { onChoose(book); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(theme.foreground)
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected == (book?.fingerprint ?? "general") { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
            }.frame(minHeight: 44)
        }.accessibilityIdentifier(book.map { "chatBook-\($0.title)" } ?? "chatGeneral")
    }
}

/// What each tab shows, in on-screen order, for the agent's view tools.
extension ChatScreen {
    private static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
    private static func percent(_ fraction: Double) -> Int { Int((min(1, max(0, fraction)) * 100).rounded(.down)) }
    private static func listing(_ screen: String, list: String, items: [[String: Any]], total: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var view: [String: Any] = ["screen": screen, "list": list, "items": items, "total_items": total]
        if items.count < total { view["note"] = "Showing the top \(items.count) of \(total); ask for more with max_items." }
        return view.merging(extra) { _, new in new }
    }

    // MARK: Discover

    /// Discover's books as its grid shows them, row by row from the top left.
    @MainActor static func discover(_ catalog: ZLibraryStore, library: LibraryStore) -> ChatScreen {
        ChatScreen(name: "Discover", view: { limit, _ in
            catalogView(catalog.books, query: catalog.activeQuery, feed: catalog.feed, order: catalog.searchOrder,
                        status: catalogStatus(catalog), canLoadMore: catalog.canLoadMore,
                        owned: Set(library.books.compactMap(\.catalogSource)), limit: limit,
                        open: catalog.viewingBook.map(catalog.latest))
        }, details: { rank, _ in
            guard catalog.books.indices.contains(rank - 1) else { return nil }
            let book = try await catalog.details(catalog.books[rank - 1], description: true)
            var item = catalogItem(book, rank: rank, owned: library.books.contains { $0.catalogSource == book.sourceID })
            if let summary = book.summary, !summary.isEmpty { item["description"] = summary }
            else { item["description_note"] = "The catalog has no description for this book." }
            return item
        })
    }
    static func catalogView(_ books: [ZLibraryBook], query: String, feed: ZLibraryFeed, order: ZLibrarySearchOrder, status: [String],
                            canLoadMore: Bool, owned: Set<String>, limit: Int, open: ZLibraryBook? = nil) -> [String: Any] {
        var extra: [String: Any] = ["more_available": canLoadMore, "layout": "grid of 3 columns; ranks run row by row from the top left"]
        if !query.isEmpty { extra["search"] = query; extra["sorted_by"] = order.title }
        if !status.isEmpty { extra["status"] = status }
        if let open {
            // The details page covers the grid: “this book” means this one.
            let rank = (books.firstIndex { $0.id == open.id }).map { $0 + 1 }
            var item = catalogItem(open, rank: rank ?? 0, owned: owned.contains(open.sourceID))
            if rank == nil { item.removeValue(forKey: "rank") }
            if let summary = open.summary, !summary.isEmpty { item["description"] = summary }
            else if open.summary == nil { item["description_note"] = "Still loading; call get_item_details with its rank for the description." }
            else { item["description_note"] = "The catalog has no description for this book." }
            extra["open_book"] = item
            extra["open_book_note"] = "The reader is on this book's details page, which covers the list. Questions about \"this book\" mean open_book; items is the list behind it."
        }
        let items = books.prefix(limit).enumerated().map { index, book in catalogItem(book, rank: index + 1, owned: owned.contains(book.sourceID)) }
        return listing("Discover", list: query.isEmpty ? feed.title : "Search results", items: items, total: books.count, extra: extra)
    }
    static func catalogItem(_ book: ZLibraryBook, rank: Int, owned: Bool) -> [String: Any] {
        var item: [String: Any] = ["rank": rank, "title": book.title, "author": book.author.isEmpty ? "Unknown author" : book.author]
        for (key, value) in [("year", book.year), ("language", book.language), ("format", book.fileExtension.uppercased()), ("size", book.size)] where !value.isEmpty {
            item[key] = value
        }
        if let rating = book.rating { item["rating"] = rating }
        if let count = book.ratingCount { item["rating_count"] = count }
        if owned { item["in_library"] = true }
        return item
    }
    @MainActor private static func catalogStatus(_ catalog: ZLibraryStore) -> [String] {
        var status: [String] = []
        if catalog.loading { status.append(catalog.books.isEmpty ? "loading" : "loading more") }
        if catalog.recommendationConnectionRequired { status.append("Recommendations need a connected Z-Library account.") }
        else if let error = catalog.error { status.append("Could not load: \(error.prefix(200))") }
        if catalog.showingSavedResults { status.append("previously loaded results") }
        if catalog.isPreview { status.append("preview catalog") }
        return status
    }

    // MARK: Bookmarks

    /// A bookmark or highlight on the Bookmarks screen.
    struct SavedEntry {
        let book: Book
        let bookmark: BookBookmark?
        let annotation: BookAnnotation?
    }
    /// The Bookmarks screen's rows: its books in library order, each newest first.
    static func savedEntries(_ books: [Book], highlights: Bool) -> [SavedEntry] {
        books.flatMap { book -> [SavedEntry] in
            highlights
                ? book.annotations.sorted { $0.createdAt > $1.createdAt }.map { SavedEntry(book: book, bookmark: nil, annotation: $0) }
                : book.bookmarks.sorted { $0.createdAt > $1.createdAt }.map { SavedEntry(book: book, bookmark: $0, annotation: nil) }
        }
    }
    @MainActor static func bookmarks(_ library: LibraryStore, highlights: @escaping @MainActor () -> Bool) -> ChatScreen {
        ChatScreen(name: "Bookmarks", view: { limit, share in
            savedView(savedEntries(library.books, highlights: highlights()), highlights: highlights(), sharePassages: share, limit: limit)
        }, details: { rank, share in
            let entries = savedEntries(library.books, highlights: highlights())
            guard entries.indices.contains(rank - 1) else { return nil }
            return savedItem(entries[rank - 1], rank: rank, sharePassages: share, length: 4000)
        })
    }
    static func savedView(_ entries: [SavedEntry], highlights: Bool, sharePassages: Bool, limit: Int) -> [String: Any] {
        var extra: [String: Any] = [:]
        if highlights, !sharePassages { extra["note_on_passages"] = "Highlighted text and notes are hidden because passage sharing is off." }
        let items = entries.prefix(limit).enumerated().map { index, entry in savedItem(entry, rank: index + 1, sharePassages: sharePassages, length: 280) }
        return listing("Bookmarks", list: highlights ? "Highlights & notes" : "Bookmarks", items: items, total: entries.count, extra: extra)
    }
    static func savedItem(_ entry: SavedEntry, rank: Int, sharePassages: Bool, length: Int) -> [String: Any] {
        var item: [String: Any] = ["rank": rank, "book": entry.book.title, "author": entry.book.author]
        if let bookmark = entry.bookmark {
            item["kind"] = "bookmark"; item["label"] = String(bookmark.label.prefix(300))
            item["percent_through_book"] = percent(bookmark.fraction); item["saved"] = day(bookmark.createdAt)
        } else if let annotation = entry.annotation {
            item["kind"] = annotation.hasNote ? "note" : "highlight"; item["color"] = annotation.color.title
            if !annotation.chapter.isEmpty { item["chapter"] = String(annotation.chapter.prefix(300)) }
            item["percent_through_book"] = percent(annotation.fraction); item["saved"] = day(annotation.createdAt)
            if sharePassages {
                item["text"] = String(annotation.text.prefix(length))
                if annotation.hasTextNote { item["note"] = String(annotation.note.prefix(length)) }
                if annotation.voiceNote != nil { item["voice_note"] = "Audio attached; no transcript is available." }
            }
        }
        return item
    }

    // MARK: Library

    /// The Library's books in the order its list shows them, after search, filter and sort.
    @MainActor static func library(_ books: @escaping @MainActor () -> [Book], list: @escaping @MainActor () -> String) -> ChatScreen {
        ChatScreen(name: "Library", view: { limit, _ in
            libraryView(books(), list: list(), limit: limit)
        }, details: { rank, share in
            let books = books()
            guard books.indices.contains(rank - 1) else { return nil }
            let book = books[rank - 1]
            var item = libraryItem(book, rank: rank)
            let recent = savedEntries([book], highlights: true).prefix(5)
            if !recent.isEmpty {
                item["recent_highlights"] = recent.enumerated().map { savedItem($1, rank: $0 + 1, sharePassages: share, length: 600) }
            }
            return item
        })
    }
    static func libraryView(_ books: [Book], list: String, limit: Int) -> [String: Any] {
        let items = books.prefix(limit).enumerated().map { index, book in libraryItem(book, rank: index + 1) }
        return listing("Library", list: list, items: items, total: books.count)
    }
    static func libraryItem(_ book: Book, rank: Int) -> [String: Any] {
        var item: [String: Any] = ["rank": rank, "title": book.title, "author": book.author, "format": book.format.label,
                                   "progress_percent": percent(book.progress),
                                   "status": book.isFinished ? "finished" : book.lastOpenedAt == nil ? "not started" : "reading"]
        if book.isFavorite { item["favorite"] = true }
        if let opened = book.lastOpenedAt { item["last_opened"] = day(opened) }
        if !book.bookmarks.isEmpty { item["bookmarks"] = book.bookmarks.count }
        if !book.annotations.isEmpty { item["highlights"] = book.annotations.count }
        return item
    }
}
