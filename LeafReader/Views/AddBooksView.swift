import SwiftUI
import WebKit
import ImageIO

struct AddBooksView: View {
    let openFiles: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var detent: PresentationDetent = .medium
    var body: some View {
        NavigationStack(path:$path) {
            List {
                Button(action: openFiles) {
                    source("From Files", subtitle:"On your iPhone, iCloud Drive & more", icon:"folder")
                }.accessibilityIdentifier("addFromFiles")
                NavigationLink(value:"zlibrary") {
                    source("Z-Library",subtitle:"Browse the most popular books",icon:"book")
                }.accessibilityIdentifier("addFromZLibrary")
                Section { Text("Books you add are saved on this device for offline reading.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Add books").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for:String.self) { _ in ZLibraryView(close: { dismiss() }) }
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Close",systemImage:"xmark") { dismiss() }.labelStyle(.iconOnly) } }
        }.presentationDetents([.medium,.large],selection:$detent).presentationDragIndicator(.visible)
            .onChange(of:path) { _, value in detent = value.isEmpty ? .medium : .large }
    }
    private func source(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing:14) {
            Image(systemName:icon).font(.title2).foregroundStyle(LeafStyle.accent).frame(width:46,height:46)
                .background(LeafStyle.accent.opacity(0.1),in:.rect(cornerRadius:13))
            VStack(alignment:.leading,spacing:4) { Text(title).font(.headline).foregroundStyle(.primary);Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical,8)
    }
}

struct ZLibraryView: View {
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    private enum Sheet: String, Identifiable { case connection, website; var id: String { rawValue } }
    @State private var sheet: Sheet?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(alignment:.firstTextBaseline) {
                    Text("Most popular").font(.system(size:32,weight:.regular,design:.serif))
                    Spacer()
                    if catalog.isPreview { Text("Preview").font(.caption).foregroundStyle(.secondary) }
                }
                if !catalog.connected {
                    Button { sheet = .connection } label: { Label("Connect Z-Library",systemImage:"person.crop.circle") }
                        .buttonStyle(.bordered).accessibilityIdentifier("connectZLibrary")
                }
                if catalog.loading && catalog.books.isEmpty {
                    ProgressView("Loading popular books…").frame(maxWidth:.infinity).padding(.vertical,70)
                }
                if let error = catalog.error {
                    VStack(alignment:.leading,spacing:12) {
                        Label("Could not load popular books",systemImage:"exclamationmark.circle").font(.headline)
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            if catalog.websiteAccessNeeded {
                                Button("Open website") { Task { await catalog.seedWebsite(); sheet = .website } }
                                    .accessibilityIdentifier("zlibraryCheckWebsite")
                            } else { Button("Connection") { sheet = .connection } }
                            Button("Try again") { Task { await catalog.loadPopular() } }.disabled(catalog.loading)
                        }.buttonStyle(.bordered)
                        if let diagnostic = catalog.requestDiagnostic {
                            DisclosureGroup("Request details") {
                                Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled)
                                    .accessibilityIdentifier("zlibraryRequestDiagnostic")
                                Text("Contains no cookies, account details, or response content.").font(.caption2).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                        Text("You can also download a book using your browser and add it from Files.").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:.rect(cornerRadius:18))
                } else if !catalog.loading && catalog.books.isEmpty {
                    ContentUnavailableView("No books available",systemImage:"books.vertical",description:Text("Pull down to refresh the popular books list."))
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:135,maximum:190),spacing:24,alignment:.top)],alignment:.leading,spacing:25) {
                    ForEach(catalog.books) { book in
                        NavigationLink { ZLibraryBookView(book:book,close:close) } label: {
                            VStack(alignment:.leading,spacing:8) {
                                ZLibraryCover(book:book)
                                Text(book.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                                Text(book.author.isEmpty ? "Unknown author" : book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if library.books.contains(where: { $0.catalogSource == book.sourceID }) {
                                    Label("In library",systemImage:"checkmark.circle.fill").font(.caption).foregroundStyle(LeafStyle.accent)
                                } else {
                                    Text([book.fileExtension.uppercased(),book.language].filter { !$0.isEmpty }.joined(separator:" · ")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("catalogBook-\(book.remoteID)")
                    }
                }
            }.padding(24).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity)
        }
        .background(LeafStyle.canvas).navigationTitle("Z-Library").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { sheet = .connection } label: { Image(systemName:"person.crop.circle") }.accessibilityLabel("Z-Library connection") } }
        .task { if catalog.books.isEmpty { await catalog.loadPopular() } }
        .refreshable { await catalog.loadPopular() }
        .sheet(item:$sheet,onDismiss: { Task { await catalog.loadPopular() } }) { sheet in
            if sheet == .website { ZLibraryWebsiteSignIn() } else { ZLibraryConnectionView() }
        }
        .presentationDetents([.large])
    }
}

