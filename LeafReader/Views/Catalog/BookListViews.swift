import SwiftUI

extension BookReviewQuery {
    init(_ book: ListedBook) { self.init(title: book.title, author: book.author, isbns: book.isbns) }
}

/// A listed book's cover, through the shared cover cache: it keeps covers on disk and sends
/// 豆瓣's image servers the Referer they require (AsyncImage cannot).
struct ListedBookCover: View {
    @Environment(\.leafTheme) private var theme
    let book: ListedBook
    @State private var loaded: (url: URL, image: UIImage)?
    private var image: UIImage? {
        guard let url = book.cover else { return nil }
        return loaded?.url == url ? loaded?.image : ZLibraryImages.shared.cachedImage(url)
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(theme.surface)
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { placeholder }
        }.aspectRatio(2 / 3, contentMode: .fit).clipShape(.rect(cornerRadius: 4))
            .accessibilityElement(children: .ignore).accessibilityLabel(book.title + " cover")
            .task(id: book.cover) {
                #if DEBUG
                if UITesting.flag(.bookListsMock) { return }
                #endif
                guard let url = book.cover else { loaded = nil; return }
                guard loaded?.url != url else { return }
                let image = await ZLibraryImages.shared.image(url)
                guard !Task.isCancelled else { return }
                loaded = image.map { (url, $0) }
            }
    }
    private var placeholder: some View {
        Image(systemName: book.source == .prizes ? "rosette" : "book.closed").font(.title3).foregroundStyle(theme.accent)
    }
}

