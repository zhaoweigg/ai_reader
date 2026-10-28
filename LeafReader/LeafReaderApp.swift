import SwiftUI
import UniformTypeIdentifiers

@main
struct LeafReaderApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var catalog: ZLibraryStore
    @StateObject private var agentTraces: AgentTraceStore
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
        #if DEBUG
        if let id = UITesting.testID {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUITests/\(id.uuidString)", isDirectory: true)
            seedSamples = !UITesting.flag("LEAF_UI_EMPTY_LIBRARY")
            chatCredentials.service = "com.leafreader.uitests.\(id.uuidString)"
            if UITesting.flag("LEAF_UI_CHAT_MOCK") {
                chatProvider = UITestChatProvider(slow: UITesting.flag("LEAF_UI_CHAT_SLOW"))
            }
            defaults = UITesting.defaults
            if UITesting.flag("LEAF_UI_CHATGPT_CONNECTED") {
                chatGPT = ChatGPTAccountStore.uiTestConnected(defaults: defaults, credentials: chatCredentials)
            }
            // UI tests never reach the live catalog from the library; shelf cases opt in.
            catalogDiscovery = UITesting.flag("LEAF_UI_ZLIB_MOCK") && UITesting.flag("LEAF_UI_ZLIB_SHELF")
            if UITesting.flag("LEAF_UI_ZLIB_MOCK") {
                catalogClient = UITestZLibraryClient()
                if UITesting.flag("LEAF_UI_ZLIB_WEBSITE_FIXTURE") {
                    defaults.set("https://catalog.example", forKey: "zlibrary.origin")
                }
            }
        } else if NSClassFromString("XCTestCase") != nil {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUnitTests/\(UUID().uuidString)", isDirectory: true)
            seedSamples = false
            catalogDiscovery = false
        }
        #endif
        let libraryStore = LibraryStore(root: root, seedSamples: seedSamples)
        _library = StateObject(wrappedValue: libraryStore)
        _agentTraces = StateObject(wrappedValue: AgentTraceStore(directory: libraryStore.disk?.root.appendingPathComponent("AgentTraces", isDirectory: true)))
        _aiSettings = StateObject(wrappedValue: AISettingsStore(defaults: defaults, credentials: chatCredentials, providerOverride: chatProvider, chatGPTOverride: chatGPT))
        var catalogCredentials = chatCredentials
        catalogCredentials.service += ".zlibrary"
        _catalog = StateObject(wrappedValue: ZLibraryStore(defaults: defaults, credentials: catalogCredentials, client: catalogClient, discoversFromLibrary: catalogDiscovery))
        readingDefaults = defaults
        if root == nil {
            ReaderScrollDiagnostics.shared.configure(defaults: .standard,
                directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Diagnostics", isDirectory: true))
        }
    }

    var body: some Scene {
        WindowGroup {
            AppView().environmentObject(library).environmentObject(aiSettings).environmentObject(catalog).environmentObject(agentTraces).defaultAppStorage(readingDefaults).tint(LeafStyle.accent)
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.library
    @State private var discoverStack = UUID()
    @State private var importing = false
    @State private var destination: ReadingDestination?
    @State private var pendingURLs: [URL] = []
    @State private var drainingImports = false
    var body: some View {
        TabView(selection: $tab) {
            LibraryView(onImport: { importing = true }, onOpen: { destination = ReadingDestination(id: $0) },
                        onDiscover: { catalog.show($0); tab = .discover },
                        onSearchCatalog: { catalog.show(query: $0); tab = .discover })
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppTab.library)
            NavigationStack {
                // Returning to the library also leaves the details of an added book.
                ZLibraryView(close: { tab = .library; discoverStack = UUID() })
            }.id(discoverStack)
                .tabItem { Label("Discover", systemImage: "safari") }.tag(AppTab.discover)
            BookmarksView(onOpen: { id, locator in destination = ReadingDestination(id: id, locator: locator) })
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
        .task { await library.refreshMissingMetadata() }
        .fullScreenCover(item: $destination, onDismiss: { library.flush() }) { target in
            ReaderView(bookID: target.id, initialLocator: target.locator).environmentObject(library).environment(\.leafTheme, theme)
        }
        .alert(item: $library.notice) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("OK"))) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                library.flush()
                Task { try? await catalog.saveWebsiteContext() }
            }
        }
        .onChange(of: library.isImporting) { _, busy in if !busy { processQueue() } }
        .environment(\.leafTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.accent)
        .toolbarBackground(theme.canvas, for: .tabBar)
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
