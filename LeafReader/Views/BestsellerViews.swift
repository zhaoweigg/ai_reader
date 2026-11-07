import SwiftUI

enum DiscoverSection: String, CaseIterable, Identifiable {
    case popular, recommended, bestsellers
    var id: String { rawValue }
    var title: String { self == .popular ? "Most popular" : self == .recommended ? "Recommended" : "Bestsellers" }
}

struct BestsellerCover: View {
    @Environment(\.leafTheme) private var theme
    let book: BestsellerBook
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(theme.surface)
            #if DEBUG
            if UITesting.flag("LEAF_UI_BESTSELLERS_MOCK"), let image = UITestBestsellerClient.cover(book) {
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
                Text("Bestsellers").font(.system(size: 32, design: .serif)).accessibilityIdentifier("bestsellersHeading")
                Spacer()
                Button("Refresh lists", systemImage: "arrow.clockwise") { Task { await discovery.load(force: true) } }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(discovery.isLoading)
                    .accessibilityIdentifier("bestsellersRefresh")
            }
            Picker("Bestseller source", selection: $discovery.source) {
                ForEach(BestsellerSource.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("bestsellerSourcePicker")
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
                        if discovery.source == .nyt { Button("NYT Books connection") { nytConnection = true } }
                    }.buttonStyle(.bordered)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 14))
            } else if discovery.needsNYTConnection && discovery.books.isEmpty && !discovery.isLoading {
                Button("Connect NYT Books") { nytConnection = true }.buttonStyle(.bordered).accessibilityIdentifier("connectNYTBooks")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14, alignment: .top), count: 3), alignment: .leading, spacing: 25) {
                ForEach(discovery.books) { entry in BestsellerCard(book: entry, close: close) }
            }.accessibilityIdentifier("bestsellerGrid")
            if discovery.isLoading && !discovery.books.isEmpty { ProgressView("Refreshing lists…").frame(maxWidth: .infinity) }
            Text(discovery.source.attribution).font(.caption).foregroundStyle(.secondary)
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
        case .failed:
            Text("Could not check editions").font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Z-Library editions").font(.headline)
                    editions
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 16))
                if let error = catalog.importError { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("bestsellerImportError") }
            }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .background(theme.canvas).navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if existing != nil {
                VStack(spacing: 8) {
                    Label("Added to your library", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(theme.accent)
                    Button("View in library", action: close).buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).accessibilityIdentifier("bestsellerViewLibrary")
                }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
            } else if let edition = state?.automatic {
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
        .onAppear { discovery.viewingBook = book; catalog.resetImportResult() }
        .onDisappear { if discovery.viewingBook?.id == book.id { discovery.viewingBook = nil } }
        .task(id: "\(catalog.matchingContextID):\(catalog.connected)") { await matching.resolve(book, catalog: catalog) }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
        .navigationDestination(isPresented: $search) { BestsellerCatalogSearch(book: book, close: close) }
    }
    @ViewBuilder private var editions: some View {
        switch state {
        case .loading, .none: ProgressView("Checking matching editions…")
        case .connectionRequired:
            Text("Use your Z-Library connection to find editions and add books.").font(.subheadline).foregroundStyle(.secondary)
            Button("Connect Z-Library") { connection = true }.buttonStyle(.bordered)
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("Try again") { Task { await matching.resolve(book, catalog: catalog, force: true) } }
            Button("Search Z-Library") { search = true }
        case .ready(let choices):
            if choices.isEmpty {
                Text("No matching edition found yet.").font(.subheadline).foregroundStyle(.secondary)
                Button("Search Z-Library") { search = true }.accessibilityIdentifier("bestsellerSearchCatalog")
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
                Button("Search other editions") { search = true }.font(.caption)
            }
        }
    }
}

private struct BestsellerCatalogSearch: View {
    let book: BestsellerBook
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var discovery: BestsellerStore
    @State private var query = ""
    @State private var results: [ZLibraryBook] = []
    @State private var loading = false
    @State private var error: String?
    @State private var request = UUID()
    @Environment(\.leafTheme) private var theme
    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Title, author, or ISBN", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .onSubmit { Task { await find() } }.accessibilityIdentifier("bestsellerCatalogQuery")
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            query = ""; request = UUID(); loading = false; results = []; error = nil; publishContext()
                        }
                            .labelStyle(.iconOnly).accessibilityIdentifier("bestsellerCatalogClear")
                    }
                }
                Button("Search Z-Library") { Task { await find() } }.disabled(loading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .task { if query.isEmpty { query = book.title + " " + book.author }; await find() }
            .onDisappear { request = UUID(); loading = false; discovery.catalogSearch = nil }
    }
    private func find() async {
        let id = UUID(), value = query; request = id; loading = true; error = nil; results = []; publishContext()
        defer { if request == id { loading = false; publishContext() } }
        do { let books = try await catalog.matchingSearch(value); try Task.checkCancellation(); if request == id { results = books } }
        catch { if request == id && !ZLibraryStore.isCancellation(error) { self.error = "The catalog could not be searched. Check your Z-Library connection and try again." } }
    }
    private func publishContext() {
        discovery.catalogSearch = BestsellerSearchContext(query: query, books: results,
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
                Text(discovery.nytConnected ? "API key saved" : "Not connected")
                SecureField("NYT Books API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("nytAPIKey")
                Button("Save connection") {
                    do { try discovery.saveNYTKey(key); key = ""; error = nil; Task { await discovery.load(source: .nyt, force: true) } }
                    catch { self.error = "The connection could not be saved. Unlock your device and check the key." }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveNYTConnection")
                if discovery.nytConnected {
                    Button("Disconnect NYT Books", role: .destructive) { do { try discovery.saveNYTKey("") } catch { self.error = "The connection could not be removed." } }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let error = discovery.errors[.nyt] { Text(error).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("NYT’s official bestseller feed requires an API key with Books API access. The key is stored privately in Keychain. Indie lists do not need this connection.")
            }
            Section { Link("Get an NYT Books API key", destination: URL(string: "https://developer.nytimes.com/")!) }
        }.leafFormStyle().navigationTitle("NYT Books").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
