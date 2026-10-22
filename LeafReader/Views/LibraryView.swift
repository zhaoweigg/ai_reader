import SwiftUI

private enum LibraryFilter: String, CaseIterable { case all = "All books", reading = "Reading", favorites = "Favorites", finished = "Finished" }
private enum LibrarySort: String, CaseIterable { case recent = "Recently opened", added = "Recently added", title = "Title", author = "Author" }

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    let onImport: () -> Void
    let onOpen: (UUID) -> Void
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .recent
    @State private var format: BookFormat?
    @State private var deleting: Book?

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
    private var featured: Book? {
        library.books.filter { !$0.isFinished && $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
        ?? library.books.first
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("A little room\nto read.").font(.system(size: 39, weight: .regular, design: .serif)).tracking(-1.3)
                        Text("Your books. Your pace.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    if let book = featured, query.isEmpty, filter == .all, format == nil {
                        featuredBook(book)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Your library").font(.title2.weight(.semibold))
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
                            TextField("Find a title or author", text: $query).accessibilityIdentifier("librarySearch")
                            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search") }
                        }.padding(13).background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                        Picker("Library filter", selection: $filter) {
                            ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        if let format {
                            Button { self.format = nil } label: { Label("\(format.label) only", systemImage: "xmark.circle.fill").font(.caption) }
                        }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(library.books.isEmpty ? "Make room for a good book" : "No books here yet", systemImage: "book.closed")
                        } description: {
                            Text(query.isEmpty ? "Import a book from Files, iCloud Drive, or another app." : "Try another title or author, or change your filters.")
                        } actions: {
                            if library.books.isEmpty { Button("Import books", action: onImport).buttonStyle(.borderedProminent) }
                        }.padding(.vertical, 22)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 195), spacing: 24, alignment: .top)], alignment: .leading, spacing: 28) {
                            ForEach(visible) { book in
                                Button { onOpen(book.id) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        BookCover(book: book, coverURL: library.coverURL(book))
                                        Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        HStack {
                                            Text(book.format.label).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(.quaternary, in: .rect(cornerRadius: 4))
                                            Spacer(minLength: 2)
                                            if book.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(LeafStyle.accent) }
                                            if book.lastOpenedAt != nil { Text(book.progressLabel).font(.caption2).foregroundStyle(.secondary) }
                                        }
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(book.title), \(book.author), \(book.format.label)")
                                .accessibilityIdentifier("book-\(book.title)")
                                .contextMenu {
                                    Button("Read", systemImage: "book") { onOpen(book.id) }
                                    Button(book.isFavorite ? "Remove from favorites" : "Add to favorites", systemImage: book.isFavorite ? "heart.slash" : "heart") { library.toggleFavorite(book.id) }
                                    ShareLink(item: library.fileURL(book) ?? URL(fileURLWithPath: "/")) { Label("Share book", systemImage: "square.and.arrow.up") }
                                    Button("Remove book", systemImage: "trash", role: .destructive) { deleting = book }
                                }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "iphone")
                        Text("At home on your device. Available offline.")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .padding(.horizontal, 24).padding(.bottom, 20).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(LeafStyle.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(alignment: .center, spacing: 7) {
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(LeafStyle.accent)
                        Text("leaf").font(.system(size: 25, weight: .semibold, design: .serif))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityElement(children: .combine).accessibilityLabel("Leaf reader")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onImport) { Label("Add books", systemImage: "plus") }.buttonStyle(.borderedProminent).clipShape(Capsule())
                        .disabled(library.isImporting).accessibilityIdentifier("importBooks")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if library.isImporting { HStack { ProgressView(); Text("Importing books… \(library.importCount) added").font(.subheadline) }.padding().frame(maxWidth: .infinity).background(.regularMaterial) }
            }
            .confirmationDialog("Remove \(deleting?.title ?? "book")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Remove from library", role: .destructive) { if let deleting { library.remove(deleting.id) }; deleting = nil }
            } message: { Text("This removes the book and its bookmarks from Leaf. Your original file stays in Files.") }
        }
    }
    private func featuredBook(_ book: Book) -> some View {
        Button { onOpen(book.id) } label: {
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
            }.padding(24).frame(minHeight: 208).background(Color(hex: "#203C4D"), in: .rect(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("featuredBook")
    }
}
