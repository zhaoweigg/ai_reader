import XCTest
@testable import LeafReader

final class RetiredVoicePackCleanupTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testCleanupRemovesOnlyTheRetiredPackAndIsSafeToRepeat() throws {
        let root = try directory(), pack = root.appendingPathComponent("KokoroVoices")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: pack.appendingPathComponent("model.onnx"))
        let bookmark = root.appendingPathComponent("listening.json"), book = root.appendingPathComponent("book.epub")
        try Data("saved cursor".utf8).write(to: bookmark); try Data("book contents".utf8).write(to: book)
        try RetiredVoicePackCleanup.removeDownloadedPack(applicationSupport: root)
        try RetiredVoicePackCleanup.removeDownloadedPack(applicationSupport: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.path))
        XCTAssertEqual(try String(contentsOf: bookmark), "saved cursor")
        XCTAssertEqual(try String(contentsOf: book), "book contents")
    }
    func testCleanupRemovesASymlinkWithoutFollowingIt() throws {
        let root = try directory(), external = try directory(), file = external.appendingPathComponent("keep")
        try Data([1]).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("KokoroVoices"), withDestinationURL: external)
        try RetiredVoicePackCleanup.removeDownloadedPack(applicationSupport: root)
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
    }
    func testRetiredEngineChoicesAreExcludedFromCloudSettings() {
        XCTAssertTrue(SyncedSettings.keys.contains("audio.voice"))
        XCTAssertTrue(SyncedSettings.keys.contains("audio.speed.system"))
        for key in ["audio.engine", "audio.kokoroVoice", "audio.speed.kokoro"] { XCTAssertFalse(SyncedSettings.keys.contains(key)) }
    }
}
