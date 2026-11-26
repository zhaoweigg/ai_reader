import SwiftUI
import WebKit

struct ZLibraryView: View {
    @Environment(\.leafTheme) private var theme
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var discovery: BestsellerStore
    @EnvironmentObject private var novels: WebNovelStore
    @EnvironmentObject private var lists: BookListStore
    @EnvironmentObject private var arrangement: DiscoverListsStore
    /// Bestsellers, the 中文 charts and the other public lists are shown in place of the catalog grid.
    private var showingCharts: Bool { discovery.showingBestsellers || novels.showing || lists.showing }
    private var chartsVisible: Bool { showingCharts && catalog.activeQuery.isEmpty }
    private var current: DiscoverList { DiscoverList.current(catalog: catalog, bestsellers: discovery, novels: novels, lists: lists) }
    /// The reader's lists, plus the one showing if it was opened from elsewhere while hidden.
    private var chips: [DiscoverList] { arrangement.shown + (arrangement.isShown(current) ? [] : [current]) }
    private func select(_ value: DiscoverList) {
        searchFocused = false; searchText = ""
        arrangement.remember(value)
        value.show(catalog: catalog, bestsellers: discovery, novels: novels, lists: lists)
        switch value {
        case .nyt, .indie: Task { await discovery.load() }
        case .qidian, .weread: Task { await novels.load() }
        case .popular, .recommended: Task { await catalog.browse(value == .popular ? .popular : .recommended) }
        default: Task { await lists.load() }
        }
    }
    private enum Sheet: String, Identifiable { case connection, website; var id: String { rawValue } }
    @State private var sheet: Sheet?
    @State private var editingLists = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Title, author, or ISBN", text: $searchText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .focused($searchFocused).onSubmit { submitSearch() }
                        .accessibilityIdentifier("zlibrarySearchField")
                    if !searchText.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            searchText = ""; searchFocused = false
                            if showingCharts { catalog.show(catalog.feed) }
                            else { Task { await catalog.search("") } }
                        }.labelStyle(.iconOnly).foregroundStyle(.secondary).accessibilityIdentifier("zlibraryClearSearch")
                    }
                    Button("Search", action: submitSearch)
                        .font(.subheadline.weight(.semibold)).disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("zlibrarySubmitSearch")
                }.padding(14).frame(minHeight: 48).background(theme.surface, in: .rect(cornerRadius: 14))
                DiscoverListChips(lists: chips, selection: current, select: select, edit: { searchFocused = false; editingLists = true })
                if chartsVisible, lists.showing {
                    BookListCharts(close: close)
                } else if chartsVisible, novels.showing {
                    WebNovelCharts(close: close)
                } else if chartsVisible {
                    BestsellerGrid(close: close)
                } else {
                if !catalog.activeQuery.isEmpty {
                    Menu {
                        Picker("Sort search results", selection: Binding(get: { catalog.searchOrder }, set: { order in
                            searchFocused = false
                            Task { await catalog.setSearchOrder(order) }
                        })) {
                            ForEach(ZLibrarySearchOrder.allCases) { order in Text(order.title).tag(order) }
                        }
                    } label: {
                        HStack(spacing:8) {
                            Label("Search order",systemImage:"arrow.up.arrow.down").foregroundStyle(.secondary)
                            Spacer(minLength:8)
                            Text(catalog.searchOrder.title).foregroundStyle(theme.accent)
                            Image(systemName:"chevron.down").font(.caption).foregroundStyle(theme.accent)
                        }.font(.subheadline).padding(.vertical,4).contentShape(Rectangle())
                    }.accessibilityIdentifier("zlibrarySearchOrder")
                }
                HStack(alignment:.firstTextBaseline) {
                    Text(catalog.activeQuery.isEmpty ? catalog.feed.title : "Search results").font(.system(size:32,weight:.regular,design:.serif))
                        .accessibilityIdentifier("zlibraryFeedTitle")
                    Spacer()
                    if catalog.isPreview { Text("Preview").font(.caption).foregroundStyle(.secondary) }
                    Button("Refresh books", systemImage: "arrow.clockwise") { Task { await catalog.reload() } }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(catalog.loading)
                        .accessibilityIdentifier("zlibraryRefresh")
                }
                if !catalog.activeQuery.isEmpty {
                    Text("Results for “\(catalog.activeQuery)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                } else if catalog.feed == .recommended {
                    Text("Picked for you by Z-Library using your connected account.").font(.subheadline).foregroundStyle(.secondary)
                }
                if catalog.showingSavedResults {
                    Text("Previously loaded · Pull down to refresh").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("zlibrarySavedResults")
                }
                if !catalog.connected {
                    Button { sheet = .connection } label: { Label("Connect Z-Library",systemImage:"person.crop.circle") }
                        .buttonStyle(.bordered).accessibilityIdentifier("connectZLibrary")
                }
                if catalog.loading && catalog.books.isEmpty {
                    ProgressView(catalog.activeQuery.isEmpty ? catalog.feed.loadingTitle : "Searching books…").frame(maxWidth:.infinity).padding(.vertical,70)
                }
                if catalog.recommendationConnectionRequired {
                    ContentUnavailableView("Connect for recommendations",systemImage:"person.crop.circle",description:Text("Connect your Z-Library account to see its personal book recommendations."))
                } else if let error = catalog.error {
                    VStack(alignment:.leading,spacing:12) {
                        Label(catalog.activeQuery.isEmpty ? catalog.feed.failureTitle : "Could not search books",systemImage:"exclamationmark.circle").font(.headline)
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            if catalog.websiteAccessNeeded {
                                Button("Open website") { Task { await catalog.seedWebsite(); sheet = .website } }
                                    .accessibilityIdentifier("zlibraryCheckWebsite")
                            } else { Button("Connection") { sheet = .connection } }
                            Button("Try again") { Task { await catalog.retry() } }.disabled(catalog.loading)
                        }.buttonStyle(.bordered)
                        if let diagnostic = catalog.requestDiagnostic {
                            DisclosureGroup("Request details") {
                                Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
                                    .accessibilityIdentifier("zlibraryRequestDiagnostic")
                                Text("Contains no cookies, account details, or response content.").font(.caption2).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                        Text("You can also download a book using your browser and add it from Files.").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(theme.surface,in:.rect(cornerRadius:18))
                } else if !catalog.loading && catalog.books.isEmpty {
                    if catalog.activeQuery.isEmpty {
                        if catalog.feed == .recommended {
                            ContentUnavailableView("No recommendations yet",systemImage:"sparkles",description:Text("Z-Library has not returned recommendations for this account yet. Try Most popular or search for a book."))
                        } else {
                            ContentUnavailableView("No books available",systemImage:"books.vertical",description:Text("Pull down to refresh the popular books list."))
                        }
                    } else {
                        ContentUnavailableView("No books found",systemImage:"magnifyingglass",description:Text("Try another title, author, or ISBN."))
                    }
                }
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(minimum:0),spacing:14,alignment:.top),count:3),alignment:.leading,spacing:25) {
                    ForEach(catalog.books) { book in
                        NavigationLink { ZLibraryBookView(book:book,close:close) } label: {
                            VStack(alignment:.leading,spacing:8) {
                                ZLibraryCover(book:book)
                                Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                Text(book.author.isEmpty ? "Unknown author" : book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(catalog.cardDetailsPending(book) && (book.fileExtension.isEmpty || book.size.isEmpty)
                                     ? (book.fileExtension.isEmpty ? "Loading details…" : "\(book.fileExtension.uppercased()) · Loading size…")
                                     : catalog.cardDetailsFailed(book) && book.fileExtension.isEmpty ? "Details unavailable" : book.fileSummary).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                if !book.editionSummary.isEmpty { Text(book.editionSummary).font(.caption2).foregroundStyle(.secondary) }
                                Label(book.rating == nil && catalog.cardDetailsPending(book) ? "Loading rating…" : book.rating == nil && catalog.cardDetailsFailed(book) ? "Rating unavailable" : book.ratingSummary,systemImage:book.rating == nil ? "star" : "star.fill")
                                    .font(.caption2).foregroundStyle(book.rating == nil ? Color.secondary : theme.accent)
                                    .fixedSize(horizontal:false,vertical:true)
                                if library.books.contains(where: { $0.catalogSource == book.sourceID }) {
                                    Label("In library",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(theme.accent)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("catalogBook-\(book.remoteID)")
                            .task(id: "\(book.id):\(catalog.detailRefresh)") { await catalog.loadCardDetails(book) }
                    }
                }
                if catalog.loading && !catalog.books.isEmpty { ProgressView(catalog.showingSavedResults ? "Refreshing books…" : "Loading more books…").frame(maxWidth: .infinity) }
                else if catalog.canLoadMore {
                    Button("Load more books") { searchFocused = false; Task { await catalog.loadMore() } }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity).accessibilityIdentifier("zlibraryLoadMore")
                }
                if catalog.searchLimitReached {
                    Text("Showing the first 300 results. Refine your search to find more books.").font(.footnote).foregroundStyle(.secondary)
                }
                }
            }.padding(24).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity)
        }
        .background(theme.canvas).toolbarBackground(theme.canvas, for: .navigationBar).navigationTitle(chartsVisible ? "Discover" : "Z-Library").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { sheet = .connection } label: { Image(systemName:"person.crop.circle") }.accessibilityLabel("Z-Library connection") } }
        .onAppear { searchText = catalog.activeQuery; catalog.traceCatalogLoad("view appeared") }
        .onChange(of: searchText) { _, value in
            if value.isEmpty && !catalog.activeQuery.isEmpty {
                if showingCharts { catalog.show(catalog.feed) }
                else { Task { await catalog.search("") } }
            }
        }
        .onDisappear { catalog.traceCatalogLoad("view disappeared"); catalog.cancelCatalogLoad("view disappeared") }
        .task {
            if !chartsVisible { await catalog.search(catalog.activeQuery) } else if lists.showing { await lists.load() }
            else if novels.showing { await novels.load() } else { await discovery.load() }
        }
        .refreshable {
            if !chartsVisible { catalog.traceCatalogLoad("pull to refresh"); await catalog.reload() }
            else if lists.showing { await lists.load(force: true) }
            else if novels.showing { await novels.load(force: true) } else { await discovery.load(force: true) }
        }
        .onChange(of: arrangement.shown) { _, shown in
            // Hiding the list on screen moves Discover to the first one still shown.
            if !shown.contains(current), editingLists, let first = shown.first { select(first) }
        }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            if UITesting.flag(.zlibThumbnails) { ZLibraryImageDiagnostics() }
            if UITesting.flag(.zlibTrace) {
                Text(catalog.loadTrace.joined(separator: " | ")).font(.system(size: 1)).opacity(0.02)
                    .frame(width: 2, height: 2).accessibilityIdentifier("zlibraryLoadTrace")
            }
        }
        #endif
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item:$sheet,onDismiss: { Task { await catalog.reload() } }) { sheet in
            if sheet == .website { ZLibraryWebsiteSignIn() } else { ZLibraryConnectionView() }
        }
        .sheet(isPresented: $editingLists) { DiscoverListsEditor() }
    }
    private func submitSearch() {
        searchFocused = false
        let query = searchText
        Task { await catalog.search(query) }
    }
}