/// One of the 豆瓣, Gutenberg, Apple Books, prize or Open Library lists, a row per book.
struct BookListCharts: View {
    @EnvironmentObject private var lists: BookListStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.leafTheme) private var theme
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(lists.source.fullName).font(.system(size: 32, design: .serif)).accessibilityIdentifier("bookListsHeading")
                Spacer()
                if !lists.chart.isBundled {
                    Button("Refresh list", systemImage: "arrow.clockwise") { Task { await lists.load(force: true) } }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(lists.isLoading)
                        .accessibilityIdentifier("bookListsRefresh")
                }
            }
            if lists.source.charts.count > 4 {
                chartMenu
            } else if lists.source.charts.count > 1 {
                Picker("List", selection: $lists.chart) {
                    ForEach(lists.source.charts) { Text($0.shortTitle).tag($0) }
                }.pickerStyle(.segmented).id(lists.source).accessibilityIdentifier("bookListChartPicker")
            }
            HStack(spacing: 12) {
                if lists.source == .apple { countryMenu }
                Spacer(minLength: 0)
                if let list = lists.selected {
                    Text(list.published.isEmpty ? "Retrieved \(list.fetchedAt.formatted(date: .abbreviated, time: .omitted))" : list.published)
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bookListDate")
                }
            }.frame(minHeight: 24)
            if lists.error != nil, lists.selected != nil {
                Text("Loaded earlier · Refresh to try again").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bookListSaved")
            }
            if lists.isLoading && lists.books.isEmpty { ProgressView("Loading list…").frame(maxWidth: .infinity).padding(.vertical, 40) }
            if let error = lists.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).font(.subheadline).accessibilityIdentifier("bookListError")
                    Button("Try again") { Task { await lists.load(force: true) } }.buttonStyle(.bordered).disabled(lists.isLoading)
                        .accessibilityIdentifier("bookListRetry")
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 14))
            }
            if let error = lists.downloadError {
                Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("bookListDownloadError")
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lists.books) { book in
                    BookListRow(book: book, caption: lists.selection.caption, close: close)
                    Divider()
                }
            }.accessibilityIdentifier("bookList")
            if lists.isLoading && !lists.books.isEmpty { ProgressView("Loading…").frame(maxWidth: .infinity) }
            else if lists.canLoadMore {
                Button("Load more") { Task { await lists.loadMore() } }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("bookListLoadMore")
            }
            if !lists.books.isEmpty {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
                Link(lists.chart.isBundled ? "About the prize" : "List on \(lists.source.fullName)", destination: lists.selection.pageURL)
                    .font(.caption).accessibilityIdentifier("bookListSource")
            }
        }
        .task(id: lists.selection) { await lists.load() }
        .onChange(of: catalog.matchingContextID) { _, _ in matching.invalidate() }
        .onChange(of: catalog.connected) { _, connected in if !connected { matching.invalidate() } }
    }
    private var footnote: String {
        switch lists.source {
        case .gutenberg: return "Free public-domain books. Add one to read it in Leaf; no account is needed."
        case .prizes: return "\(lists.books.count) winners of the \(lists.chart.title), newest first. Leaf carries this list; it was last checked \(PrizeWinners.checked)."
        default: return "\(lists.books.count) of \(lists.chart.meaning)."
        }
    }
    private var chartMenu: some View {
        Menu {
            Picker("Prize", selection: $lists.chart) {
                ForEach(lists.source.charts) { Text($0.title).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(lists.chart.title); Image(systemName: "chevron.down").font(.caption)
            }.font(.subheadline.weight(.medium)).foregroundStyle(theme.accent).frame(minHeight: 32).contentShape(Rectangle())
        }.accessibilityLabel("Prize, " + lists.chart.title).accessibilityIdentifier("bookListChartMenu")
    }
    private var countryMenu: some View {
        Menu {
            Picker("Store", selection: $lists.country) {
                ForEach(BookListCountry.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(lists.country.title); Image(systemName: "chevron.down").font(.caption)
            }.font(.subheadline.weight(.medium)).foregroundStyle(theme.accent).frame(minHeight: 32).contentShape(Rectangle())
        }.accessibilityLabel("Store, " + lists.country.title).accessibilityIdentifier("bookListCountry")
    }
}

private struct BookListRow: View {
    let book: ListedBook
    let caption: String
    let close: () -> Void
    @EnvironmentObject private var lists: BookListStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var connection = false
    private var free: Bool { book.epub != nil }
    private var state: BestsellerMatchState? { matching.state(for: book) }
    private var existing: Book? { lists.existing(book, in: library, candidates: state?.editions.map(\.book) ?? []) }
    private var page: BookListBookView { BookListBookView(book: book, caption: caption, close: close) }
    private var marker: String { book.year.map(String.init) ?? "\(book.rank)" }
    /// Read out as one item: place, title, who and what, the list's count, then the description.
    private var spoken: String {
        ([book.year.map { "\($0). \(book.title)" } ?? "\(book.rank). \(book.title)", book.byline, book.figure, book.quote, book.summary]
            .filter { !$0.isEmpty }).joined(separator: ", ")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(marker).font((book.year == nil ? Font.headline : .caption.weight(.semibold)).monospacedDigit())
                .foregroundStyle(book.year == nil && book.rank <= 3 ? theme.accent : Color.secondary)
                .frame(width: book.year == nil ? 26 : 34, alignment: .trailing).accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 8) {
                NavigationLink { page } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ListedBookCover(book: book).frame(width: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            Text(book.byline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !book.figure.isEmpty && book.year == nil { Text(book.figure).font(.caption.weight(.medium)).foregroundStyle(theme.accent) }
                            if !book.quote.isEmpty { Text("“\(book.quote)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                            else if !book.summary.isEmpty { Text(book.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(spoken).accessibilityIdentifier("bookListRow-\(book.rank)")
                HStack(spacing: 10) { action }.font(.caption)
            }
        }
        .padding(.vertical, 14)
        .task(id: "\(book.id):\(catalog.matchingContextID):\(catalog.connected)") {
            if !free, existing == nil { await matching.resolve(book, catalog: catalog) }
        }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
    }
    @ViewBuilder private var action: some View {
        if existing != nil {
            Label("In library", systemImage: "checkmark").foregroundStyle(theme.accent).accessibilityIdentifier("bookListOwned-\(book.rank)")
        } else if free {
            if lists.downloadingID == book.id { ProgressView("Adding…") }
            else {
                Text("Free EPUB").foregroundStyle(.secondary)
                Button { lists.addFree(book, library: library) } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.bordered).disabled(lists.downloadingID != nil || library.isImporting)
                    .accessibilityLabel("Add \(book.title) to library").accessibilityIdentifier("bookListFree-\(book.rank)")
            }
        } else if catalog.downloadingID != nil, catalog.downloadingID == state?.automatic?.id {
            ProgressView("Adding…")
        } else if let edition = state?.automatic {
            Text([edition.fileExtension.uppercased(), edition.size].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            Button { catalog.add(edition, library: library) } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.bordered).disabled(catalog.downloadingID != nil || library.isImporting)
                .accessibilityLabel("Add \(book.title) to library").accessibilityIdentifier("bookListAdd-\(book.rank)")
        } else {
            switch state {
            case .loading, .none: ProgressView("Checking…")
            case .connectionRequired:
                Button("Connect") { connection = true }.buttonStyle(.bordered).accessibilityIdentifier("bookListConnect-\(book.rank)")
            case .ready(let editions):
                Text(editions.isEmpty ? "No match yet" : editions.count == 1 ? "1 possible edition" : "\(editions.count) editions").foregroundStyle(.secondary)
                NavigationLink { page } label: { Text(editions.isEmpty ? "Find" : "Choose") }
                    .buttonStyle(.bordered).accessibilityIdentifier("bookListChoose-\(book.rank)")
            case .failed(_, let reason):
                Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("bookListEditionsFailed-\(book.rank)")
                Button("Try again") { Task { await matching.resolve(book, catalog: catalog, force: true) } }
            }
        }
    }
}

struct BookListBookView: View {
    let book: ListedBook
    /// The list the reader came from, such as "Top paid · United States".
    let caption: String
    let close: () -> Void
    @EnvironmentObject private var lists: BookListStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var connection = false
    @State private var search = false
    private var free: Bool { book.epub != nil }
    private var state: BestsellerMatchState? { matching.state(for: book) }
    private var existing: Book? { lists.existing(book, in: library, candidates: state?.editions.map(\.book) ?? []) }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ListedBookCover(book: book).frame(width: 130)
                Text(book.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).accessibilityIdentifier("bookListDetailTitle")
                Text(book.author.isEmpty ? "Unknown author" : book.author).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    if !book.detail.isEmpty { Text(book.detail) }
                    Text(((book.year == nil ? ["#\(book.rank)"] : []) + [caption] + (book.figure.isEmpty ? [] : [book.figure])).joined(separator: " · "))
                        .accessibilityIdentifier("bookListRanking")
                }.font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 10) {
                    Text("About this book").font(.headline)
                    if !book.quote.isEmpty { Text("“\(book.quote)”").font(.subheadline.italic()) }
                    Text(book.summary.isEmpty ? (book.quote.isEmpty ? "\(book.source.fullName) lists no description for this book." : "") : book.summary)
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("bookListSynopsis")
                    if let link = book.link { Link("View on \(book.source.fullName)", destination: link).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                BookReviewsSection(query: BookReviewQuery(book))
                if free {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Free from Project Gutenberg").font(.headline)
                        Text("A public-domain EPUB. Adding it downloads the book from gutenberg.org; no account is needed.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let error = lists.downloadError {
                            Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("bookListDownloadError")
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 16))
                } else {
                    ListedBookEditions(state: state, close: close, connect: { connection = true }, search: { search = true },
                                       retry: { Task { await matching.resolve(book, catalog: catalog, force: true) } })
                }
            }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .background(theme.canvas).navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if free { freeBar } else { ListedBookAddBar(owned: existing != nil, edition: state?.automatic, close: close) }
        }
        .onAppear { lists.viewingBook = book; lists.resetDownloadResult(); catalog.resetImportResult() }
        .onDisappear { if lists.viewingBook?.id == book.id { lists.viewingBook = nil } }
        .task(id: "\(catalog.matchingContextID):\(catalog.connected)") { if !free { await matching.resolve(book, catalog: catalog) } }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
        .navigationDestination(isPresented: $search) { BestsellerCatalogSearch(initialQuery: book.title + " " + book.author, close: close) }
    }
    @ViewBuilder private var freeBar: some View {
        VStack(spacing: 8) {
            if existing != nil {
                Label("Added to your library", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(theme.accent)
                Button("View in library", action: close).buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent)
                    .accessibilityIdentifier("bookListViewLibrary")
            } else {
                Button { lists.addFree(book, library: library) } label: {
                    Label(lists.downloadingID == book.id ? "Adding to library…" : "Add free EPUB", systemImage: "plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).controlSize(.large)
                    .disabled(lists.downloadingID != nil || library.isImporting).accessibilityIdentifier("bookListDetailAdd")
                if lists.downloadingID == book.id {
                    Button("Cancel download") { lists.cancelDownload() }.accessibilityIdentifier("bookListCancelDownload")
                }
                Text("Saved on this device for offline reading").font(.caption).foregroundStyle(.secondary)
            }
        }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
    }
}
