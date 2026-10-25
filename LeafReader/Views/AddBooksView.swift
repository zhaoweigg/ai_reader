import SwiftUI
import WebKit
import ImageIO

struct AddBooksView: View {
    @Environment(\.leafTheme) private var theme
    let openFiles: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var detent: PresentationDetent = .medium
    var body: some View {
        NavigationStack(path:$path) {
            List {
                Group {
                    Button(action: openFiles) {
                        source("From Files", subtitle:"On your iPhone, iCloud Drive & more", icon:"folder")
                    }.buttonStyle(.plain).accessibilityIdentifier("addFromFiles")
                    Button { path = ["zlibrary"] } label: {
                        source("Z-Library",subtitle:"Search books, discover recommendations & more",icon:"book")
                    }.buttonStyle(.plain).accessibilityIdentifier("addFromZLibrary")
                    Section { Text("Books you add are saved on this device for offline reading.").font(.footnote).foregroundStyle(.secondary) }
                }.listRowBackground(theme.surface)
            }.leafFormStyle()
            .toolbarBackground(theme.canvas, for: .navigationBar)
            .navigationTitle("Add books").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for:String.self) { _ in ZLibraryView(close: { dismiss() }) }
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Close",systemImage:"xmark") { dismiss() }.labelStyle(.iconOnly) } }
        }.presentationDetents([.medium,.large],selection:$detent).presentationDragIndicator(.visible)
            .onChange(of:path) { _, value in detent = value.isEmpty ? .medium : .large }
    }
    private func source(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing:14) {
            Image(systemName:icon).font(.title2).foregroundStyle(theme.accent).frame(width:46,height:46)
                .background(theme.accent.opacity(0.1),in:.rect(cornerRadius:13))
            VStack(alignment:.leading,spacing:4) { Text(title).font(.headline).foregroundStyle(.primary);Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength:8)
            Image(systemName:"chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }.padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
    }
}