struct ZLibraryBookView: View {
    @Environment(\.leafTheme) private var theme
    let book: ZLibraryBook
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @State private var connection = false
    @State private var resolved: ZLibraryBook?
    @State private var detailsError: String?
    @State private var descriptionFailed = false
    @State private var loadingDetails = false
    @State private var detailsAttempt = 0
    @State private var detailsRequest = UUID()
    private var edition: ZLibraryBook { resolved ?? book }
    private var description: String { edition.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var existing: Book? { library.books.first { $0.catalogSource == book.sourceID } }
    var body: some View {
        ScrollView {
            VStack(spacing:18) {
                ZLibraryCover(book:edition).frame(width:120).accessibilityElement(children:.ignore).accessibilityLabel(edition.title + " cover").accessibilityIdentifier("catalogDetailCover")
                Text(edition.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text(edition.author).foregroundStyle(.secondary).accessibilityIdentifier("catalogDetailAuthor")
                BestsellerRankings(title: edition.title, author: edition.author)
                VStack(alignment:.leading,spacing:9) {
                    Text("About this book").font(.headline).accessibilityAddTraits(.isHeader).accessibilityIdentifier("catalogSummaryHeading")
                    if !description.isEmpty {
                        CatalogBookSummary(text:description).id(book.id)
                    } else if loadingDetails || (edition.summary == nil && !descriptionFailed) {
                        ProgressView("Loading description…").font(.subheadline).accessibilityIdentifier("catalogSummaryLoading")
                    } else if descriptionFailed {
                        Text("The description couldn’t be loaded.").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("catalogSummaryError")
                        if !edition.fileExtension.isEmpty {
                            Button("Try again") { detailsAttempt += 1 }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("retryCatalogSummary")
                        }
                    } else {
                        Text("No description available for this edition.").font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("catalogSummaryEmpty")
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
                VStack(alignment:.leading,spacing:14) {
                    Text("This edition").font(.caption).foregroundStyle(.secondary)
                    HStack { Image(systemName:"doc").font(.title2).foregroundStyle(theme.accent); VStack(alignment:.leading,spacing:4) {
                        Text(edition.fileExtension.isEmpty ? "Format unavailable" : edition.fileSummary).font(.headline)
                        Text(edition.editionSummary).font(.subheadline).foregroundStyle(.secondary)
                    };Spacer() }
                    Text(edition.fileExtension.isEmpty ? (detailsError == nil ? "Loading edition information…" : "Edition information unavailable") : edition.format == nil ? "This format cannot be opened in Leaf." : edition.format == .pdf ? "Original page layout" : "Reading appearance can be adjusted in Leaf").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(theme.surface,in:.rect(cornerRadius:18))
                // Waits for the edition's ISBNs, which arrive with its details.
                BookReviewsSection(query:BookReviewQuery(edition),ready:resolved != nil || descriptionFailed || detailsError != nil || (!book.fileExtension.isEmpty && book.summary != nil))
                if let error = catalog.importError { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("catalogImportError") }
                if catalog.downloadingID == book.id {
                    if let progress = catalog.progress { ProgressView(value:progress).accessibilityLabel("Download progress") } else { ProgressView("Preparing download…") }
                    Button("Cancel download") { catalog.cancelDownload() }.accessibilityIdentifier("cancelCatalogDownload")
                }
            }.padding(24).frame(maxWidth:520).frame(maxWidth:.infinity)
        }
        .accessibilityIdentifier("catalogDetailsScroll")
        .background(theme.canvas).toolbarBackground(theme.canvas, for: .navigationBar).navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:8) {
                if existing != nil {
                    Label("Added to your library",systemImage:"checkmark.circle.fill").font(.subheadline).foregroundStyle(theme.accent).accessibilityIdentifier("catalogAdded")
                    Button("View in library",action:close).buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).accessibilityIdentifier("catalogViewLibrary")
                } else if edition.fileExtension.isEmpty {
                    if let detailsError {
                        Text(detailsError).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("catalogDetailsError")
                        HStack {
                            Button("Try again") { detailsAttempt += 1 }.accessibilityIdentifier("retryCatalogDetails")
                            if !catalog.connected { Button("Connect Z-Library") { connection = true } }
                        }.buttonStyle(.bordered).disabled(loadingDetails)
                    } else {
                        ProgressView("Loading book details…").accessibilityIdentifier("catalogDetailsLoading")
                    }
                } else if edition.format == nil {
                    Text("Leaf does not support this edition’s format. Choose another book or edition.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button { if catalog.connected { catalog.add(edition,library:library) } else { connection = true } } label: {
                        Label(catalog.downloadingID == book.id ? "Adding to library…" : catalog.connected ? "Add to library" : "Connect to add book",systemImage:"plus").frame(maxWidth:.infinity)
                    }.buttonStyle(CatalogAddButtonStyle()).disabled(catalog.downloadingID != nil || library.isImporting).accessibilityIdentifier("catalogAddBook")
                    Text("Saved on this device for offline reading").font(.caption).foregroundStyle(.secondary)
                }
            }.padding().frame(maxWidth:.infinity).background(.regularMaterial)
        }
        .sheet(isPresented:$connection) { ZLibraryConnectionView() }
        .onAppear { catalog.resetImportResult(); catalog.beginViewing(edition) }
        .onChange(of: resolved) { _, value in if let value { catalog.beginViewing(value) } }
        .task(id: "\(catalog.connected):\(detailsAttempt)") { await loadDetails() }
        .onDisappear { catalog.endViewing(book); if catalog.downloadingID == book.id { catalog.cancelDownload() } }
    }
    private func loadDetails() async {
        // The same request also carries the description Ask Leaf uses for “this book”.
        guard edition.fileExtension.isEmpty || edition.summary == nil else { return }
        let listed = !edition.fileExtension.isEmpty
        let request = UUID(); detailsRequest = request; loadingDetails = true; detailsError = nil; descriptionFailed = false
        defer { if request == detailsRequest { loadingDetails = false } }
        do {
            let details = try await catalog.details(book, description: true)
            try Task.checkCancellation()
            guard request == detailsRequest else { return }
            resolved = details
        } catch {
            // Description failures do not stop an already listed edition being added.
            if request == detailsRequest && !Task.isCancelled && !ZLibraryStore.isCancellation(error) {
                descriptionFailed = true
                if !listed { detailsError = error.localizedDescription }
            }
        }
    }
}

/// Measures both layouts at the available width so short descriptions never
/// acquire a redundant expand button, including after rotation or a text-size change.
private struct CatalogBookSummary: View {
    @Environment(\.leafTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    @State private var expanded = false
    @State private var overflows = false

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            Text(text).font(.body).lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                .accessibilityIdentifier("catalogBookSummary")
                .background(alignment:.topLeading) {
                    ZStack(alignment:.topLeading) {
                        measuredText(lines:4,key:"preview")
                        measuredText(lines:nil,key:"full")
                    }.hidden().accessibilityHidden(true).allowsHitTesting(false)
                }
            if overflows {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration:0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing:4) {
                        Text(expanded ? "Read less" : "Read more")
                        Image(systemName:expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                    }.font(.subheadline.weight(.semibold)).frame(minHeight:44,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(theme.accent).accessibilityIdentifier("toggleCatalogSummary")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .onPreferenceChange(CatalogSummaryHeights.self) { heights in
            if let full = heights["full"], let preview = heights["preview"] { overflows = full > preview + 1 }
        }
        .onChange(of:text) { _, _ in expanded = false }
    }
    private func measuredText(lines:Int?,key:String) -> some View {
        Text(text).font(.body).lineLimit(lines).fixedSize(horizontal:false,vertical:true)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background { GeometryReader { proxy in Color.clear.preference(key:CatalogSummaryHeights.self,value:[key:proxy.size.height]) } }
    }
}
private struct CatalogSummaryHeights: PreferenceKey {
    static var defaultValue: [String:CGFloat] = [:]
    static func reduce(value:inout [String:CGFloat],nextValue:() -> [String:CGFloat]) { value.merge(nextValue(),uniquingKeysWith: { _, next in next }) }
}

struct ZLibraryConnectionView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var addressError: String?
    @State private var signingIn = false
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("Website") {
                        TextField("https://z-library.sk",text:$address).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("zlibraryAddress")
                        Button("Save website address") { Task { do { try await catalog.changeAddress(address); addressError = nil } catch { addressError = error.localizedDescription } } }
                        if let addressError { Text(addressError).foregroundStyle(.red).font(.footnote) }
                    }
                    Section {
                        if catalog.connected {
                            Label("Account connected",systemImage:"checkmark.shield").foregroundStyle(theme.accent)
                            if !catalog.accountName.isEmpty { Text(catalog.accountName).font(.subheadline) }
                            if let remaining = catalog.remaining { Text("\(remaining) downloads remaining").foregroundStyle(.secondary) }
                        }
                        Button(catalog.connected ? "Open website" : "Sign in on Z-Library") {
                            Task { do { try await catalog.changeAddress(address); await catalog.seedWebsite(); signingIn = true } catch { addressError = error.localizedDescription } }
                        }.accessibilityIdentifier("zlibrarySignIn")
                        if catalog.connected { Button("Disconnect",role:.destructive) { Task { do { try await catalog.disconnect() } catch { addressError = error.localizedDescription } } } }
                        #if DEBUG
                        if catalog.isPreview { Button("Connect preview account") { Task { if await catalog.connectPreview() { dismiss() } } }.accessibilityIdentifier("zlibraryPreviewConnect") }
                        #endif
                    } footer: { Text("Sign in on the website. Leaf saves your session in Keychain, without saving your password. The connection uses Z-Library’s unofficial mobile interface.") }
                    if let error = catalog.connectionError { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                }.listRowBackground(theme.surface)
            }.leafFormStyle()
            .toolbarBackground(theme.canvas, for: .navigationBar)
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Close",systemImage:"xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityLabel("Close connection") } }
            .onAppear { address = catalog.origin.url.absoluteString }
            .sheet(isPresented:$signingIn) { ZLibraryWebsiteSignIn().environmentObject(catalog) }
        }
    }
}

