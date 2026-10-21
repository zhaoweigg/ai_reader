import XCTest
@testable import LeafReader

final class LibraryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testFormatDetectionIncludesAliasesAndRejectsUnknownFormats() {
        for (name, expected) in [("book.EPUB", BookFormat.epub), ("book.fb2.zip", .fbz), ("book.MOBI", .mobi), ("book.azw3", .azw3), ("notes.markdown", .md), ("page.htm", .html)] {
            XCTAssertEqual(BookFormat.detect(URL(fileURLWithPath: name)), expected)
        }
        for name in ["book.kfx", "book.acsm", "book.cbr", "book.zip", "book.exe"] { XCTAssertNil(BookFormat.detect(URL(fileURLWithPath: name))) }
    }
    func testImportIsACopyAndDuplicatesUseContentHash() throws {
        let root = try temporaryDirectory()
        let disk = try LibraryDisk(root: root.appendingPathComponent("library"))
        let original = root.appendingPathComponent("Original.txt")
        try Data("A book worth keeping.".utf8).write(to: original)
        let book = try disk.prepareImport(original, existing: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: disk.fileURL(book)), try Data(contentsOf: original))
        let renamed = root.appendingPathComponent("Renamed.txt")
        try FileManager.default.copyItem(at: original, to: renamed)
        XCTAssertThrowsError(try disk.prepareImport(renamed, existing: [book.fingerprint])) { XCTAssertEqual($0.localizedDescription, LibraryError.duplicate.localizedDescription) }
        try disk.removeFiles(book)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disk.fileURL(book).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testEmptyAndInvalidPDFAreRejectedWithoutLeavingFiles() throws {
        let root = try temporaryDirectory()
        let disk = try LibraryDisk(root: root.appendingPathComponent("library"))
        let empty = root.appendingPathComponent("Empty.epub")
        try Data().write(to: empty)
        XCTAssertThrowsError(try disk.prepareImport(empty, existing: []))
        let invalid = root.appendingPathComponent("Fake.pdf")
        try Data("This is not a PDF".utf8).write(to: invalid)
        XCTAssertThrowsError(try disk.prepareImport(invalid, existing: []))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: disk.booksDirectory.path).count, 0)
    }
    @MainActor func testReadingPositionAndBookmarksSurviveRelaunch() throws {
        let root = try temporaryDirectory()
        let storage = root.appendingPathComponent("library")
        let original = root.appendingPathComponent("Reading.txt")
        try Data("A long afternoon in the library.".utf8).write(to: original)
        let disk = try LibraryDisk(root: storage)
        let imported = try disk.prepareImport(original, existing: [])
        try disk.save([imported])
        let first = LibraryStore(root: storage, seedSamples: false)
        first.setPosition(imported.id, locator: "epubcfi(/6/2!/4/2)", fraction: 0.42)
        first.toggleBookmark(imported.id, locator: "epubcfi(/6/2!/4/2)", fraction: 0.42, label: "A long afternoon")
        first.toggleFavorite(imported.id)
        first.flush()
        let restored = LibraryStore(root: storage, seedSamples: false)
        XCTAssertEqual(restored.books.first?.progress, 0.42)
        XCTAssertEqual(restored.books.first?.locator, "epubcfi(/6/2!/4/2)")
        XCTAssertEqual(restored.books.first?.bookmarks.first?.label, "A long afternoon")
        XCTAssertEqual(restored.books.first?.isFavorite, true)
        restored.toggleBookmark(imported.id, locator: "epubcfi(/6/2!/4/2)", fraction: 0.42, label: "A long afternoon")
        XCTAssertEqual(restored.books.first?.bookmarks.count, 0)
    }
    @MainActor func testCorruptManifestIsPreserved() throws {
        let disk = try LibraryDisk(root: try temporaryDirectory())
        let original = Data("corrupt manifest".utf8)
        try original.write(to: disk.manifest)
        let library = LibraryStore(root: disk.root, seedSamples: true)
        XCTAssertNotNil(library.notice)
        library.flush()
        XCTAssertEqual(try Data(contentsOf: disk.manifest), original)
    }
}
