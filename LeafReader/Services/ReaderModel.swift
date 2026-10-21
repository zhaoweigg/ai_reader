import SwiftUI
import WebKit
import PDFKit

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
    let bookID: UUID
    let library: LibraryStore
    let initialLocator: String?
    weak var webView: WKWebView?
    weak var pdfView: PDFView?
    var preferences: ReaderPreferences?
    private var searchGeneration = UUID().uuidString

    init(bookID: UUID, library: LibraryStore, initialLocator: String?) {
        self.bookID = bookID; self.library = library; self.initialLocator = initialLocator
        super.init()
        locator = initialLocator ?? library.book(bookID)?.locator ?? ""
        fraction = library.book(bookID)?.progress ?? 0
    }
    var book: Book? { library.book(bookID) }
    var isBookmarked: Bool { book?.bookmarks.contains { $0.locator == locator } ?? false }
    var positionLabel: String { "\(Int(fraction * 100))%" }
    func toggleBookmark() {
        library.toggleBookmark(bookID, locator: locator, fraction: fraction,
                               label: chapterTitle.isEmpty ? "Saved at \(positionLabel)" : chapterTitle)
    }
    func send(_ action: String, value: Any? = nil) {
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
        webView?.evaluateJavaScript("void window.Leaf.\(method)(\(json))") { [weak self] _, error in
            if let error { self?.error = error.localizedDescription; self?.isSearching = false }
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
        pdfView = view
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
        locator = "pdf:\(index)"; fraction = doc.pageCount > 1 ? Double(index) / Double(doc.pageCount - 1) : 0
        chapterTitle = "Page \(index + 1) of \(doc.pageCount)"
        library.setPosition(bookID, locator: locator, fraction: fraction)
    }
}
