import SwiftUI

private enum LibraryFilter: String, CaseIterable { case all = "All books", reading = "Reading", favorites = "Favorites", finished = "Finished" }
private enum LibrarySort: String, CaseIterable { case recent = "Recently opened", added = "Recently added", title = "Title", author = "Author" }

struct LibraryView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var sync: ICloudSync
    @Environment(\.scenePhase) private var scenePhase
    let onImport: () -> Void
    let onOpen: (UUID) -> Void
    let onDiscover: (ZLibraryFeed) -> Void
    let onSearchCatalog: (String) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .recent
    @State private var format: BookFormat?
    @State private var deleting: Book?
    @StateObject private var chat = TabChat()
    @State private var catalogBook: ZLibraryBook?
    @State private var catalogMatches: [ZLibraryBook] = []

    private var visible: [Book] {
        library.books.filter { book in
            let matchesQuery = query.isEmpty || "\(book.title) \(book.author) \(book.format.label)".localizedCaseInsensitiveContains(query)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .reading: matchesFilter = book.lastOpenedAt != nil && !book.isFinished
            case .favorites: matchesFilter = book.isFavorite
            case .finished: matchesFilter = book.isFinished
            }
            return matchesQuery && matchesFilter && (format == nil || format == book.format)
        }.sorted { lhs, rhs in
            switch sort {
            case .recent: return (lhs.lastOpenedAt ?? .distantPast) > (rhs.lastOpenedAt ?? .distantPast)
            case .added: return lhs.importedAt > rhs.importedAt
            case .title: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .author: return lhs.author.localizedStandardCompare(rhs.author) == .orderedAscending
            }
        }
    }
    private var shelf: [ZLibraryBook] {
        catalog.shelf.filter { book in !library.books.contains { $0.catalogSource == book.sourceID } }
    }
    private var featured: Book? {
        library.books.filter { !$0.isFinished && $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
        ?? library.books.first
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("A little room\nto read.").font(.system(size: 39, weight: .regular, design: .serif)).tracking(-1.3)
                        Text("Your books. Your pace.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    if let book = featured, query.isEmpty, filter == .all, format == nil {
                        featuredBook(book)
                    }
                    if !shelf.isEmpty, query.isEmpty, filter == .all, format == nil {
                        discoverShelf
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Your library").font(.title2.weight(.semibold)).id("libraryHeader")
                            Text("\(library.books.count)").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Picker("Sort books", selection: $sort) { ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                Picker("Format", selection: $format) {
                                    Text("All formats").tag(Optional<BookFormat>.none)
                                    ForEach(BookFormat.allCases.filter { f in library.books.contains { $0.format == f } }) { Text($0.label).tag(Optional($0)) }
                                }
                            } label: {
                                Image(systemName: format == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                                    .font(.title3).frame(width: 44, height: 44)
                            }.accessibilityLabel("Sort and filter books")
                        }
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Find a title or author", text: $query).focused($searchFocused).accessibilityIdentifier("librarySearch")
                            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search").accessibilityIdentifier("libraryClearSearch") }
                        }.padding(13).background(theme.surface, in: .rect(cornerRadius: 12))
                        Picker("Library filter", selection: $filter) {
                            ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        if let format {
                            Button { self.format = nil } label: { Label("\(format.label) only", systemImage: "xmark.circle.fill").font(.caption) }
                        }
                    }
                    if sync.isConnected, cloudOnly > 0 {
                        Label("\(cloudOnly) book\(cloudOnly == 1 ? " is" : "s are") in iCloud Drive. Tap a book to download it.", systemImage: "icloud")
                            .font(.footnote).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surface, in: .rect(cornerRadius: 12)).accessibilityIdentifier("libraryCloudBanner")
                    }
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(library.books.isEmpty ? "Make room for a good book" : "No books here yet", systemImage: "book.closed")
                        } description: {
                            Text(query.isEmpty ? "Import a book from Files, iCloud Drive, or another app." : "Try another title or author, or change your filters.")
                        } actions: {
                            if library.books.isEmpty { Button("Import books", action: onImport).buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent) }
                        }.padding(.vertical, 22)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 195), spacing: 24, alignment: .top)], alignment: .leading, spacing: 28) {
                            ForEach(visible) { book in
                                Button { openBook(book.id) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        BookCover(book: book, coverURL: library.coverURL(book))
                                            .overlay(alignment: .topTrailing) { cloudBadge(book) }
                                        Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        HStack {
                                            Text(book.format.label).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(.quaternary, in: .rect(cornerRadius: 4))
                                            Spacer(minLength: 2)
                                            if book.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(theme.accent) }
                                            if book.lastOpenedAt != nil { Text(book.progressLabel).font(.caption2).foregroundStyle(.secondary) }
                                        }
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(book.title), \(book.author), \(book.format.label)")
                                .accessibilityIdentifier("book-\(book.title)")
                                .contextMenu {
                                    Button("Read", systemImage: "book") { openBook(book.id) }
                                    Button(book.isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: book.isFavorite ? "heart.slash" : "heart") { library.toggleFavorite(book.id) }
                                    ShareLink(item: library.fileURL(book) ?? URL(fileURLWithPath: "/")) { Label("Share book", systemImage: "square.and.arrow.up") }
                                    Button("Remove book", systemImage: "trash", role: .destructive) { deleting = book }
                                }
                            }
                        }
                    }
                    if !query.isEmpty { catalogSearch }
                    HStack(spacing: 6) {
                        Image(systemName: "iphone")
                        Text("At home on your device. Available offline.")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .padding(.horizontal, 24).padding(.bottom, 20).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
            }
            // Searching hides the featured book and shelf; keep the search field in view.
            .onChange(of: query.isEmpty) { _, empty in if !empty { proxy.scrollTo("libraryHeader", anchor: .top) } }
            }
            .background(theme.canvas)
            .toolbarBackground(theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(alignment: .center, spacing: 7) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(theme.accent)
                        Text("leaf").font(.system(size: 25, weight: .semibold, design: .serif))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .combine).accessibilityLabel("Leaf reader")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onImport) { Label("Import", systemImage: "plus") }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).clipShape(Capsule())
                        .disabled(library.isImporting).accessibilityIdentifier("importBooks")
                }
            }
            .task(id: catalog.connected) { await catalog.loadShelf() }
            .task(id: query) {
                catalogMatches = []
                guard !query.trimmingCharacters(in: .whitespaces).isEmpty, visible.isEmpty else { return }
                // Wait for a pause in typing before asking the catalog.
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                let matches = await catalog.searchPreview(query)
                if !Task.isCancelled { catalogMatches = matches }
            }
            .sheet(item: $catalogBook) { book in
                NavigationStack {
                    ZLibraryBookView(book: book, close: { catalogBook = nil })
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Close", systemImage: "xmark") { catalogBook = nil }.labelStyle(.iconOnly).accessibilityIdentifier("closeCatalogBook")
                            }
                        }
                }.environment(\.leafTheme, theme).tint(theme.accent)
            }
            .safeAreaInset(edge: .bottom) {
                if library.isImporting { HStack { ProgressView(); Text("Importing books… \(library.importCount) added").font(.subheadline) }.padding().frame(maxWidth: .infinity).background(.regularMaterial) }
            }
            .alert("Remove \(deleting?.title ?? "book")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { book in
                Button("Remove from library", role: .destructive) { library.remove(book.id); deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { _ in Text(sync.isConnected
                ? "This removes the book, its bookmarks and highlights from Leaf on all your devices and from iCloud Drive. Your original file stays in Files."
                : "This removes the book and its bookmarks from Leaf. Your original file stays in Files.") }
        }
        .modifier(TabChatHost(chat: chat, finishMovingIdentifier: "finishMovingLibraryChatButton", screen: {
            ChatScreen.library({ visible }, list: {
                [filter.rawValue, format?.label, query.isEmpty ? nil : "matching “\(query)”", "sorted by \(sort.rawValue.lowercased())"]
                    .compactMap { $0 }.joined(separator: " · ")
            })
        }, onOpen: { searchFocused = false }))
    }
    private func openBook(_ id: UUID) { chat.close(); onOpen(id) }
    private var cloudOnly: Int { library.books.filter { !library.isDownloaded($0) }.count }
    /// Books synced from iCloud Drive whose files are not on this device yet.
    @ViewBuilder private func cloudBadge(_ book: Book) -> some View {
        if sync.downloading.contains(book.id) {
            ProgressView().padding(7).background(.thinMaterial, in: .circle).padding(6)
        } else if sync.isConnected, !library.isDownloaded(book) {
            Image(systemName: "icloud.and.arrow.down").font(.caption.weight(.semibold)).foregroundStyle(.blue)
                .padding(7).background(.thinMaterial, in: .circle).padding(6)
                .accessibilityLabel("In iCloud Drive").accessibilityIdentifier("cloudBadge-\(book.title)")
        }
    }
    private var discoverShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(catalog.shelfFeed == .recommended ? "Recommended for you" : "Popular on Z-Library").font(.title2.weight(.semibold))
                    .accessibilityIdentifier("discoverShelfTitle")
                Spacer()
                Button("See all") { onDiscover(catalog.shelfFeed) }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("discoverSeeAll")
            }
            catalogRow(shelf, identifier: "discoverShelfBook")
        }
    }
    private var catalogSearch: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { searchFocused = false; onSearchCatalog(query) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(theme.accent).frame(width: 42, height: 42)
                        .background(theme.accent.opacity(0.1), in: .rect(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Search Z-Library for “\(query)”").font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text("Find it and add it to your library").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 14)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("librarySearchZLibrary")
            if visible.isEmpty && !catalogMatches.isEmpty {
                Text("Matches on Z-Library").font(.subheadline).foregroundStyle(.secondary)
                catalogRow(catalogMatches, identifier: "librarySearchMatch")
            }
        }
    }
    private func catalogRow(_ books: [ZLibraryBook], identifier: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(books) { book in
                    Button { searchFocused = false; catalogBook = book } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZLibraryCover(book: book)
                            Text(book.title).font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Text(book.author.isEmpty ? "Unknown author" : book.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(width: 96, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("\(identifier)-\(book.remoteID)")
                }
            }.padding(.horizontal, 24)
        }.padding(.horizontal, -24)
    }
    private func featuredBook(_ book: Book) -> some View {
        Button { openBook(book.id) } label: {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(book.lastOpenedAt == nil ? "A good place to begin" : "Continue reading").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                    Text(book.title).font(.system(size: 24, weight: .regular, design: .serif)).foregroundStyle(.white).lineLimit(3)
                    Text(book.author).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 6) { Text(book.lastOpenedAt == nil ? "Open book" : book.progressLabel); Image(systemName: "arrow.up.right") }
                        .font(.caption.weight(.semibold)).foregroundStyle(Color(hex: "#B8DFD4"))
                    if book.lastOpenedAt != nil { ProgressView(value: book.progress).tint(Color(hex: "#B8DFD4")) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                BookCover(book: book, coverURL: library.coverURL(book)).frame(width: 105).rotationEffect(.degrees(5))
            }.padding(24).frame(minHeight: 208).background(theme.featured, in: .rect(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("featuredBook")
    }
}
