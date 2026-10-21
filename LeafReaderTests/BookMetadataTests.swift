import XCTest
import UIKit
@testable import LeafReader

@MainActor
final class BookMetadataTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }
    private func assertCover(_ store: LibraryStore, book: Book, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(store.coverURL(book), file: file, line: line)
        XCTAssertNotNil(UIImage(contentsOfFile: url.path), file: file, line: line)
        XCTAssertNil(book.lastOpenedAt, file: file, line: line)
        XCTAssertEqual(book.progress, 0, file: file, line: line)
        XCTAssertEqual(book.locator, "", file: file, line: line)
        XCTAssertEqual(book.metadataVersion, BookMetadataLoader.version, file: file, line: line)
    }

    func testEPUBImportLoadsCoverAndAuthorBeforeFirstOpen() async throws {
        let root = try directory()
        let store = LibraryStore(root: root, seedSamples: false)
        await store.importBooks([try fixture("Covered.epub")])
        let book = try XCTUnwrap(store.books.first)
        XCTAssertEqual(book.title, "书封面 · Imported")
        XCTAssertEqual(book.author, "林海")
        try assertCover(store, book: book)
        let saved = try XCTUnwrap(LibraryDisk(root: root).load()?.first)
        XCTAssertEqual(saved, book)
    }

    func testEPUB2CoverDeclarationWorksBeforeFirstOpen() async throws {
        let store = LibraryStore(root: try directory(), seedSamples: false)
        await store.importBooks([try fixture("LegacyCover.epub")])
        try assertCover(store, book: XCTUnwrap(store.books.first))
    }

    func testXHTMLCoverPageResolvesItsEmbeddedImage() async throws {
        let store = LibraryStore(root: try directory(), seedSamples: false)
        await store.importBooks([try fixture("CoverPage.epub")])
        try assertCover(store, book: XCTUnwrap(store.books.first))
    }

    func testSVGCoverIsRasterizedAndDownsampled() async throws {
        let store = LibraryStore(root: try directory(), seedSamples: false)
        await store.importBooks([try fixture("VectorCover.epub")])
        let book = try XCTUnwrap(store.books.first)
        try assertCover(store, book: book)
        let url = try XCTUnwrap(store.coverURL(book))
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(image.size, CGSize(width: 400, height: 600))
        XCTAssertEqual(Array(try Data(contentsOf: url).prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testPDFImportCreatesCoverWithoutOpeningTheReader() async throws {
        let store = LibraryStore(root: try directory(), seedSamples: false)
        let source = try XCTUnwrap(Bundle.main.url(forResource: "Notes from the Coast.pdf", withExtension: nil, subdirectory: "Samples"))
        await store.importBooks([source])
        try assertCover(store, book: XCTUnwrap(store.books.first))
    }

    func testExistingBooksBackfillWithoutChangingSavedReadingState() async throws {
        let disk = try LibraryDisk(root: directory())
        var book = try disk.prepareImport(fixture("Covered.epub"), existing: [])
        book.progress = 0.37
        book.locator = "epubcfi(/6/2!/4/2)"
        book.lastOpenedAt = Date(timeIntervalSince1970: 1_700_000_000)
        book.isFavorite = true
        book.bookmarks = [BookBookmark(label: "Keep this passage", locator: book.locator, fraction: book.progress)]
        try disk.save([book])
        let store = LibraryStore(root: disk.root, seedSamples: false)
        await store.refreshMissingMetadata()
        let updated = try XCTUnwrap(store.books.first)
        XCTAssertNotNil(updated.coverFileName)
        XCTAssertEqual(updated.title, "书封面 · Imported")
        XCTAssertEqual(updated.id, book.id)
        XCTAssertEqual(updated.progress, book.progress)
        XCTAssertEqual(updated.locator, book.locator)
        XCTAssertEqual(updated.lastOpenedAt, book.lastOpenedAt)
        XCTAssertEqual(updated.bookmarks, book.bookmarks)
        XCTAssertEqual(updated.isFavorite, book.isFavorite)
        XCTAssertEqual(try disk.load()?.first, updated)
    }

    func testBooksWithoutCoversAreNotRepeatedlyParsed() async throws {
        let root = try directory()
        var calls = 0
        let loader: (Book, URL) async throws -> BookMetadata = { _, _ in calls += 1; return BookMetadata() }
        let store = LibraryStore(root: root, seedSamples: false, metadataLoader: loader)
        await store.importBooks([try fixture("Covered.epub")])
        await store.refreshMissingMetadata()
        let restored = LibraryStore(root: root, seedSamples: false, metadataLoader: loader)
        await restored.refreshMissingMetadata()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(store.books.first?.coverFileName)
    }

    func testMetadataFailureKeepsTheBookAndCanBeRetried() async throws {
        var calls = 0
        let store = LibraryStore(root: try directory(), seedSamples: false, metadataLoader: { _, _ in
            calls += 1
            if calls == 1 { throw URLError(.cannotDecodeContentData) }
            return BookMetadata(title: "Recovered title")
        })
        await store.importBooks([try fixture("Covered.epub")])
        let imported = try XCTUnwrap(store.books.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.fileURL(imported)).path))
        XCTAssertNil(imported.metadataVersion)
        XCTAssertNil(store.notice)
        await store.refreshMissingMetadata()
        XCTAssertEqual(store.books.first?.title, "Recovered title")
        XCTAssertEqual(calls, 2)
    }

    func testRemovingABookDiscardsAnInFlightMetadataResult() async throws {
        let root = try directory()
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        var release: CheckedContinuation<Void, Never>?
        let store = LibraryStore(root: root, seedSamples: false, metadataLoader: { _, _ in
            await withCheckedContinuation { release = $0 }
            return BookMetadata(title: "Late result", cover: cover)
        })
        let source = try fixture("Covered.epub")
        let importing = Task { await store.importBooks([source]) }
        let deadline = Date().addingTimeInterval(5)
        while release == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let completion = try XCTUnwrap(release)
        store.remove(try XCTUnwrap(store.books.first).id)
        completion.resume()
        await importing.value
        XCTAssertTrue(store.books.isEmpty)
        let disk = try LibraryDisk(root: root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.coversDirectory.path).count, 0)
        XCTAssertEqual(try disk.load()?.count, 0)
    }
}
