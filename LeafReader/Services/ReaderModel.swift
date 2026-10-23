import SwiftUI
import WebKit
import PDFKit
import OSLog

@MainActor
final class ReaderModel: NSObject, ObservableObject {
    @Published var isReady = false
    @Published var error: String?
    @Published var isLocked = false
    @Published var chapterTitle = ""
    @Published var locator = ""
    @Published var fraction = 0.0
    @Published var chapters: [Chapter] = []
    @Published var searchResults: [BookSearchResult] = []
    @Published var isSearching = false
    @Published var hasSearched = false
    @Published var controlsVisible = false
    @Published var selectionRequest: ReaderSelectionRequest?
    @Published private(set) var liveSelection: ReadingChatContext?
    private var selectedWebText = ""
    private var selectedWebLocator: String?
    private var selectedWebChapter: String?
    @Published private(set) var reloadID = UUID()
    let bookID: UUID
    let library: LibraryStore
    let initialLocator: String?
    weak var webView: WKWebView?
    weak var pdfView: PDFView?
    var preferences: ReaderPreferences?
    private var searchGeneration = UUID().uuidString
    private var lastAutomaticRecovery: Date?
    private var memoryWarningObserver: NSObjectProtocol?
    private var pdfSelectionObserver: NSObjectProtocol?
    private var memoryWarningCount = 0
    private static let logger = Logger(subsystem: "com.weizhao.leafreader", category: "ReaderLifecycle")

