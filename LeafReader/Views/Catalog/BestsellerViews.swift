import SwiftUI

struct BestsellerCover: View {
    @Environment(\.leafTheme) private var theme
    let book: BestsellerBook
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(theme.surface)
            #if DEBUG
            if UITesting.flag(.bestsellersMock), let image = UITestBestsellerClient.cover(book) {
                Image(uiImage: image).resizable().scaledToFit()
            } else { remote }
            #else
            remote
            #endif
        }.aspectRatio(2 / 3, contentMode: .fit).clipShape(.rect(cornerRadius: 4))
            .accessibilityElement(children: .ignore).accessibilityLabel(book.title + " cover")
    }
    private var remote: some View {
        AsyncImage(url: book.coverURL) { phase in
            if let image = phase.image { image.resizable().scaledToFit() }
            else {
                VStack(spacing: 9) {
                    Image(systemName: "book.closed").font(.title2).foregroundStyle(theme.accent)
                    Text(book.title).font(.caption.weight(.medium)).multilineTextAlignment(.center).lineLimit(4)
                }.padding(10)
            }
        }
    }
}

struct BestsellerGrid: View {
    @EnvironmentObject private var discovery: BestsellerStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    let close: () -> Void
    @State private var nytConnection = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(discovery.source == .nyt ? "NYT Best Sellers" : "Indie Bestsellers").font(.system(size: 32, design: .serif)).accessibilityIdentifier("bestsellersHeading")
                Spacer()
                Button("Refresh lists", systemImage: "arrow.clockwise") { Task { await discovery.load(force: true) } }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(discovery.isLoading)
                    .accessibilityIdentifier("bestsellersRefresh")
            }
            HStack {
                Picker("Book category", selection: $discovery.genre) {
                    ForEach(BestsellerGenre.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("bestsellerGenrePicker")
                Text("Hardcover").font(.caption).foregroundStyle(.secondary)
            }
            if let list = discovery.selected {
                Text("List dated \(list.published)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bestsellerListDate")
                if discovery.error != nil {
                    Text("Previously loaded · Retrieved \(list.fetchedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bestsellerSavedList")
                }
            }
            if discovery.isLoading && discovery.books.isEmpty { ProgressView("Loading bestsellers…").frame(maxWidth: .infinity).padding(.vertical, 40) }
            if let error = discovery.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).font(.subheadline).accessibilityIdentifier("bestsellerFeedError")
                    HStack {
                        Button("Try again") { Task { await discovery.load(force: true) } }.disabled(discovery.isLoading)
                        if discovery.source == .nyt && discovery.nytConnected { Button("NYT Books connection") { nytConnection = true } }
                    }.buttonStyle(.bordered)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 14))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14, alignment: .top), count: 3), alignment: .leading, spacing: 25) {
                ForEach(discovery.books) { entry in BestsellerCard(book: entry, close: close) }
            }.accessibilityIdentifier("bestsellerGrid")
            if discovery.isLoading && !discovery.books.isEmpty { ProgressView("Refreshing lists…").frame(maxWidth: .infinity) }
            Text(discovery.source.attribution).font(.caption).foregroundStyle(.secondary)
            if let relay = discovery.selected?.relayURL {
                Link("Public feed via Team Book Club", destination: relay).font(.caption).accessibilityIdentifier("bestsellerPublicSource")
            }
            if let error = catalog.importError { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("bestsellerImportError") }
        }
        .task(id: discovery.source) { await discovery.load() }
        .onChange(of: catalog.matchingContextID) { _, _ in matching.invalidate() }
        .onChange(of: catalog.connected) { _, connected in if !connected { matching.invalidate() } }
        .sheet(isPresented: $nytConnection) { NavigationStack { NYTBooksConnectionView() } }
    }
}

