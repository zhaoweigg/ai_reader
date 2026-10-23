import XCTest
import PDFKit
import UIKit
@testable import LeafReader

@MainActor final class AnnotationTests: XCTestCase {
    private func library(format: BookFormat = .txt) throws -> (LibraryStore, Book, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = try LibraryDisk(root: root)
        let book = Book(id: UUID(), title: "A book", author: "Author", fileName: "book.\(format.rawValue)", format: format, fingerprint: "stable-fingerprint")
        try disk.save([book])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (LibraryStore(root: root, seedSamples: false), book, root)
    }
    private var annotation: BookAnnotation {
        BookAnnotation(text: "Exact selected passage 中文", locator: "epubcfi(/6/2!/4,/2/1:3,/2/1:12)", chapter: "Chapter 1", fraction: 0.2)
    }
    func testLegacyLibraryWithoutAnnotationsLoadsAndPreservesAllSavedState() throws {
        var book = Book(id: UUID(), title: "Legacy", author: "A", fileName: "book.epub", format: .epub, fingerprint: "original")
        book.locator = "epubcfi(/6/4!/4/2)"; book.progress = 0.42; book.isFavorite = true
        book.bookmarks = [BookBookmark(label: "Saved passage", locator: book.locator, fraction: 0.42)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        object.removeValue(forKey: "annotations")
        let restored = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored, book); XCTAssertTrue(restored.annotations.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(restored)), book)
    }
    func testHighlightNoteColorEditsAndDeletionSurviveRelaunchWithoutChangingOtherBooks() throws {
        let (store, book, root) = try library()
        let second = Book(id: UUID(), title: "Other", author: "", fileName: "other.txt", format: .txt, fingerprint: "another")
        try store.disk!.save([book, second])
        let first = LibraryStore(root: root, seedSamples: false)
        first.setPosition(book.id, locator: "saved-position", fraction: 0.6)
        first.toggleBookmark(book.id, locator: "bookmark", fraction: 0.4, label: "Bookmark")
        var saved = annotation
        saved.note = "My persistent note\n第二行"; saved.color = .blue
        try first.saveAnnotation(saved, bookID: book.id)
        var restored = LibraryStore(root: root, seedSamples: false)
        XCTAssertEqual(restored.book(book.id)?.annotations, [saved])
        XCTAssertEqual(restored.book(book.id)?.locator, "saved-position")
        XCTAssertEqual(restored.book(book.id)?.bookmarks.count, 1)
        XCTAssertEqual(restored.book(second.id), second)
        XCTAssertEqual(restored.book(book.id)?.fingerprint, "stable-fingerprint")
        saved.note = ""; saved.color = .pink
        try restored.saveAnnotation(saved, bookID: book.id)
        restored = LibraryStore(root: root, seedSamples: false)
        XCTAssertEqual(restored.book(book.id)?.annotations, [saved]); XCTAssertFalse(saved.hasNote)
        try restored.removeAnnotation(saved.id, bookID: book.id)
        XCTAssertTrue(LibraryStore(root: root, seedSamples: false).book(book.id)?.annotations.isEmpty == true)
        XCTAssertEqual(restored.book(book.id)?.bookmarks.count, 1)
    }
    func testRepeatedSameAnchorUpdatesOneHighlightAndKeepsItsIdentity() throws {
        let (store, book, root) = try library()
        let first = annotation
        try store.saveAnnotation(first, bookID: book.id)
        var second = annotation; second.note = "A note on the existing highlight"; second.color = .green
        try store.saveAnnotation(second, bookID: book.id)
        let saved = try XCTUnwrap(LibraryStore(root: root, seedSamples: false).book(book.id)?.annotations.first)
        XCTAssertEqual(store.book(book.id)?.annotations.count, 1)
        XCTAssertEqual(saved.id, first.id); XCTAssertEqual(saved.createdAt, first.createdAt)
        XCTAssertEqual(saved.note, second.note); XCTAssertEqual(saved.color, .green)
    }
    func testFailedAnnotationWritesKeepPublishedAndPersistedPassages() throws {
        let (store, book, _) = try library()
        let saved = annotation
        try store.saveAnnotation(saved, bookID: book.id)
        let disk = try XCTUnwrap(store.disk), backup = disk.root.appendingPathComponent("backup.json")
        let original = try Data(contentsOf: disk.manifest)
        try FileManager.default.moveItem(at: disk.manifest, to: backup)
        try FileManager.default.createDirectory(at: disk.manifest, withIntermediateDirectories: false)
        var edit = saved; edit.note = "This write must fail"
        XCTAssertThrowsError(try store.saveAnnotation(edit, bookID: book.id))
        XCTAssertThrowsError(try store.removeAnnotation(saved.id, bookID: book.id))
        XCTAssertEqual(store.book(book.id)?.annotations, [saved])
        try FileManager.default.removeItem(at: disk.manifest)
        try FileManager.default.moveItem(at: backup, to: disk.manifest)
        XCTAssertEqual(try Data(contentsOf: disk.manifest), original)
        XCTAssertEqual(LibraryStore(root: disk.root, seedSamples: false).book(book.id)?.annotations, [saved])
    }
    func testInvalidAnchorsOversizedNotesAndMismatchedFormatsAreRejectedAtomically() throws {
        let (store, book, _) = try library()
        var bad = annotation; bad.note = String(repeating: "x", count: 20_001)
        XCTAssertThrowsError(try store.saveAnnotation(bad, bookID: book.id))
        bad = annotation; bad.text = String(repeating: "字", count: 12_001)
        XCTAssertThrowsError(try store.saveAnnotation(bad, bookID: book.id))
        bad = annotation; bad.locator = "https://not-a-book-anchor.example"
        XCTAssertThrowsError(try store.saveAnnotation(bad, bookID: book.id))
        bad = annotation; bad.locator = "pdf:0"; bad.pdfRanges = [PDFAnnotationRange(page: 0, location: Int.max, length: 4)]
        XCTAssertThrowsError(try store.saveAnnotation(bad, bookID: book.id))
        bad.pdfRanges = [PDFAnnotationRange(page: 0, location: 3, length: 4)]
        XCTAssertThrowsError(try store.saveAnnotation(bad, bookID: book.id))
        XCTAssertTrue(store.book(book.id)?.annotations.isEmpty == true)
        let (pdfStore, pdfBook, _) = try library(format: .pdf)
        XCTAssertThrowsError(try pdfStore.saveAnnotation(annotation, bookID: pdfBook.id))
    }
    func testNoteDraftIsNotSavedUntilCommitAndRepeatedHighlightPreservesNote() throws {
        let (store, book, _) = try library()
        let model = ReaderModel(bookID: book.id, library: store, initialLocator: nil)
        let selection = BookAnnotationSelection(text: annotation.text, locator: annotation.locator, chapter: annotation.chapter, fraction: 0.2)
        model.annotateSelection(.note, selection: selection)
        XCTAssertNotNil(model.annotationDraft); XCTAssertTrue(store.book(book.id)?.annotations.isEmpty == true)
        model.annotationDraft = nil // Cancel leaves no highlight or empty note behind.
        model.annotateSelection(.highlight, selection: selection)
        var saved = try XCTUnwrap(store.book(book.id)?.annotations.first)
        saved.note = "Keep this note"; saved.color = .blue
        try model.saveAnnotation(saved)
        model.annotateSelection(.highlight, selection: selection)
        XCTAssertEqual(store.book(book.id)?.annotations, [saved])
    }
    func testPDFExactTextRangesRenderPersistAndDeleteWithoutWritingToTheBookFile() throws {
        let (store, book, _) = try library(format: .pdf)
        let source = try XCTUnwrap(Bundle.main.url(forResource: "Notes from the Coast.pdf", withExtension: nil, subdirectory: "Samples"))
        let original = try Data(contentsOf: source)
        let model = ReaderModel(bookID: book.id, library: store, initialLocator: nil), view = ReaderPDFView()
        model.configurePDF(view, url: source)
        let originalCover = try Data(contentsOf: XCTUnwrap(store.coverURL(try XCTUnwrap(store.book(book.id)))))
        let page = try XCTUnwrap(view.document?.page(at: 0))
        view.currentSelection = page.selection(for: NSRange(location: 10, length: 30))
        let selection = try XCTUnwrap(model.selectedAnnotationSelection())
        XCTAssertEqual(selection.pdfRanges, [PDFAnnotationRange(page: 0, location: 10, length: 30)])
        model.annotateSelection(.highlight, selection: selection)
        let saved = try XCTUnwrap(store.book(book.id)?.annotations.first)
        XCTAssertFalse(page.annotations.isEmpty)
        XCTAssertTrue(page.annotations.allSatisfy { $0.userName == "Leaf:\(saved.id.uuidString)" })
        let reopened = ReaderModel(bookID: book.id, library: LibraryStore(root: store.disk!.root, seedSamples: false), initialLocator: nil)
        let reopenedView = ReaderPDFView(); reopened.configurePDF(reopenedView, url: source)
        XCTAssertFalse(reopenedView.document?.page(at: 0)?.annotations.isEmpty ?? true)
        let reopenedBook = try XCTUnwrap(reopened.book)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reopened.library.coverURL(reopenedBook))), originalCover, "Saved highlights must not become part of the library cover")
        try model.removeAnnotation(saved.id)
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testPDFHighlightWindowTracksVisiblePagesAndZoomWithoutAnnotatingAllPages() async throws {
        let (store, book, root) = try library(format: .pdf)
        let source = root.appendingPathComponent("pages.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500))
        try renderer.pdfData { context in
            for number in 0..<8 {
                context.beginPage()
                ("Page \(number) selected passage for a saved note." as NSString).draw(in: CGRect(x: 20, y: 30, width: 260, height: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }.write(to: source)
        for number in 0..<8 {
            let saved = BookAnnotation(text: "selected passage", locator: "pdf:\(number)", chapter: "Page \(number + 1)", fraction: Double(number) / 7,
                pdfRanges: [PDFAnnotationRange(page: number, location: 7, length: 16)])
            try store.saveAnnotation(saved, bookID: book.id)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 500))
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.autoScales = true
        controller.view.addSubview(view); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let model = ReaderModel(bookID: book.id, library: store, initialLocator: nil)
        model.configurePDF(view, url: source)
        let coordinator = PDFBookSurface.Coordinator(model); coordinator.observe(view)
        let document = try XCTUnwrap(view.document)
        XCTAssertTrue(try XCTUnwrap(document.page(at: 7)).annotations.isEmpty)
        view.go(to: try XCTUnwrap(document.page(at: 6)))
        let deadline = Date().addingTimeInterval(5)
        while view.currentPage.map({ document.index(for: $0) }) != 6 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        model.pdfPageChanged()
        XCTAssertEqual(view.currentPage.map { document.index(for: $0) }, 6)
        XCTAssertFalse(try XCTUnwrap(document.page(at: 6)).annotations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(document.page(at: 0)).annotations.isEmpty)
        view.scaleFactor = 0.25
        try await Task.sleep(for: .milliseconds(200))
        model.synchronizeAnnotations()
        let visible = view.visiblePages
        XCTAssertGreaterThan(visible.count, 1)
        XCTAssertTrue(visible.allSatisfy { !$0.annotations.isEmpty })
        withExtendedLifetime(coordinator) { }
    }
}
