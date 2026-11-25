import SwiftUI
import UniformTypeIdentifiers

@main
struct LeafReaderApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var catalog: ZLibraryStore
    @StateObject private var bestsellers: BestsellerStore
    @StateObject private var webNovels: WebNovelStore
    @StateObject private var bookLists: BookListStore
    @StateObject private var discoverLists: DiscoverListsStore
    @StateObject private var bookReviews: BookReviewStore
    @StateObject private var agentTraces: AgentTraceStore
    @StateObject private var sync: ICloudSync
    private let readingDefaults: UserDefaults

    init() {
        var root: URL?
        var seedSamples = true
        var defaults = UserDefaults.standard
        var chatProvider: (any ChatProvider)?
        var chatGPT: ChatGPTAccountStore?
        var chatCredentials = KeychainChatCredentials()
        var catalogClient: (any ZLibraryServing)?
        var catalogDiscovery = true
        var bestsellerService: (any BestsellerServing)?
        var bestsellerShelf = true
        var webNovelService: (any WebNovelServing)?
        var bookListService: (any BookListServing)?
        var reviewService: (any BookReviewServing)?
        var syncFolder: URL?
        #if DEBUG
        if let id = UITesting.testID {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUITests/\(id.uuidString)", isDirectory: true)
            seedSamples = !UITesting.flag(.emptyLibrary)
            // Book pages never ask the live review sites during UI tests.
            reviewService = UITestBookReviewClient()
            chatCredentials.service = "com.leafreader.uitests.\(id.uuidString)"
            if UITesting.flag(.chatMock) {
                chatProvider = UITestChatProvider(slow: UITesting.flag(.chatSlow))
            }
            if UITesting.flag(.chatRecovery) { chatProvider = UITestRecoveryChatProvider() }
            defaults = UITesting.defaults
            if UITesting.flag(.syncFixture), let root {
                syncFolder = UITestSyncFixture.seed(next: root)
                defaults.set(false, forKey: ICloudSync.Keys.keepBooks)
            }
            if UITesting.flag(.chatgptConnected) {
                chatGPT = ChatGPTAccountStore.uiTestConnected(defaults: defaults, credentials: chatCredentials)
            }
            // UI tests never reach the live catalog from the library; shelf cases opt in.
            catalogDiscovery = UITesting.flag(.zlibMock) && UITesting.flag(.zlibShelf)
            bestsellerShelf = UITesting.flag(.bestsellersMock)
            if bestsellerShelf { bestsellerService = UITestBestsellerClient(); catalogClient = UITestZLibraryClient() }
            if UITesting.flag(.webNovelsMock) { webNovelService = UITestWebNovelClient(); catalogClient = UITestZLibraryClient() }
            if UITesting.flag(.bookListsMock) { bookListService = UITestBookListClient(); catalogClient = UITestZLibraryClient() }
            if UITesting.flag(.zlibMock) {
                catalogClient = UITestZLibraryClient()
                if UITesting.flag(.zlibWebsiteFixture) {
                    defaults.set("https://catalog.example", forKey: "zlibrary.origin")
                }
            }
        } else if NSClassFromString("XCTestCase") != nil {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUnitTests/\(UUID().uuidString)", isDirectory: true)
            seedSamples = false
            catalogDiscovery = false
            bestsellerShelf = false
        }
        #endif
        let libraryStore = LibraryStore(root: root, seedSamples: seedSamples)
        _library = StateObject(wrappedValue: libraryStore)
        #if DEBUG
        // A saved place for the Bookmarks tab's chat, without opening a book first.
        if UITesting.flag(.savedFixture), let book = libraryStore.books.first(where: { $0.format != .pdf }), book.bookmarks.isEmpty {
            libraryStore.toggleBookmark(book.id, locator: "leaf-ui-saved-fixture", fraction: 0.42, label: "Fixture bookmark")
        }
        #endif
        _agentTraces = StateObject(wrappedValue: AgentTraceStore(directory: libraryStore.disk?.root.appendingPathComponent("AgentTraces", isDirectory: true)))
        _aiSettings = StateObject(wrappedValue: AISettingsStore(defaults: defaults, credentials: chatCredentials, providerOverride: chatProvider, chatGPTOverride: chatGPT))
        var catalogCredentials = chatCredentials
        catalogCredentials.service += ".zlibrary"
        #if DEBUG
        if UITesting.flag(.bestsellersMock) || UITesting.flag(.webNovelsMock) || UITesting.flag(.bookListsMock), !UITesting.flag(.bestsellersDisconnected) {
            let value = ZLibrarySession(userID: "bestseller-preview", userKey: "fixture-only")
            try? catalogCredentials.write(String(decoding: JSONEncoder().encode(value), as: UTF8.self), account: defaults.string(forKey: "zlibrary.origin") ?? "https://z-library.sk")
        }
        #endif
        _catalog = StateObject(wrappedValue: ZLibraryStore(defaults: defaults, credentials: catalogCredentials, client: catalogClient, discoversFromLibrary: catalogDiscovery))
        var bestsellerCredentials = chatCredentials; bestsellerCredentials.service += ".nytbooks"
        _bestsellers = StateObject(wrappedValue: BestsellerStore(defaults: defaults, credentials: bestsellerCredentials,
            service: bestsellerService ?? BestsellerFeedClient(), allowsAutomaticShelf: bestsellerShelf))
        _webNovels = StateObject(wrappedValue: WebNovelStore(defaults: defaults, service: webNovelService ?? WebNovelClient()))
        _bookLists = StateObject(wrappedValue: BookListStore(defaults: defaults, service: bookListService ?? BookListClient()))
        _discoverLists = StateObject(wrappedValue: DiscoverListsStore(defaults: defaults))
        // NYT reviews use the reader's own NYT Books key, when they saved one.
        _bookReviews = StateObject(wrappedValue: BookReviewStore(defaults: defaults, service: reviewService ?? BookReviewClient(),
            nytKey: { [bestsellerCredentials] in ((try? bestsellerCredentials.read(account: "nyt-books")) ?? nil) }))
        readingDefaults = defaults
        if root == nil, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            Task.detached(priority: .utility) { try? RetiredVoicePackCleanup.removeDownloadedPack(applicationSupport: support) }
        }
        let syncState = root.map { $0.appendingPathComponent("SyncState", isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LeafSync", isDirectory: true)
        _sync = StateObject(wrappedValue: ICloudSync(library: libraryStore, defaults: defaults, stateDirectory: syncState, folderOverride: syncFolder))
        // The recorder is configured on every launch so Settings › Diagnostics
        // can turn it on and off; the drift UI tests start with it on, so its
        // observer recognizer is proven not to change how reader taps behave.
        var diagnosticsEnvironment = ProcessInfo.processInfo.environment
        #if DEBUG
        if UITesting.flag(.scrollTouchTrace) { diagnosticsEnvironment["LEAF_SCROLL_DIAGNOSTICS"] = "1" }
        #endif
        ReaderScrollDiagnostics.shared.configure(defaults: defaults, environment: diagnosticsEnvironment,
            directory: (root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)?.appendingPathComponent("Diagnostics", isDirectory: true))
    }

    var body: some Scene {
        WindowGroup {
            AppView().environmentObject(library).environmentObject(aiSettings).environmentObject(catalog).environmentObject(bestsellers).environmentObject(bestsellers.matching).environmentObject(webNovels).environmentObject(bookLists).environmentObject(discoverLists).environmentObject(bookReviews).environmentObject(agentTraces).environmentObject(sync).defaultAppStorage(readingDefaults).tint(LeafStyle.accent)
                #if DEBUG
                .background(UITestSceneGeometryBridge())
                .background(UITestScrollTouchProbe())
                #endif
        }
    }
}