private struct BestsellerCard: View {
    let book: BestsellerBook
    let close: () -> Void
    @EnvironmentObject private var discovery: BestsellerStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var connection = false
    private var state: BestsellerMatchState? { matching.state(for: book) }
    private var existing: Book? { discovery.existing(book, in: library, candidates: state?.editions.map(\.book) ?? []) }
    private var identifier: String { "\(book.source.rawValue)-\(book.genre.rawValue)-\(book.rank)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("#\(book.rank)").font(.caption).foregroundStyle(.secondary)
            NavigationLink { BestsellerBookView(book: book, close: close) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    BestsellerCover(book: book)
                    Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.buttonStyle(.plain).accessibilityIdentifier("bestsellerBook-" + identifier)
            if existing != nil {
                Label("In library", systemImage: "checkmark").font(.caption).foregroundStyle(theme.accent).accessibilityIdentifier("bestsellerOwned-" + identifier)
            } else if catalog.downloadingID != nil, catalog.downloadingID == state?.automatic?.id {
                ProgressView("Adding…").font(.caption)
            } else if let edition = state?.automatic {
                Text([edition.fileExtension.uppercased(), edition.language].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(theme.accent)
                Button { catalog.add(edition, library: library) } label: { Label("Add", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).font(.caption).disabled(catalog.downloadingID != nil || library.isImporting)
                    .accessibilityLabel("Add \(book.title) to library").accessibilityIdentifier("bestsellerAdd-" + identifier)
            } else {
                alternative
            }
        }
        .task(id: "\(book.id):\(catalog.matchingContextID):\(catalog.connected)") {
            if existing == nil { await matching.resolve(book, catalog: catalog) }
        }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
    }
    @ViewBuilder private var alternative: some View {
        switch state {
        case .loading, .none: ProgressView("Checking…").font(.caption)
        case .connectionRequired:
            Button("Connect") { connection = true }.buttonStyle(.bordered).font(.caption).accessibilityIdentifier("bestsellerConnect-" + identifier)
        case .ready(let editions):
            Text(editions.isEmpty ? "No match yet" : "\(editions.count) possible editions").font(.caption).foregroundStyle(.secondary)
            NavigationLink { BestsellerBookView(book: book, close: close) } label: { Text(editions.isEmpty ? "Find" : "Choose").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).font(.caption).accessibilityIdentifier("bestsellerChoose-" + identifier)
        case .failed(_, let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("bestsellerEditionsFailed-" + identifier)
            Button("Try again") { Task { await matching.resolve(book, catalog: catalog, force: true) } }.font(.caption)
        }
    }
}

struct BestsellerBookView: View {
    let book: BestsellerBook
    let close: () -> Void
    @EnvironmentObject private var discovery: BestsellerStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var connection = false
    @State private var search = false
    private var state: BestsellerMatchState? { matching.state(for: book) }
    private var existing: Book? { discovery.existing(book, in: library, candidates: state?.editions.map(\.book) ?? []) }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                BestsellerCover(book: book).frame(width: 130)
                Text(book.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).accessibilityIdentifier("bestsellerDetailTitle")
                Text(book.author).foregroundStyle(.secondary)
                BestsellerRankings(title: book.title, author: book.author)
                VStack(alignment: .leading, spacing: 10) {
                    Text("About this book").font(.headline)
                    Text(book.summary.isEmpty ? "No description supplied by the list provider." : book.summary).font(.subheadline).foregroundStyle(.secondary)
                    Link("View on \(book.source == .indie ? "IndieBound" : "The New York Times")", destination: book.sourceURL).font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
                BookReviewsSection(query: BookReviewQuery(book))
                ListedBookEditions(state: state, close: close, connect: { connection = true }, search: { search = true },
                                   retry: { Task { await matching.resolve(book, catalog: catalog, force: true) } })
            }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .background(theme.canvas).navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { ListedBookAddBar(owned: existing != nil, edition: state?.automatic, close: close) }
        .onAppear { discovery.viewingBook = book; catalog.resetImportResult() }
        .onDisappear { if discovery.viewingBook?.id == book.id { discovery.viewingBook = nil } }
        .task(id: "\(catalog.matchingContextID):\(catalog.connected)") { await matching.resolve(book, catalog: catalog) }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
        .navigationDestination(isPresented: $search) { BestsellerCatalogSearch(initialQuery: book.title + " " + book.author, close: close) }
    }
}

/// The catalog editions found for a book from a public list, on the bestseller and web-novel pages alike.
struct ListedBookEditions: View {
    let state: BestsellerMatchState?
    let close: () -> Void
    let connect: () -> Void
    let search: () -> Void
    let retry: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.leafTheme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Z-Library editions").font(.headline)
            editions
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 16))
        if let error = catalog.importError { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("bestsellerImportError") }
    }
    @ViewBuilder private var editions: some View {
        switch state {
        case .loading, .none: ProgressView("Checking matching editions…")
        case .connectionRequired:
            Text("Use your Z-Library connection to find editions and add books.").font(.subheadline).foregroundStyle(.secondary)
            Button("Connect Z-Library", action: connect).buttonStyle(.bordered)
        case .failed(let message, _):
            Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("editionCheckFailure")
            Button("Try again", action: retry)
            Button("Search Z-Library", action: search)
        case .ready(let choices):
            if choices.isEmpty {
                Text("No matching edition found yet.").font(.subheadline).foregroundStyle(.secondary)
                Button("Search Z-Library", action: search).accessibilityIdentifier("bestsellerSearchCatalog")
            } else {
                Text(choices.count > 1 ? "Check the title, author, format, and language before adding." : "Matching edition from your Z-Library connection.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(choices) { choice in
                    NavigationLink { ZLibraryBookView(book: choice.book, close: close) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(choice.book.fileExtension.isEmpty ? "Load edition details" : choice.book.fileSummary).font(.subheadline.weight(.semibold))
                                Text(choice.book.title).font(.caption).lineLimit(2)
                                Text(choice.book.author).font(.caption).foregroundStyle(.secondary)
                                Text(choice.book.editionSummary).font(.caption).foregroundStyle(.secondary)
                                if choice.confidence == .possible { Text("Confirm this is the right book").font(.caption).foregroundStyle(theme.accent) }
                            }
                            Spacer(minLength: 8); Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 6)
                    }.accessibilityIdentifier("bestsellerEdition-" + choice.book.remoteID)
                }
                Button("Search other editions", action: search).font(.caption)
            }
        }
    }
}

