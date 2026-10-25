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
    @Published var listeningRequest: ReaderListeningRequest?
    @Published var annotationDraft: BookAnnotation?
    @Published var annotationError: String?
    @Published private(set) var liveSelection: ReadingChatContext?
    private var selectedWebText = ""
    private var selectedWebLocator: String?
    private var selectedWebChapter: String?
    private var selectedWebPreceding: String?
    private var selectedWebFollowing: String?
    private var selectedWebProgress: Double?
    private var selectionTooLong = false
    private var renderedPDFAnnotations: [(PDFPage, PDFAnnotation)] = []
    private var renderedPDFPages: Set<Int> = []
    private var renderedPDFValues: [BookAnnotation] = []
    @Published private(set) var reloadID = UUID()
    let bookID: UUID
    let library: LibraryStore
    let initialLocator: String?
    weak var webView: WKWebView?
    weak var pdfView: PDFView?
    var preferences: ReaderPreferences?
    var spokenHighlightLocator: String?
    var spokenHighlightView: ObjectIdentifier?
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
        selectedWebPreceding = nil; selectedWebFollowing = nil; selectedWebProgress = nil
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
        var preceding: String?, following: String?
        if let pdfView {
            if let selection = pdfView.currentSelection?.string, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = selection; source = "selection"
                location = pdfChatLocator(pdfView.currentSelection) ?? location
                let neighbors = pdfChatNeighbors(pdfView.currentSelection)
                preceding = neighbors.before; following = neighbors.after
            } else { text = pdfView.currentPage?.string ?? "" }
        } else if let webView {
            let result = try await webView.evaluateJavaScript("window.Leaf.chatContext()") as? [String: String]
            text = result?["text"] ?? ""; source = result?["source"] ?? "page"
            if let selectedLocator = result?["locator"], !selectedLocator.isEmpty { location = selectedLocator }
            if let selectedChapter = result?["label"], !selectedChapter.isEmpty { chapter = selectedChapter }
            preceding = result?["precedingText"]; following = result?["followingText"]
        }
        return ReadingChatContext(title: title, author: author, chapter: chapter, text: text,
                                  source: source, locator: location, precedingText: preceding, followingText: following, progress: fraction).bounded()
    }
    func recallBookContext(term: String, context: ReadingChatContext) async throws -> ReadingBookRecall? {
        try Task.checkCancellation()
        guard isReady, !isLocked, error == nil else { return nil }
        let epoch = reloadID
        if let web = webView {
            let id = UUID().uuidString
            return try await withTaskCancellationHandler(operation: {
                let value = try await web.callAsyncJavaScript("return await window.Leaf.recallBook({term,locator,id,selection});",
                    arguments: ["term": term, "locator": context.locator, "id": id, "selection": context.source == "selection"], in: nil, contentWorld: .page)
                try Task.checkCancellation(); guard epoch == reloadID, webView === web else { throw CancellationError() }
                guard let value, JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try JSONDecoder().decode(ReadingBookRecall.self, from: data).bounded()
            }, onCancel: { [weak web] in
                Task { @MainActor in
                    _ = try? await web?.callAsyncJavaScript("window.Leaf.cancelRecall({id});", arguments: ["id": id], in: nil, contentWorld: .page)
                }
            })
        }
        guard let view = pdfView, let doc = view.document else { return nil }
        let cursor = PDFLocator.cursor(context.locator)
        let boundaryPage = cursor?.page ?? view.currentPage.map(doc.index(for:)) ?? 0
        let total = min(doc.pageCount, boundaryPage + 1), deadline = Date().addingTimeInterval(8)
        var excerpts: [(page: Int, offset: Int, text: String)] = [], scanned = 0, characters = 0
        var partial = false, visited = Set<Int>()
        let indices = Array(0..<min(total, 32)) + Array((max(0, total - 96)..<total).reversed()) + Array(0..<total)
        for index in indices where visited.insert(index).inserted {
            try Task.checkCancellation(); guard epoch == reloadID else { throw CancellationError() }
            if Date() >= deadline || scanned >= 512 || characters >= 4000000 { break }
            let text = autoreleasepool { () -> NSString in
                let value = (doc.page(at: index)?.string ?? "") as NSString
                let cutoff = index == boundaryPage && context.locator.split(separator: ":").count > 2 ? cursor?.offset ?? value.length : value.length
                if cutoff > 250000 { partial = true }
                return value.substring(to: min(250000, min(max(0, cutoff), value.length))) as NSString
            }
            characters += text.length
            var range = NSRange(location: 0, length: text.length), matches = 0
            while range.length > 0, matches < 200 {
                let found = text.range(of: term, options: [.caseInsensitive], range: range)
                if found.location == NSNotFound { break }; matches += 1
                let start = max(0, found.location - 170), length = min(500, text.length - start)
                if !excerpts.contains(where: { $0.page == index && abs($0.offset - found.location) < 180 }) {
                    excerpts.append((index, found.location, text.substring(with: NSRange(location: start, length: length))))
                    excerpts.sort { $0.page == $1.page ? $0.offset < $1.offset : $0.page < $1.page }
                    if excerpts.count > 6 { excerpts.remove(at: 1) }
                }
                let next = NSMaxRange(found); range = NSRange(location: next, length: text.length - next)
            }
            if matches >= 200 { partial = true }
            scanned += 1; await Task.yield()
        }
        return ReadingBookRecall(term: term, excerpts: excerpts.map { ReadingBookExcerpt(chapter: "Page \($0.page + 1)", text: $0.text) }, scannedSections: scanned, totalSections: total, complete: scanned == total && !partial).bounded()
    }
    func refreshSelectedWebContext() async {
        guard isReady, let view = webView else { return }
        let epoch = reloadID
        guard let value = try? await view.evaluateJavaScript("window.Leaf.chatContext()") as? [String: String],
              !Task.isCancelled, webView === view, reloadID == epoch, isReady else { return }
        let text = value["source"] == "selection" ? value["text"] ?? "" : ""
        receive(["type": "selection", "text": text, "locator": value["locator"] ?? "", "label": value["label"] ?? "",
                 "precedingText": value["precedingText"] ?? "", "followingText": value["followingText"] ?? "",
                 "tooLong": text.utf16.count > 12000])
    }
    func selectedReadingContext() -> ReadingChatContext? {
        let text = pdfView?.currentSelection?.string ?? selectedWebText
        guard isReady, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let neighbors = pdfView == nil ? (before: selectedWebPreceding, after: selectedWebFollowing) : pdfChatNeighbors(pdfView?.currentSelection)
        return ReadingChatContext(title: book?.title ?? "", author: book?.author ?? "", chapter: pdfView != nil ? chapterTitle : selectedWebChapter ?? chapterTitle,
                                  text: text, source: "selection", locator: pdfView != nil ? pdfChatLocator(pdfView?.currentSelection) ?? locator : selectedWebLocator ?? locator,
                                  precedingText: neighbors.before, followingText: neighbors.after,
                                  progress: pdfView != nil ? fraction : selectedWebProgress ?? fraction).bounded()
    }
    private func pdfChatLocator(_ selection: PDFSelection?) -> String? {
        guard let selection, let page = selection.pages.first, let document = pdfView?.document,
              selection.numberOfTextRanges(on: page) > 0 else { return nil }
        let range = selection.range(at: 0, on: page)
        guard range.location != NSNotFound else { return nil }
        return PDFLocator.position(page: document.index(for: page), offset: range.location)
    }
    private func pdfChatNeighbors(_ selection: PDFSelection?) -> (before: String?, after: String?) {
        guard let selection, let first = selection.pages.first, let last = selection.pages.last,
              selection.numberOfTextRanges(on: first) > 0, selection.numberOfTextRanges(on: last) > 0 else { return (nil, nil) }
        let firstRange = selection.range(at: 0, on: first)
        let lastRange = selection.range(at: selection.numberOfTextRanges(on: last) - 1, on: last)
        let firstText = (first.string ?? "") as NSString
        let lastText = first === last ? firstText : (last.string ?? "") as NSString
        guard firstRange.location != NSNotFound, firstRange.location <= firstText.length,
              lastRange.location != NSNotFound, NSMaxRange(lastRange) <= lastText.length else { return (nil, nil) }
        let before = firstText.substring(with: NSRange(location: max(0, firstRange.location - 2400), length: min(2400, firstRange.location)))
        // A PDF page is the context boundary; do not load the next page.
        let after = lastText.substring(with: NSRange(location: NSMaxRange(lastRange), length: min(1200, lastText.length - NSMaxRange(lastRange))))
        return (before, after)
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
    func selectedAnnotationSelection() -> BookAnnotationSelection? {
        guard isReady, !isLocked, error == nil else { return nil }
        if let pdfView, let document = pdfView.document, let selected = pdfView.currentSelection, let text = selected.string {
            let ranges = selected.annotationRanges(in: document)
            guard let first = ranges.first else { return nil }
            let selection = BookAnnotationSelection(text: text, locator: PDFLocator.page(first.page), chapter: "Page \(first.page + 1)", fraction: document.pageCount > 1 ? Double(first.page) / Double(document.pageCount - 1) : 0, pdfRanges: ranges)
            return selection.annotation().valid ? selection : nil
        }
        guard !selectionTooLong, let selectedWebLocator else { return nil }
        let selection = BookAnnotationSelection(text: selectedWebText, locator: selectedWebLocator, chapter: selectedWebChapter ?? chapterTitle, fraction: fraction)
        return selection.annotation().valid ? selection : nil
    }
    func annotateSelection(_ intent: ReaderAnnotationIntent, selection: BookAnnotationSelection) {
        let existing = book?.annotations.first { $0.matches(selection) }
        let draft = existing ?? selection.annotation()
        guard draft.valid else { annotationError = BookAnnotationError.selection.localizedDescription; return }
        if intent == .note { annotationDraft = draft }
        else if existing == nil {
            do { try library.saveAnnotation(draft, bookID: bookID); synchronizeAnnotations() }
            catch { annotationError = error.localizedDescription; return }
        }
        hideControls()
        clearNativeSelection()
    }
    func editAnnotation(_ id: UUID) {
        guard let annotation = book?.annotations.first(where: { $0.id == id }) else { return }
        if annotationDraft?.id != id { annotationDraft = annotation }
    }
    func saveAnnotation(_ annotation: BookAnnotation) throws {
        try library.saveAnnotation(annotation, bookID: bookID)
        synchronizeAnnotations()
    }
    func removeAnnotation(_ id: UUID) throws {
        try library.removeAnnotation(id, bookID: bookID)
        synchronizeAnnotations()
    }
    func synchronizeAnnotations() {
        guard isReady else { return }
        if let pdfView, let document = pdfView.document {
            let proposed = pdfView.currentPage.map { document.index(for: $0) } ?? 0
            let current = (0..<document.pageCount).contains(proposed) ? proposed : 0
            let visible = pdfView.visiblePages.map { document.index(for: $0) }.filter { (0..<document.pageCount).contains($0) }
            let pages = Set(max(0, current - 1)...min(max(0, document.pageCount - 1), current + 1)).union(visible)
            let values = book?.annotations ?? []
            guard pages != renderedPDFPages || values != renderedPDFValues else { return }
            renderedPDFPages = pages; renderedPDFValues = values
            for (page, annotation) in renderedPDFAnnotations { page.removeAnnotation(annotation) }
            renderedPDFAnnotations = []
            for saved in values where saved.valid {
                // Avoid materializing annotated pages throughout a large PDF.
                for range in saved.pdfRanges where pages.contains(range.page) {
                    guard let page = document.page(at: range.page), range.location <= (page.string as NSString?)?.length ?? 0,
                          range.length <= ((page.string as NSString?)?.length ?? 0) - range.location,
                          let selection = page.selection(for: NSRange(location: range.location, length: range.length)) else { continue }
                    for line in selection.selectionsByLine() {
                        let bounds = line.bounds(for: page)
                        guard !bounds.isEmpty, !bounds.isInfinite else { continue }
                        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                        annotation.color = UIColor(saved.color.color).withAlphaComponent(0.4)
                        annotation.userName = "Leaf:\(saved.id.uuidString)"
                        annotation.contents = saved.note
                        page.addAnnotation(annotation); renderedPDFAnnotations.append((page, annotation))
                    }
                }
            }
        } else { evaluate("setAnnotations", ["items": (book?.annotations ?? []).filter { $0.valid && $0.pdfRanges.isEmpty }.map(\.webPayload)]) }
    }
    func openPDFAnnotation(_ annotation: PDFAnnotation) {
        guard let name = annotation.userName, name.hasPrefix("Leaf:"), let id = UUID(uuidString: String(name.dropFirst(5))) else { return }
        editAnnotation(id)
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
                          "locator": locator, "preferences": preferences.payload,
                          "annotations": book.annotations.filter { $0.valid && $0.pdfRanges.isEmpty }.map(\.webPayload)])
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
            selectionTooLong = message["tooLong"] as? Bool ?? false
            selectedWebLocator = (message["locator"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(2000)) }
            selectedWebChapter = (message["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
            selectedWebPreceding = (message["precedingText"] as? String).map { String($0.suffix(2400)) }
            selectedWebFollowing = (message["followingText"] as? String).map { String($0.prefix(1200)) }
            selectedWebProgress = fraction
            #if DEBUG
            readerSelectionMenuTrace("selection", source: webView, context: !selectedWebText.isEmpty)
            #endif
            updateLiveSelection()
        case "toggleControls": toggleControls()
        case "readingActivity": hideControls()
        case "bridgeReady": openWebBook()
        case "ready": isReady = true; error = nil; synchronizeAnnotations()
        case "annotationSelected": if let value = message["id"] as? String, let id = UUID(uuidString: value) { editAnnotation(id) }
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
                return BookSearchResult(label: "Page \(index + 1)", excerpt: selection.selectionsByLine().compactMap(\.string).joined(separator: " "), locator: PDFLocator.page(index))
            }
            isSearching = false
        } else { evaluate("search", ["query": text, "generation": searchGeneration]) }
    }
    func configurePDF(_ view: PDFView, url: URL) {
        if let pdfSelectionObserver { NotificationCenter.default.removeObserver(pdfSelectionObserver) }
        for (page, annotation) in renderedPDFAnnotations { page.removeAnnotation(annotation) }
        renderedPDFAnnotations = []; renderedPDFPages = []; renderedPDFValues = []
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
        chapters = (0..<doc.pageCount).map { Chapter(label: "Page \($0 + 1)", href: PDFLocator.page($0)) }
        if !locator.isEmpty { navigatePDF(locator) }
        else if let first = doc.page(at: 0) { view.go(to: first) }
        isReady = true
        if let cover = doc.page(at: 0)?.thumbnail(of: CGSize(width: 300, height: 440), for: .cropBox).pngData() {
            library.setMetadata(bookID, title: nil, author: nil, cover: cover)
        }
        pdfPageChanged()
        synchronizeAnnotations()
    }
    private func navigatePDF(_ target: String) {
        guard let index = PDFLocator.pageIndex(target), let page = pdfView?.document?.page(at: index) else { return }
        pdfView?.go(to: page)
    }
    func pdfPageChanged() {
        guard isReady, let view = pdfView, let doc = view.document, let page = view.currentPage else { return }
        let index = doc.index(for: page)
        guard index != NSNotFound else { return }
        if locator != PDFLocator.page(index) { hideControls() }
        locator = PDFLocator.page(index); fraction = doc.pageCount > 1 ? Double(index) / Double(doc.pageCount - 1) : 0
        chapterTitle = "Page \(index + 1) of \(doc.pageCount)"
        library.setPosition(bookID, locator: locator, fraction: fraction)
        synchronizeAnnotations()
    }
}