struct ZLibraryView: View {
    @Environment(\.leafTheme) private var theme
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    private enum Sheet: String, Identifiable { case connection, website; var id: String { rawValue } }
    @State private var sheet: Sheet?
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
                            Task { await catalog.search("") }
                        }.labelStyle(.iconOnly).foregroundStyle(.secondary).accessibilityIdentifier("zlibraryClearSearch")
                    }
                    Button("Search", action: submitSearch)
                        .font(.subheadline.weight(.semibold)).disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("zlibrarySubmitSearch")
                }.padding(14).frame(minHeight: 48).background(theme.surface, in: .rect(cornerRadius: 14))
                Picker("Browse books", selection: Binding(get: { catalog.feed }, set: { feed in
                    searchFocused = false
                    Task { searchText = ""; await catalog.browse(feed) }
                })) {
                    ForEach(ZLibraryFeed.allCases) { feed in Text(feed.title).tag(feed) }
                }.pickerStyle(.segmented).accessibilityIdentifier("zlibraryFeedPicker")
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
                LazyVGrid(columns:[GridItem(.adaptive(minimum:135,maximum:190),spacing:24,alignment:.top)],alignment:.leading,spacing:25) {
                    ForEach(catalog.books) { book in
                        NavigationLink { ZLibraryBookView(book:book,close:close) } label: {
                            VStack(alignment:.leading,spacing:8) {
                                ZLibraryCover(book:book)
                                Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                Text(book.author.isEmpty ? "Unknown author" : book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(book.fileSummary).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                if !book.editionSummary.isEmpty { Text(book.editionSummary).font(.caption2).foregroundStyle(.secondary) }
                                Label(book.ratingSummary,systemImage:book.rating == nil ? "star" : "star.fill")
                                    .font(.caption2).foregroundStyle(book.rating == nil ? Color.secondary : theme.accent)
                                    .fixedSize(horizontal:false,vertical:true)
                                if library.books.contains(where: { $0.catalogSource == book.sourceID }) {
                                    Label("In library",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(theme.accent)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("catalogBook-\(book.remoteID)")
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
            }.padding(24).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity)
        }
        .background(theme.canvas).toolbarBackground(theme.canvas, for: .navigationBar).navigationTitle("Z-Library").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { sheet = .connection } label: { Image(systemName:"person.crop.circle") }.accessibilityLabel("Z-Library connection") } }
        .onAppear { searchText = catalog.activeQuery }
        .onChange(of: searchText) { _, value in
            if value.isEmpty && !catalog.activeQuery.isEmpty { Task { await catalog.search("") } }
        }
        .onDisappear { catalog.cancelCatalogLoad() }
        .task { await catalog.search(catalog.activeQuery) }
        .refreshable { await catalog.reload() }
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item:$sheet,onDismiss: { Task { await catalog.reload() } }) { sheet in
            if sheet == .website { ZLibraryWebsiteSignIn() } else { ZLibraryConnectionView() }
        }
        .presentationDetents([.large])
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
    @State private var loadingDetails = false
    @State private var detailsAttempt = 0
    @State private var detailsRequest = UUID()
    private var edition: ZLibraryBook { resolved ?? book }
    private var existing: Book? { library.books.first { $0.catalogSource == book.sourceID } }
    var body: some View {
        ScrollView {
            VStack(spacing:18) {
                ZLibraryCover(book:edition).frame(width:150)
                Text(edition.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text(edition.author).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:14) {
                    Text("This edition").font(.caption).foregroundStyle(.secondary)
                    HStack { Image(systemName:"doc").font(.title2).foregroundStyle(theme.accent); VStack(alignment:.leading,spacing:4) {
                        Text(edition.fileExtension.isEmpty ? "Format unavailable" : edition.fileSummary).font(.headline)
                        Text(edition.editionSummary).font(.subheadline).foregroundStyle(.secondary)
                    };Spacer() }
                    Text(edition.fileExtension.isEmpty ? (detailsError == nil ? "Loading edition information…" : "Edition information unavailable") : edition.format == nil ? "This format cannot be opened in Leaf." : edition.format == .pdf ? "Original page layout" : "Reading appearance can be adjusted in Leaf").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(theme.surface,in:.rect(cornerRadius:18))
                VStack(alignment:.leading,spacing:12) {
                    Text("Ratings & reviews").font(.headline)
                    Label(edition.ratingSummary,systemImage:edition.rating == nil ? "star" : "star.fill").foregroundStyle(theme.accent)
                    if let quality = edition.qualityScore {
                        Label("File quality \(quality.formatted(.number.precision(.fractionLength(0...1))))",systemImage:"checkmark.seal").font(.subheadline)
                    }
                    Text("Scores are supplied by Z-Library. Written reviews are not available through this connection.").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(theme.surface,in:.rect(cornerRadius:18))
                if let error = catalog.importError { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("catalogImportError") }
                if catalog.downloadingID == book.id {
                    if let progress = catalog.progress { ProgressView(value:progress).accessibilityLabel("Download progress") } else { ProgressView("Preparing download…") }
                    Button("Cancel download") { catalog.cancelDownload() }.accessibilityIdentifier("cancelCatalogDownload")
                }
            }.padding(24).frame(maxWidth:520).frame(maxWidth:.infinity)
        }
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
                    }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent).controlSize(.large).disabled(catalog.downloadingID != nil || library.isImporting).accessibilityIdentifier("catalogAddBook")
                    Text("Saved on this device for offline reading").font(.caption).foregroundStyle(.secondary)
                }
            }.padding().frame(maxWidth:.infinity).background(.regularMaterial)
        }
        .sheet(isPresented:$connection) { ZLibraryConnectionView() }
        .onAppear { catalog.resetImportResult() }
        .task(id: "\(catalog.connected):\(detailsAttempt)") { await loadDetails() }
        .onDisappear { if catalog.downloadingID == book.id { catalog.cancelDownload() } }
    }
    private func loadDetails() async {
        guard edition.fileExtension.isEmpty else { return }
        let request = UUID(); detailsRequest = request; loadingDetails = true; detailsError = nil
        defer { if request == detailsRequest { loadingDetails = false } }
        do {
            let details = try await catalog.details(book)
            try Task.checkCancellation()
            guard request == detailsRequest else { return }
            resolved = details
        } catch {
            if request == detailsRequest && !Task.isCancelled && !ZLibraryStore.isCancellation(error) { detailsError = error.localizedDescription }
        }
    }
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
        fixture = store.isPreview && UITesting.flag("LEAF_UI_ZLIB_WEBSITE_FIXTURE")
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

private struct ZLibraryCover: View {
    let book: ZLibraryBook
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage:image).resizable().scaledToFit() }
            else { BookCover(book:book.placeholder) }
        }.aspectRatio(0.68,contentMode:.fit).clipShape(.rect(cornerRadius:8))
            .task(id:book.coverURL) { if let url = book.coverURL { image = await ZLibraryImages.shared.image(url) } }
    }
}
@MainActor private final class ZLibraryImages {
    static let shared = ZLibraryImages()
    private let cache = NSCache<NSURL,UIImage>()
    init() { cache.countLimit = 40;cache.totalCostLimit = 8 * 1024 * 1024 }
    func image(_ url:URL) async -> UIImage? {
        if let image = cache.object(forKey:url as NSURL) { return image }
        do {
            let payload = try await ZLibraryHTTPTransport().send(URLRequest(url:url),toFile:false,progress: { _ in })
            try Task.checkCancellation()
            guard (200...299).contains(payload.response.statusCode),
                  let source = CGImageSourceCreateWithData(payload.data as CFData,nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:360,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
            let image = UIImage(cgImage:cg);cache.setObject(image,forKey:url as NSURL,cost:cg.bytesPerRow*cg.height);return image
        } catch { return nil }
    }
}