/// The bar under a listed book's page: add its one sure edition, or go to the copy already in the library.
struct ListedBookAddBar: View {
    let owned: Bool
    let edition: ZLibraryBook?
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    var body: some View {
        if owned {
            VStack(spacing: 8) {
                Label("Added to your library", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(theme.accent)
                Button("View in library", action: close).buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).accessibilityIdentifier("bestsellerViewLibrary")
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        } else if let edition {
            VStack(spacing: 8) {
                Button { catalog.add(edition, library: library) } label: {
                    Label(catalog.downloadingID == edition.id ? "Adding to library…" : "Add to library", systemImage: "plus").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).controlSize(.large)
                    .disabled(catalog.downloadingID != nil || library.isImporting).accessibilityIdentifier("bestsellerDetailAdd")
                if catalog.downloadingID == edition.id {
                    if let progress = catalog.progress { ProgressView(value: progress) } else { ProgressView("Preparing download…") }
                    Button("Cancel download") { catalog.cancelDownload() }.accessibilityIdentifier("bestsellerCancelDownload")
                }
                Text("Saved on this device for offline reading").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
}

/// A catalog search opened from a listed book's page, starting from its title and author.
struct BestsellerCatalogSearch: View {
    let initialQuery: String
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var discovery: BestsellerStore
    @State private var query = ""
    @State private var results: [ZLibraryBook] = []
    @State private var loading = false
    @State private var error: String?
    @State private var request = UUID()
    @State private var submittedQuery = ""
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchContext: UUID?
    @Environment(\.leafTheme) private var theme
    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Title, author, or ISBN", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { startSearch() }.accessibilityIdentifier("bestsellerCatalogQuery")
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            request = UUID(); searchTask?.cancel(); searchTask = nil
                            query = ""; submittedQuery = ""; hasSearched = true; loading = false; results = []; error = nil; publishContext()
                        }
                            .labelStyle(.iconOnly).accessibilityIdentifier("bestsellerCatalogClear")
                    }
                }
                Button("Search Z-Library") { startSearch() }.disabled(loading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if loading { ProgressView("Searching Z-Library…") }
            if let error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            if !loading && error == nil && results.isEmpty { Text("No editions found. Try the title without the author.").foregroundStyle(.secondary) }
            Section("Editions") {
                ForEach(results) { edition in
                    NavigationLink { ZLibraryBookView(book: edition, close: close) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(edition.title).font(.headline); Text(edition.author).font(.subheadline)
                            Text(edition.fileSummary + " · " + edition.editionSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("bestsellerSearchEdition-" + edition.remoteID)
                }
            }
        }.leafFormStyle().navigationTitle("Search Z-Library").navigationBarTitleDisplayMode(.inline)
            .task(id: catalog.matchingContextID) {
                if searchContext != catalog.matchingContextID {
                    request = UUID(); searchTask?.cancel(); searchTask = nil
                    hasSearched = false; loading = false; results = []; error = nil
                    searchContext = catalog.matchingContextID
                }
                if !hasSearched { if query.isEmpty { query = initialQuery }; startSearch() }
                else { publishContext() }
            }
            .onDisappear {
                request = UUID(); searchTask?.cancel(); searchTask = nil
                if loading { hasSearched = false }
                loading = false; discovery.catalogSearch = nil
            }
    }
    private func startSearch() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchTask?.cancel()
        let id = UUID(); request = id; submittedQuery = value; hasSearched = true; loading = true; error = nil; results = []; publishContext()
        searchTask = Task { await find(value, request: id) }
    }
    private func find(_ value: String, request id: UUID) async {
        defer { if request == id { loading = false; searchTask = nil; publishContext() } }
        do { let books = try await catalog.matchingSearch(value); try Task.checkCancellation(); if request == id { results = books } }
        catch { if request == id && !ZLibraryStore.isCancellation(error) { self.error = "The catalog could not be searched. Check your Z-Library connection and try again." } }
    }
    private func publishContext() {
        discovery.catalogSearch = BestsellerSearchContext(generation: catalog.matchingContextID, query: submittedQuery, books: results,
            status: loading ? ["Searching Z-Library…"] : error.map { [$0] } ?? [])
    }
}

struct BestsellerRankings: View {
    @EnvironmentObject private var discovery: BestsellerStore
    let title: String
    let author: String
    var body: some View {
        let entries = discovery.rankings(title: title, author: author)
        if !entries.isEmpty {
            VStack(spacing: 6) {
                ForEach(entries) { entry in
                    Text("#\(entry.rank) · \(entry.source.title) \(entry.genre.title)").font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("bestsellerRankings")
        }
    }
}

struct NYTBooksConnectionView: View {
    @EnvironmentObject private var discovery: BestsellerStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.leafTheme) private var theme
    @State private var key = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Text(discovery.nytConnected ? "API key saved" : "Using public feed · No key required")
                SecureField("NYT Books API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("nytAPIKey")
                Button("Save connection") {
                    do { try discovery.saveNYTKey(key); key = ""; error = nil; Task { await discovery.load(source: .nyt, force: true) } }
                    catch { self.error = "The connection could not be saved. Unlock your device and check the key." }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveNYTConnection")
                if discovery.nytConnected {
                    Button("Use public feed", role: .destructive) {
                        do { try discovery.saveNYTKey(""); Task { await discovery.load(source: .nyt, force: true) } }
                        catch { self.error = "The connection could not be removed." }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = discovery.errors[.nyt] { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("NYT lists load from Team Book Club’s public pages without an account. Optionally use NYT’s official API by saving a key with Books API access. The key stays privately in Keychain and is sent only to NYT.")
            }
            Section { Link("Get an NYT Books API key", destination: URL(string: "https://developer.nytimes.com/")!) }
        }.leafFormStyle().navigationTitle("NYT Books").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
