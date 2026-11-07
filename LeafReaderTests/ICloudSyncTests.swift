import XCTest
import SwiftUI
@testable import LeafReader

/// Two simulated devices share one folder standing in for iCloud Drive.
@MainActor
final class ICloudSyncTests: XCTestCase {
    @MainActor private struct Device {
        let library: LibraryStore
        let sync: ICloudSync
        let defaults: UserDefaults
        let root: URL
        func chats(_ conversation: String) throws -> ChatHistoryStore {
            try ChatHistoryStore(directory: root.appendingPathComponent("ChatHistory", isDirectory: true), conversation: conversation)
        }
    }
    private var cleanup: [URL] = []
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LeafSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cleanup.append(folder)
    }
    override func tearDown() async throws {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    private func device(keepBooks: Bool = true, automaticSync: Bool = false) throws -> Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafSyncDevice-\(UUID().uuidString)", isDirectory: true)
        cleanup.append(root)
        let library = LibraryStore(root: root, seedSamples: false, metadataLoader: { _, _ in BookMetadata(title: nil, author: nil, cover: nil) })
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LeafSyncTests.\(UUID().uuidString)"))
        defaults.set(keepBooks, forKey: ICloudSync.Keys.keepBooks)
        let sync = ICloudSync(library: library, defaults: defaults, stateDirectory: root.appendingPathComponent("SyncState"), folderOverride: folder)
        if !automaticSync { library.onSave = nil } // Most cases sync explicitly.
        return Device(library: library, sync: sync, defaults: defaults, root: root)
    }

    private func importBook(_ device: Device) async throws -> Book {
        let url = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: "Density.html", withExtension: nil, subdirectory: "Fixtures"))
        await device.library.importBooks([url])
        return try XCTUnwrap(device.library.books.last)
    }

    private func annotation(_ text: String, at fraction: Double) -> BookAnnotation {
        BookAnnotation(text: text, locator: "epubcfi(/6/2!/4/\(Int(fraction * 100)))", chapter: "One", fraction: fraction)
    }

    func testAutomaticSyncSettlesAndStillSendsLocalChanges() async throws {
        let phone = try device(automaticSync: true)
        defer { phone.sync.disconnect() }
        let book = try await importBook(phone)
        var starts = 0
        let observation = phone.sync.$status.sink { if $0 == .syncing { starts += 1 } }
        defer { observation.cancel() }
        await phone.sync.syncNow()
        XCTAssertEqual(phone.sync.status, .upToDate)
        XCTAssertEqual(starts, 1)
        // Observe beyond the real two-second save debounce. The production
        // callback stays connected, unlike the explicit two-device fixtures.
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertEqual(starts, 1, "A completed sync must not schedule itself again")

        phone.library.setPosition(book.id, locator: "epubcfi(/6/4!/4/8)", fraction: 0.61)
        let deadline = Date().addingTimeInterval(6)
        while (starts < 2 || phone.sync.status != .upToDate) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(starts, 2, "A real local edit must still sync automatically")
        let remote = folder.appendingPathComponent("Library/\(book.fingerprint).json")
        let record = try JSONDecoder().decode(SyncedBook.self, from: Data(contentsOf: remote))
        XCTAssertEqual(record.locator, "epubcfi(/6/4!/4/8)")
        XCTAssertEqual(record.progress, 0.61, accuracy: 0.0001)
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertEqual(starts, 2, "The automatic pass must settle too")
    }

    func testANewDeviceListsTheLibraryAndDownloadsABookWhenOpened() async throws {
        let phone = try device(), tablet = try device(keepBooks: false)
        let book = try await importBook(phone)
        phone.library.setPosition(book.id, locator: "epubcfi(/6/4!/4/2)", fraction: 0.42)
        phone.library.toggleFavorite(book.id)
        try phone.library.saveAnnotation(annotation("A quiet line", at: 0.3), bookID: book.id)
        phone.library.toggleBookmark(book.id, locator: "epubcfi(/6/4!/4/8)", fraction: 0.45, label: "Here")
        await phone.sync.syncNow()
        XCTAssertEqual(phone.sync.status, .upToDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Books/\(book.fingerprint).html").path), "The book file is uploaded once")

        await tablet.sync.syncNow()
        let synced = try XCTUnwrap(tablet.library.books.first { $0.fingerprint == book.fingerprint })
        XCTAssertFalse(tablet.library.isDownloaded(synced), "With books kept in iCloud, the file waits until the book is opened")
        XCTAssertEqual(synced.locator, "epubcfi(/6/4!/4/2)")
        XCTAssertEqual(synced.progress, 0.42, accuracy: 0.0001)
        XCTAssertTrue(synced.isFavorite)
        XCTAssertEqual(synced.annotations.map(\.text), ["A quiet line"])
        XCTAssertEqual(synced.bookmarks.map(\.label), ["Here"])
        try await tablet.sync.download(synced)
        XCTAssertTrue(tablet.library.isDownloaded(synced))
        let original = try XCTUnwrap(phone.library.fileURL(book)), copy = try XCTUnwrap(tablet.library.fileURL(synced))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: original))
    }

    func testTheNewestPositionWinsAndHighlightsFromBothDevicesMerge() async throws {
        let phone = try device(), tablet = try device()
        let book = try await importBook(phone)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        let tabletBook = try XCTUnwrap(tablet.library.books.first)
        XCTAssertTrue(tablet.library.isDownloaded(tabletBook), "Books kept on the device download during sync")

        phone.library.setPosition(book.id, locator: "epubcfi(/6/4!/4/2)", fraction: 0.2)
        try phone.library.saveAnnotation(annotation("From the phone", at: 0.2), bookID: book.id)
        try await Task.sleep(for: .milliseconds(20))
        tablet.library.setPosition(tabletBook.id, locator: "epubcfi(/6/8!/4/2)", fraction: 0.6)
        try tablet.library.saveAnnotation(annotation("From the tablet", at: 0.6), bookID: tabletBook.id)

        await phone.sync.syncNow(); await tablet.sync.syncNow(); await phone.sync.syncNow()
        for library in [phone.library, tablet.library] {
            let current = try XCTUnwrap(library.books.first)
            XCTAssertEqual(current.progress, 0.6, accuracy: 0.0001, "The later reading position wins")
            XCTAssertEqual(Set(current.annotations.map(\.text)), ["From the phone", "From the tablet"])
        }

        var edited = try XCTUnwrap(tablet.library.books.first?.annotations.first { $0.text == "From the phone" })
        edited.note = "Edited on the tablet"; edited.updatedAt = Date()
        try tablet.library.saveAnnotation(edited, bookID: tabletBook.id)
        await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(phone.library.books.first?.annotations.first { $0.id == edited.id }?.note, "Edited on the tablet")
    }

    func testDeletionsReachTheOtherDeviceAndRemovedBooksLeaveICloud() async throws {
        let phone = try device(), tablet = try device()
        let book = try await importBook(phone)
        let note = annotation("Soon gone", at: 0.5)
        try phone.library.saveAnnotation(note, bookID: book.id)
        phone.library.toggleBookmark(book.id, locator: "epubcfi(/6/4!/4/8)", fraction: 0.45, label: "Mark")
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(tablet.library.books.first?.annotations.count, 1)

        try phone.library.removeAnnotation(note.id, bookID: book.id)
        let mark = try XCTUnwrap(phone.library.books.first?.bookmarks.first)
        phone.library.removeBookmark(book.id, bookmarkID: mark.id)
        await phone.sync.syncNow(); await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(tablet.library.books.first?.annotations.count, 0, "A highlight deleted on one device is deleted everywhere")
        XCTAssertEqual(tablet.library.books.first?.bookmarks.count, 0)
        XCTAssertEqual(phone.library.books.first?.annotations.count, 0, "The deletion is not undone by the other device's copy")

        phone.library.remove(book.id)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertTrue(tablet.library.books.isEmpty, "A removed book is removed on every device")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Books/\(book.fingerprint).html").path))
    }

    func testConversationsAndTheirDeletionsSync() async throws {
        let phone = try device(), tablet = try device()
        let book = try await importBook(phone)
        let question = ReaderChatMessage(isUser: true, text: "What is this chapter about?")
        let answer = ReaderChatMessage(isUser: false, text: "Attention and arrival.")
        try phone.chats(book.fingerprint).save([question, answer], draft: "unsent")
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        let tabletChat = try tablet.chats(book.fingerprint)
        XCTAssertEqual(try tabletChat.page(before: nil, after: nil, limit: 24).messages.map(\.text), [question.text, answer.text])
        XCTAssertEqual(try tabletChat.loadDraft(), "", "Unsent drafts stay on their device")

        try tabletChat.remove(answer.id)
        await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(try phone.chats(book.fingerprint).page(before: nil, after: nil, limit: 24).messages.map(\.id), [question.id])
    }

    func testTheNewerSettingWinsAndLayoutStaysLocal() async throws {
        let phone = try device(), tablet = try device()
        phone.defaults.set("night", forKey: "reader.theme")
        phone.defaults.set(true, forKey: "reader.boldText")
        phone.defaults.set(120.0, forKey: "reader.chatButtonX")
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(tablet.defaults.string(forKey: "reader.theme"), "night")
        XCTAssertTrue(tablet.defaults.bool(forKey: "reader.boldText"))
        XCTAssertNil(tablet.defaults.object(forKey: "reader.chatButtonX"), "The floating button's position stays on each device")

        try await Task.sleep(for: .milliseconds(20))
        tablet.defaults.set(24.0, forKey: "reader.fontSize")
        tablet.defaults.set(false, forKey: "reader.boldText")
        await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(phone.defaults.double(forKey: "reader.fontSize"), 24)
        XCTAssertFalse(phone.defaults.bool(forKey: "reader.boldText"))
        XCTAssertEqual(phone.defaults.string(forKey: "reader.theme"), "night", "An unchanged setting is not overwritten")
    }
}