    init(bookID: UUID, library: LibraryStore, initialLocator: String?) {
        self.bookID = bookID; self.library = library; self.initialLocator = initialLocator
        super.init()
        locator = initialLocator ?? library.book(bookID)?.locator ?? ""
        fraction = library.book(bookID)?.progress ?? 0
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.memoryWarningCount += 1
                Self.logger.warning("Received system memory warning; clearing search results.")
                self.search("")
            }
        }
    }
    deinit {
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        if let pdfSelectionObserver { NotificationCenter.default.removeObserver(pdfSelectionObserver) }
    }
    var book: Book? { library.book(bookID) }
    var isBookmarked: Bool { book?.bookmarks.contains { $0.locator == locator } ?? false }
    var positionLabel: String { "\(Int(fraction * 100))%" }
    func reload() {
        library.flush()
        error = nil; isReady = false; isSearching = false; selectedWebText = ""; liveSelection = nil
        selectedWebLocator = nil; selectedWebChapter = nil
        searchGeneration = UUID().uuidString
        searchResults = []; hasSearched = false
        reloadID = UUID()
    }
    func webProcessTerminated(_ view: WKWebView, now: Date = Date()) {
        guard webView === view else { return }
        Self.logger.error("WebKit reader process stopped; observed native memory warnings: \(self.memoryWarningCount, privacy: .public). Termination cause is unavailable.")
        webView = nil
        // WebKit does not supply a termination cause here. One recovery also
        // handles a suspended process being reclaimed while Leaf is backgrounded.
        if let lastAutomaticRecovery, now.timeIntervalSince(lastAutomaticRecovery) < 60 {
            isReady = false; isSearching = false
            error = "The book renderer stopped again. Reload to continue from your saved place."
        } else {
            lastAutomaticRecovery = now
            reload()
        }
    }
    func readingChatContext() async throws -> ReadingChatContext? {
        guard isReady, !isLocked, error == nil else { throw ChatError.configuration("Wait for the book to finish opening before asking about it.") }
        let title = book?.title ?? ""
        let author = book?.author ?? ""
        var chapter = chapterTitle
        var location = locator
        var text = ""
        var source = "page"
        if let pdfView {
            if let selection = pdfView.currentSelection?.string, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = selection; source = "selection"
            } else { text = pdfView.currentPage?.string ?? "" }
        } else if let webView {
            let result = try await webView.evaluateJavaScript("window.Leaf.chatContext()") as? [String: String]
            text = result?["text"] ?? ""; source = result?["source"] ?? "page"
            if let selectedLocator = result?["locator"], !selectedLocator.isEmpty { location = selectedLocator }
            if let selectedChapter = result?["label"], !selectedChapter.isEmpty { chapter = selectedChapter }
        }
        return ReadingChatContext(title: title, author: author, chapter: chapter, text: text,
                                  source: source, locator: location).bounded()
    }
    func selectedReadingContext() -> ReadingChatContext? {
        let text = pdfView?.currentSelection?.string ?? selectedWebText
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ReadingChatContext(title: book?.title ?? "", author: book?.author ?? "", chapter: pdfView != nil ? chapterTitle : selectedWebChapter ?? chapterTitle,
                                  text: text, source: "selection", locator: pdfView != nil ? locator : selectedWebLocator ?? locator).bounded()
    }
    private func updateLiveSelection() {
        let context = selectedReadingContext()
        if liveSelection != context { liveSelection = context }
    }
    func askAboutSelection(_ intent: ReaderSelectionIntent, context: ReadingChatContext) {
        guard !context.isEmpty else { return }
        selectionRequest = ReaderSelectionRequest(intent: intent, context: context.bounded())
        clearNativeSelection()
    }
    func clearNativeSelection() {
        pdfView?.clearSelection()
        pdfView?.endEditing(true)
        if let webView {
            webView.evaluateJavaScript("window.Leaf.clearSelection()") { [weak webView] _, _ in webView?.endEditing(true) }
        }
    }
    func toggleControls() {
        guard isReady, !isLocked, error == nil else { return }
        controlsVisible.toggle()
    }
    func hideControls() { controlsVisible = false }
    func toggleBookmark() {
        library.toggleBookmark(bookID, locator: locator, fraction: fraction,
                               label: chapterTitle.isEmpty ? "Saved at \(positionLabel)" : chapterTitle)
    }
    func send(_ action: String, value: Any? = nil) {
        if ["next", "previous", "navigate"].contains(action) { hideControls() }
        if let pdfView {
            switch action {
            case "next": if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
            case "previous": if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
            case "navigate": if let target = value as? String { navigatePDF(target) }
            case "seek":
                if let percent = value as? Double, let doc = pdfView.document, doc.pageCount > 0,
                   let page = doc.page(at: Int((min(1, max(0, percent)) * Double(doc.pageCount - 1)).rounded())) { pdfView.go(to: page) }
            default: break
            }
            return
        }
        var payload: [String: Any] = ["action": action]
        if let value { payload["value"] = value }
        evaluate("command", payload)
    }
    func evaluate(_ method: String, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        guard let view = webView else { return }
        view.evaluateJavaScript("void window.Leaf.\(method)(\(json))") { [weak self, weak view] _, error in
            guard let self, let view, self.webView === view else { return }
            if let error { self.error = error.localizedDescription; self.isSearching = false }
        }
    }
    func openWebBook() {
        guard let book, let preferences else { return }
        evaluate("open", ["name": book.title + "." + book.format.rawValue, "format": book.format.rawValue,
                          "locator": locator, "preferences": preferences.payload])
    }
    func applyPreferences(_ value: ReaderPreferences) {
        guard value != preferences else { return }
        preferences = value
        if isReady, book?.format != .pdf { evaluate("applyPreferences", value.payload) }
    }
    func receive(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "selection":
            selectedWebText = String((message["text"] as? String ?? "").prefix(12000))
            selectedWebLocator = (message["locator"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2000)) }
            selectedWebChapter = (message["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            updateLiveSelection()
        case "toggleControls": toggleControls()
        case "readingActivity": hideControls()
        case "bridgeReady": openWebBook()
        case "ready": isReady = true; error = nil
        case "error": error = message["message"] as? String ?? "This book could not be opened. Try importing a fresh copy."; isSearching = false
        case "relocate":
            locator = message["locator"] as? String ?? locator
            fraction = min(1, max(0, message["fraction"] as? Double ?? fraction))
            chapterTitle = message["label"] as? String ?? ""
            library.setPosition(bookID, locator: locator, fraction: fraction)
        case "metadata":
            let cover = (message["cover"] as? String).flatMap { Data(base64Encoded: $0) }
            library.setMetadata(bookID, title: message["title"] as? String, author: message["author"] as? String, cover: cover)
        case "toc":
            chapters = (message["items"] as? [[String: Any]] ?? []).compactMap {
                guard let href = $0["href"] as? String, let label = $0["label"] as? String else { return nil }
                return Chapter(label: label, href: href, depth: $0["depth"] as? Int ?? 0)
            }
        case "searchResults":
            guard message["generation"] as? String == searchGeneration else { return }
            searchResults = (message["items"] as? [[String: String]] ?? []).compactMap {
                guard let locator = $0["locator"] else { return nil }
                return BookSearchResult(label: $0["label"] ?? "Result", excerpt: $0["excerpt"] ?? "", locator: locator)
            }
            isSearching = false
        default: break
        }
    }
    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration = UUID().uuidString
        searchResults = []; hasSearched = !text.isEmpty; isSearching = !text.isEmpty
        guard !text.isEmpty else { if pdfView == nil { send("clearSearch") }; return }
        if let pdfView, let doc = pdfView.document {
            let results = doc.findString(text, withOptions: [.caseInsensitive])
            searchResults = results.prefix(200).compactMap { selection in
                guard let page = selection.pages.first else { return nil }
                let index = doc.index(for: page)
                return BookSearchResult(label: "Page \(index + 1)", excerpt: selection.selectionsByLine().compactMap(\.string).joined(separator: " "), locator: "pdf:\(index)")
            }
            isSearching = false
        } else { evaluate("search", ["query": text, "generation": searchGeneration]) }
    }
    func configurePDF(_ view: PDFView, url: URL) {
        if let pdfSelectionObserver { NotificationCenter.default.removeObserver(pdfSelectionObserver) }
        pdfView = view
        pdfSelectionObserver = NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.pdfView === view else { return }
                self.updateLiveSelection()
            }
        }
        guard let document = PDFDocument(url: url) else { error = LibraryError.invalidPDF.localizedDescription; return }
        view.document = document
        isLocked = document.isLocked
        if !isLocked { finishPDFSetup(view) }
    }
    func unlockPDF(_ password: String) {
        guard let pdfView, let document = pdfView.document else { return }
        if document.unlock(withPassword: password) { isLocked = false; error = nil; finishPDFSetup(pdfView) }
        else { error = "That password did not unlock this PDF. Try again." }
    }
    private func finishPDFSetup(_ view: PDFView) {
        guard let doc = view.document else { return }
        chapters = (0..<doc.pageCount).map { Chapter(label: "Page \($0 + 1)", href: "pdf:\($0)") }
        if !locator.isEmpty { navigatePDF(locator) }
        else if let first = doc.page(at: 0) { view.go(to: first) }
        isReady = true
        if let cover = doc.page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 440), for: .cropBox).pngData() {
            library.setMetadata(bookID, title: nil, author: nil, cover: cover)
        }
        pdfPageChanged()
    }
    private func navigatePDF(_ target: String) {
        guard target.hasPrefix("pdf:"), let index = Int(target.dropFirst(4)), let page = pdfView?.document?.page(at: index) else { return }
        pdfView?.go(to: page)
    }
    func pdfPageChanged() {
        guard isReady, let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        let index = doc.index(for: page)
        guard index != NSNotFound else { return }
        if locator != "pdf:\(index)" { hideControls() }
        locator = "pdf:\(index)"; fraction = doc.pageCount > 1 ? Double(index) / Double(doc.pageCount - 1) : 0
        chapterTitle = "Page \(index + 1) of \(doc.pageCount)"
        library.setPosition(bookID, locator: locator, fraction: fraction)
    }
}