struct ZLibraryWebsiteSignIn: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var checking = false
    @State private var checkTask: Task<Void,Never>?
    @State private var browserReady = false
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                ZLibrarySignInWebView(store:catalog,message:$message,ready:$browserReady)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding() }
                if let error = catalog.connectionError { Text(error).font(.footnote).foregroundStyle(.red).padding() }
                Button { checking = true; checkTask = Task {
                    let cookies = await catalog.websiteData.httpCookieStore.allCookies()
                    if let candidate = catalog.cookieCandidate(cookies) {
                        if await catalog.connect(candidate) { dismiss() }
                    } else { message = "Finish signing in on the website, then tap Check connection." }
                    checking = false
                } } label: { HStack { if checking { ProgressView() }; Text("Check connection") }.frame(maxWidth:.infinity) }
                    .buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).controlSize(.large).disabled(checking || !browserReady).padding()
            }
            .navigationTitle(catalog.origin.url.host ?? "Z-Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarLeading) { Button("Cancel") { checkTask?.cancel();dismiss() } } }
            .onDisappear {
                checkTask?.cancel()
                Task { try? await catalog.saveWebsiteContext() }
            }
        }
    }
}

private struct ZLibrarySignInWebView: UIViewRepresentable {
    let store: ZLibraryStore
    @Binding var message: String?
    @Binding var ready: Bool
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let browser = store.websiteBrowser
        context.coordinator.browser = browser
        browser.stateChanged = { [weak coordinator = context.coordinator] ready, message in
            Task { @MainActor in
                coordinator?.parent.ready = ready
                coordinator?.parent.message = message
            }
        }
        var fixture = false
        #if DEBUG
        fixture = store.isPreview && UITesting.flag(.zlibWebsiteFixture)
        #endif
        browser.presentWebsite(fixture: fixture)
        return browser.webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.browser?.dismissWebsite() }
    final class Coordinator {
        var parent: ZLibrarySignInWebView
        var browser: ZLibraryBrowserSession?
        init(_ parent: ZLibrarySignInWebView) { self.parent = parent }
    }
}

