import SwiftUI
import UniformTypeIdentifiers

@main
struct LeafReaderApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var aiSettings: AISettingsStore
    @StateObject private var catalog: ZLibraryStore
    private let readingDefaults: UserDefaults

    init() {
        var root: URL?
        var seedSamples = true
        var defaults = UserDefaults.standard
        var chatProvider: (any ChatProvider)?
        var chatGPT: ChatGPTAccountStore?
        var chatCredentials = KeychainChatCredentials()
        var catalogClient: (any ZLibraryServing)?
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-testing"),
           let value = process.environment["LEAF_UI_TEST_ID"], let id = UUID(uuidString: value) {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUITests/\(id.uuidString)", isDirectory: true)
            seedSamples = process.environment["LEAF_UI_EMPTY_LIBRARY"] != "1"
            chatCredentials.service = "com.leafreader.uitests.\(id.uuidString)"
            if process.environment["LEAF_UI_CHAT_MOCK"] == "1" {
                chatProvider = UITestChatProvider(slow: process.environment["LEAF_UI_CHAT_SLOW"] == "1")
            }
            defaults = UserDefaults(suiteName: "com.leafreader.uitests.\(id.uuidString)") ?? .standard
            if process.environment["LEAF_UI_CHATGPT_CONNECTED"] == "1" {
                chatGPT = ChatGPTAccountStore.uiTestConnected(defaults: defaults, credentials: chatCredentials)
            }
            if process.environment["LEAF_UI_ZLIB_MOCK"] == "1" {
                catalogClient = UITestZLibraryClient()
                if process.environment["LEAF_UI_ZLIB_WEBSITE_FIXTURE"] == "1" {
                    defaults.set("https://catalog.example", forKey: "zlibrary.origin")
                }
            }
        } else if NSClassFromString("XCTestCase") != nil {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUnitTests/\(UUID().uuidString)", isDirectory: true)
            seedSamples = false
        }
        #endif
        _library = StateObject(wrappedValue: LibraryStore(root: root, seedSamples: seedSamples))
        _aiSettings = StateObject(wrappedValue: AISettingsStore(defaults: defaults, credentials: chatCredentials, providerOverride: chatProvider, chatGPTOverride: chatGPT))
        var catalogCredentials = chatCredentials
        catalogCredentials.service += ".zlibrary"
        _catalog = StateObject(wrappedValue: ZLibraryStore(defaults: defaults, credentials: catalogCredentials, client: catalogClient))
        readingDefaults = defaults
    }

    var body: some Scene {
        WindowGroup {
            AppView().environmentObject(library).environmentObject(aiSettings).environmentObject(catalog).defaultAppStorage(readingDefaults).tint(LeafStyle.accent)
                .background {
                    #if DEBUG
                    UITestSceneGeometryBridge()
                    #endif
                }
        }
    }
}

struct ReadingDestination: Identifiable {
    let id: UUID
    var locator: String? = nil
}

struct AppView: View {
    @AppStorage("reader.theme") private var themeName = ReadingTheme.day.rawValue
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeName) ?? .day }
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var addingBooks = false
    @State private var pickFilesAfterDismiss = false
    @State private var destination: ReadingDestination?
    @State private var pendingURLs: [URL] = []
    @State private var drainingImports = false
    var body: some View {
        TabView {
            LibraryView(onImport: { addingBooks = true }, onOpen: { destination = ReadingDestination(id: $0) })
                .tabItem { Label("Library", systemImage: "books.vertical") }
            BookmarksView(onOpen: { id, locator in destination = ReadingDestination(id: id, locator: locator) })
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .sheet(isPresented: $addingBooks, onDismiss: {
            if pickFilesAfterDismiss { pickFilesAfterDismiss = false; importing = true }
        }) { AddBooksView(openFiles: { pickFilesAfterDismiss = true; addingBooks = false }).environment(\.leafTheme, theme).tint(theme.accent) }
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