@MainActor
final class ICloudSyncStatusLayoutTests: XCTestCase {
    func testRecentSyncAndSpinnerKeepTheHeaderHeight() throws {
        for width in [280.0, 330, 600] {
            var heights: [CGFloat] = []
            for syncing in [false, true] {
                let content = ICloudSyncStatusHeader(title: syncing ? "Syncing…" : "Up to date",
                    subtitle: "Synced \(syncing ? "2 seconds ago" : "now") · 2 books · 0 highlights", syncing: syncing)
                    .environment(\.dynamicTypeSize, .large)
                let host = UIHostingController(rootView: content)
                let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                heights.append(size.height)
                XCTAssertGreaterThan(size.height, 0)
                if width >= 330 {
                    let image = ImageRenderer(content: content.frame(width: width).padding(16).background(ReadingTheme.paper.surface))
                    let attachment = XCTAttachment(image: try XCTUnwrap(image.uiImage))
                    attachment.name = "iCloud header \(syncing ? "syncing" : "settled") \(Int(width)) wide"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            XCTAssertEqual(heights[0], heights[1], accuracy: 0.5, "The status transition must not move the settings below at \(width)pt")
        }
        let error = UIHostingController(rootView: ICloudSyncStatusHeader(title: "Couldn’t sync",
            subtitle: String(repeating: "The selected folder is unavailable. ", count: 8), syncing: false))
        let normal = UIHostingController(rootView: ICloudSyncStatusHeader(title: "Up to date", subtitle: "Synced now", syncing: false))
        XCTAssertGreaterThan(error.sizeThatFits(in: CGSize(width: 330, height: 1000)).height,
                             normal.sizeThatFits(in: CGSize(width: 330, height: 1000)).height,
                             "Reserving recent-status space must not truncate longer errors")
    }
}