@MainActor struct ZLibraryCover: View {
    let book: ZLibraryBook
    private let images: ZLibraryImages
    @State private var loaded: (url: URL, image: UIImage)?
    init(book: ZLibraryBook, images: ZLibraryImages? = nil) {
        let images = images ?? .shared
        self.book = book; self.images = images
        _loaded = State(initialValue: book.coverURL.flatMap { url in images.cachedImage(url).map { (url, $0) } })
    }
    private var image: UIImage? {
        guard let url = book.coverURL else { return nil }
        return loaded?.url == url ? loaded?.image : images.cachedImage(url)
    }
    /// Width over height of every cover tile, whatever shape the artwork is.
    static let shape: CGFloat = 0.68
    var body: some View {
        // Covers come in many shapes. Sizing the tile to the artwork made each one a different
        // size and moved the card when its cover arrived, so the tile is always this box: the
        // whole cover is fitted inside it and a blurred copy of the cover fills what is left.
        Color.clear.aspectRatio(Self.shape,contentMode:.fit)
            .overlay {
                if let image, abs(image.size.width / max(image.size.height, 1) / Self.shape - 1) > 0.005 {
                    Image(uiImage:image).resizable().scaledToFill().scaleEffect(1.3).blur(radius:12)
                        .overlay(Color.black.opacity(0.1))
                }
            }
            .overlay {
                if let image { Image(uiImage:image).resizable().scaledToFit() }
                else { BookCover(book:book.placeholder) }
            }
            .clipShape(.rect(cornerRadius:8))
            .task(id: book.coverURL) {
                guard let url = book.coverURL else { loaded = nil; return }
                guard loaded?.url != url else { return }
                let image = await images.image(url)
                guard !Task.isCancelled else { return }
                loaded = image.map { (url, $0) }
            }
            .onDisappear { loaded = nil }
    }
}

#if DEBUG
private struct ZLibraryImageDiagnostics: View {
    @ObservedObject private var images = ZLibraryImages.shared
    var body: some View {
        Text("total=\(images.transferCounts.values.reduce(0, +));unique=\(images.transferCounts.count);active=\(images.activeTransfers);first=\(images.transferCounts[URL(string: "https://covers.example/0.png")!, default: 0])")
            .font(.system(size: 1)).opacity(0.02).frame(width: 2, height: 2)
            .accessibilityIdentifier("zlibraryThumbnailTransfers")
    }
}
#endif
