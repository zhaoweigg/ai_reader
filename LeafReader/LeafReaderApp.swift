import SwiftUI
import UniformTypeIdentifiers

@main
struct LeafReaderApp: App {
    @StateObject private var library: LibraryStore
    private let readingDefaults: UserDefaults

    init() {
        var root: URL?
        var seedSamples = true
        var defaults = UserDefaults.standard
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-testing"),
           let value = process.environment["LEAF_UI_TEST_ID"], let id = UUID(uuidString: value) {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUITests/\(id.uuidString)", isDirectory: true)
            defaults = UserDefaults(suiteName: "com.leafreader.uitests.\(id.uuidString)") ?? .standard
        } else if NSClassFromString("XCTestCase") != nil {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafUnitTests/\(UUID().uuidString)", isDirectory: true)
            seedSamples = false
        }
        #endif
        _library = StateObject(wrappedValue: LibraryStore(root: root, seedSamples: seedSamples))
        readingDefaults = defaults
    }

    var body: some Scene {
        WindowGroup { AppView().environmentObject(library).defaultAppStorage(readingDefaults).tint(LeafStyle.accent) }
    }
}

struct ReadingDestination: Identifiable {
    let id: UUID
    var locator: String? = nil
}

struct AppView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var destination: ReadingDestination?
    @State private var pendingURLs: [URL] = []
    @State private var drainingImports = false
    var body: some View {
        TabView {
            LibraryView(onImport: { importing = true }, onOpen: { destination = ReadingDestination(id: $0) })
                .tabItem { Label("Library", systemImage: "books.vertical") }
            BookmarksView(onOpen: { id, locator in destination = ReadingDestination(id: id, locator: locator) })
                .tabItem { Label("Bookmarks", systemImage: "bookmark") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
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
            ReaderView(bookID: target.id, initialLocator: target.locator).environmentObject(library)
        }
        .alert(item: $library.notice) { Alert(title: Text($0.title), message: Text($0.message), dismissButton: .default(Text("OK"))) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { library.flush() } }
    }
    private func enqueue(_ urls: [URL]) { pendingURLs.append(contentsOf: urls); processQueue() }
    private func processQueue() {
        guard !drainingImports, !pendingURLs.isEmpty else { return }
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