struct ReadingDestination: Identifiable {
    let id: UUID
    var locator: String? = nil
}

enum AppTab: Hashable { case library, discover, bookmarks, settings }

struct AppView: View {
    @AppStorage("reader.theme") private var themeName = ReadingTheme.day.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeName) ?? .day }
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var bestsellers: BestsellerStore
    @EnvironmentObject private var webNovels: WebNovelStore
    @EnvironmentObject private var bookLists: BookListStore
    @EnvironmentObject private var discoverLists: DiscoverListsStore
    @EnvironmentObject private var sync: ICloudSync
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.library
    @State private var discoverStack = UUID()
    @StateObject private var discoverChat = TabChat()
    @State private var importing = false
    @State private var destination: ReadingDestination?
    @State private var pendingURLs: [URL] = []
    @State private var drainingImports = false
    var body: some View {
        TabView(selection: $tab) {
            LibraryView(onImport: { importing = true }, onOpen: { open($0) },
                        onDiscover: { showCharts(bestsellers: false); catalog.show($0); tab = .discover },
                        onSearchCatalog: { showCharts(bestsellers: false); catalog.show(query: $0); tab = .discover },
                        onBestsellers: { showCharts(bestsellers: true); catalog.show(catalog.feed); tab = .discover })
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppTab.library)
            NavigationStack {
                // Returning to the library also leaves the details of an added book.
                ZLibraryView(close: { tab = .library; discoverStack = UUID() })
            }.id(discoverStack)
                .modifier(TabChatHost(chat: discoverChat, finishMovingIdentifier: "finishMovingDiscoverChatButton",
                                      screen: { ChatScreen.discover(catalog, library: library, bestsellers: bestsellers, webNovels: webNovels, bookLists: bookLists) }))
                .tabItem { Label("Discover", systemImage: "safari") }.tag(AppTab.discover)
            BookmarksView(onOpen: { id, locator in open(id, locator: locator) })
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }.tag(AppTab.bookmarks)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(AppTab.settings)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): enqueue(urls)
            case .failure(let error): library.notice = LibraryNotice(title: "Could not open Files", message: error.localizedDescription)
            }
        }
        .onOpenURL { enqueue([$0]) }
        .task {
            // Discover opens on the list last chosen on this device.
            discoverLists.remembered?.show(catalog: catalog, bestsellers: bestsellers, novels: webNovels, lists: bookLists)
            await library.refreshMissingMetadata(); sync.schedule(after: 0)
        }
        .fullScreenCover(item: $destination, onDismiss: { library.flush() }) { target in
            ReaderView(bookID: target.id, initialLocator: target.locator).environmentObject(library).environment(\.leafTheme, theme)
        }
        .alert(item: $library.notice) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("OK"))) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                library.flush()
                Task { try? await catalog.saveWebsiteContext() }
            } else { sync.schedule(after: 0) }
        }
        .onChange(of: library.isImporting) { _, busy in if !busy { processQueue() } }
        .environment(\.leafTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .toolbarBackground(theme.canvas, for: .tabBar)
    }
    /// A book synced from iCloud may not be on this device yet; download it first.
    /// Leaving Library for the catalog or the bestseller lists takes Discover off the other lists.
    private func showCharts(bestsellers show: Bool) { bestsellers.showingBestsellers = show; webNovels.showing = false; bookLists.showing = false }
    private func open(_ id: UUID, locator: String? = nil) {
        guard let book = library.book(id), !library.isDownloaded(book), sync.isConnected else {
            destination = ReadingDestination(id: id, locator: locator); return
        }
        Task {
            do {
                try await sync.download(book)
                destination = ReadingDestination(id: id, locator: locator)
            } catch {
                library.notice = LibraryNotice(title: "Could not download “\(book.title)”",
                    message: "Check that iCloud Drive is on and connected, then try again. \(error.localizedDescription)")
            }
        }
    }
    private func enqueue(_ urls: [URL]) { pendingURLs.append(contentsOf: urls); processQueue() }
    private func processQueue() {
        guard !drainingImports, !library.isImporting, !pendingURLs.isEmpty else { return }
        drainingImports = true
        Task {
            while !pendingURLs.isEmpty {
                let urls = pendingURLs
                pendingURLs.removeAll()
                await library.importBooks(urls)
            }
            drainingImports = false
        }
    }
}