struct ZLibraryBookView: View {
    let book: ZLibraryBook
    let close: () -> Void
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @State private var connection = false
    private var existing: Book? { library.books.first { $0.catalogSource == book.sourceID } }
    var body: some View {
        ScrollView {
            VStack(spacing:18) {
                ZLibraryCover(book:book).frame(width:150)
                Text(book.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text(book.author).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:14) {
                    Text("This edition").font(.caption).foregroundStyle(.secondary)
                    HStack { Image(systemName:"doc").font(.title2).foregroundStyle(LeafStyle.accent); VStack(alignment:.leading,spacing:4) {
                        Text([book.fileExtension.uppercased(),book.size].filter { !$0.isEmpty }.joined(separator:" · ")).font(.headline)
                        Text([book.language,book.year].filter { !$0.isEmpty }.joined(separator:" · ")).font(.subheadline).foregroundStyle(.secondary)
                    };Spacer() }
                    Text(book.format == .pdf ? "Original page layout" : "Reading appearance can be adjusted in Leaf").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:.rect(cornerRadius:18))
                if let error = catalog.importError { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("catalogImportError") }
                if catalog.downloadingID == book.id {
                    if let progress = catalog.progress { ProgressView(value:progress).accessibilityLabel("Download progress") } else { ProgressView("Preparing download…") }
                    Button("Cancel download") { catalog.cancelDownload() }.accessibilityIdentifier("cancelCatalogDownload")
                }
            }.padding(24).frame(maxWidth:520).frame(maxWidth:.infinity)
        }
        .background(LeafStyle.canvas).navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge:.bottom) {
            VStack(spacing:8) {
                if existing != nil {
                    Label("Added to your library",systemImage:"checkmark.circle.fill").font(.subheadline).foregroundStyle(LeafStyle.accent).accessibilityIdentifier("catalogAdded")
                    Button("View in library",action:close).buttonStyle(.borderedProminent).accessibilityIdentifier("catalogViewLibrary")
                } else if book.format == nil {
                    Text("Leaf does not support this edition’s format. Choose another book or edition.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button { if catalog.connected { catalog.add(book,library:library) } else { connection = true } } label: {
                        Label(catalog.downloadingID == book.id ? "Adding to library…" : catalog.connected ? "Add to library" : "Connect to add book",systemImage:"plus").frame(maxWidth:.infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(catalog.downloadingID != nil || library.isImporting).accessibilityIdentifier("catalogAddBook")
                    Text("Saved on this device for offline reading").font(.caption).foregroundStyle(.secondary)
                }
            }.padding().frame(maxWidth:.infinity).background(.regularMaterial)
        }
        .sheet(isPresented:$connection) { ZLibraryConnectionView() }
        .onAppear { catalog.resetImportResult() }
        .onDisappear { if catalog.downloadingID == book.id { catalog.cancelDownload() } }
    }
}

struct ZLibraryConnectionView: View {
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var addressError: String?
    @State private var signingIn = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Website") {
                    TextField("https://z-library.sk",text:$address).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("zlibraryAddress")
                    Button("Save website address") { Task { do { try await catalog.changeAddress(address); addressError = nil } catch { addressError = error.localizedDescription } } }
                    if let addressError { Text(addressError).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    if catalog.connected {
                        Label("Account connected",systemImage:"checkmark.shield").foregroundStyle(LeafStyle.accent)
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
            }
            .navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Close",systemImage:"xmark") { dismiss() }.labelStyle(.iconOnly).accessibilityLabel("Close connection") } }
            .onAppear { address = catalog.origin.url.absoluteString }
            .sheet(isPresented:$signingIn) { ZLibraryWebsiteSignIn().environmentObject(catalog) }
        }
    }
}

struct ZLibraryWebsiteSignIn: View {
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var checking = false
    @State private var checkTask: Task<Void,Never>?
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                ZLibrarySignInWebView(store:catalog,message:$message)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding() }
                if let error = catalog.connectionError { Text(error).font(.footnote).foregroundStyle(.red).padding() }
                Button { checking = true; checkTask = Task {
                    let cookies = await catalog.websiteData.httpCookieStore.allCookies()
                    if let candidate = catalog.cookieCandidate(cookies) {
                        if await catalog.connect(candidate) { dismiss() }
                    } else { message = "Finish signing in on the website, then tap Check connection." }
                    checking = false
                } } label: { HStack { if checking { ProgressView() }; Text("Check connection") }.frame(maxWidth:.infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(checking).padding()
            }
            .navigationTitle(catalog.origin.url.host ?? "Z-Library").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarLeading) { Button("Cancel") { checkTask?.cancel();dismiss() } } }
            .onDisappear { checkTask?.cancel() }
        }
    }
}

private struct ZLibrarySignInWebView: UIViewRepresentable {
    let store: ZLibraryStore
    @Binding var message: String?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = store.websiteData
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame:.zero,configuration:config); view.navigationDelegate = context.coordinator
        view.isInspectable = false; view.load(URLRequest(url:store.origin.url)); return view
    }
    func updateUIView(_ uiView: WKWebView, context:Context) {}
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator) { view.stopLoading();view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: ZLibrarySignInWebView
        init(_ parent: ZLibrarySignInWebView) { self.parent = parent }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping (WKNavigationActionPolicy)->Void) {
            guard let url = action.request.url else { decisionHandler(.cancel);return }
            if url.absoluteString == "about:blank" || parent.store.origin.contains(url) || (action.targetFrame?.isMainFrame == false && url.scheme == "https" && url.user == nil && url.password == nil) { decisionHandler(.allow) }
            else { parent.message = "This link opens another website (\(url.host ?? "unknown")). If it is your trusted sign-in website, set its address in Connection first.";decisionHandler(.cancel) }
        }
        func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
            if (error as NSError).code != NSURLErrorCancelled { parent.message = "The website could not be loaded. Check its address and your connection." }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url, parent.store.origin.contains(url) else { return }
            // Keep normal API requests consistent with the browser session the user opened.
            // This reads only browser identity; it never solves or automates verification.
            webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
                if let text = value as? String { self?.parent.store.captureWebsiteUserAgent(text) }
            }
        }
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
