import XCTest
import SwiftUI
@testable import LeafReader

private struct NoCredentials: ChatCredentialStore {
    func read(account: String) throws -> String? { nil }
    func write(_ key: String?, account: String) throws {}
}

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

    private func voiceNote(_ device: Device, book: Book) async throws -> (BookAnnotation, URL) {
        let draft = device.root.appendingPathComponent("recording.m4a")
        try VoiceNoteFixture.write(to: draft, duration: 1.4)
        var note = annotation("A spoken thought 中文", at: 0.3)
        note.note = "Keep the written note too"
        note.voiceNote = try VoiceNoteFiles.inspect(draft, id: UUID()); note.voiceNoteUpdatedAt = Date()
        try await device.library.saveAnnotation(note, bookID: book.id, voiceDraft: draft)
        return (note, draft)
    }

    func testVoiceNotesRestoreOnANewDeviceWithoutDownloadingTheBook() async throws {
        let phone = try device(), tablet = try device(keepBooks: false)
        let book = try await importBook(phone), (note, _) = try await voiceNote(phone, book: book)
        await phone.sync.syncNow(); XCTAssertEqual(phone.sync.status, .upToDate)
        await tablet.sync.syncNow(); XCTAssertEqual(tablet.sync.status, .upToDate)
        let restored = try XCTUnwrap(tablet.library.books.first)
        XCTAssertEqual(restored.annotations, [note]); XCTAssertFalse(tablet.library.isDownloaded(restored))
        let clip = try XCTUnwrap(restored.annotations.first?.voiceNote)
        try VoiceNoteFiles.verify(try XCTUnwrap(tablet.library.voiceNoteURL(clip)), note: clip)
        XCTAssertEqual(clip.id, note.voiceNote?.id)
        XCTAssertNotEqual(restored.id, book.id, "Media IDs survive local book-ID changes")
    }

    func testConcurrentTextAndAudioEditsBothArriveAndAudioRemovalDoesNotResurrect() async throws {
        let phone = try device(), tablet = try device()
        let book = try await importBook(phone)
        var base = annotation("Concurrent note", at: 0.3); base.note = "Original"
        base.updatedAt = Date().addingTimeInterval(-30)
        try phone.library.saveAnnotation(base, bookID: book.id)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        let tabletBook = try XCTUnwrap(tablet.library.books.first)
        var text = base; text.note = "Text edited on tablet"
        text.contentUpdatedAt = base.updatedAt.addingTimeInterval(1); text.updatedAt = text.contentUpdatedAt!
        try tablet.library.saveAnnotation(text, bookID: tabletBook.id)
        let draft = phone.root.appendingPathComponent("concurrent.m4a"); try VoiceNoteFixture.write(to: draft)
        var audio = base; audio.voiceNote = try VoiceNoteFiles.inspect(draft, id: UUID())
        audio.voiceNoteUpdatedAt = base.updatedAt.addingTimeInterval(2); audio.updatedAt = audio.voiceNoteUpdatedAt!
        audio.contentUpdatedAt = base.updatedAt
        try await phone.library.saveAnnotation(audio, bookID: book.id, voiceDraft: draft)
        await phone.sync.syncNow(); await tablet.sync.syncNow(); await phone.sync.syncNow()
        for current in [phone.library.books.first, tablet.library.books.first] {
            XCTAssertEqual(current?.annotations.first?.note, text.note)
            XCTAssertEqual(current?.annotations.first?.voiceNote, audio.voiceNote)
        }
        var removed = try XCTUnwrap(tablet.library.books.first?.annotations.first)
        removed.voiceNote = nil; removed.voiceNoteUpdatedAt = Date(); removed.updatedAt = Date()
        try tablet.library.saveAnnotation(removed, bookID: tabletBook.id)
        await tablet.sync.syncNow()
        let clip = try XCTUnwrap(audio.voiceNote)
        let cloud = folder.appendingPathComponent("VoiceNotes/" + clip.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.path))
        // A previously failed cleanup/stale upload is retried from the durable
        // media tombstone even after the record has already dropped its clip.
        try FileManager.default.copyItem(at: draft, to: cloud)
        let inFlight = folder.appendingPathComponent("VoiceNotes/" + UUID().uuidString.lowercased() + ".m4a")
        try FileManager.default.copyItem(at: draft, to: inFlight)
        await tablet.sync.syncNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlight.path), "Never collect a different device's in-flight upload")
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertNil(phone.library.books.first?.annotations.first?.voiceNote)
        XCTAssertEqual(phone.library.books.first?.annotations.first?.note, text.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(phone.library.voiceNoteURL(clip)).path))
        // A download begun before removal may finish after the local annotation
        // already lost its clip. The durable tombstone must clean it on retry.
        let staleLocal = try XCTUnwrap(phone.library.voiceNoteURL(clip))
        try FileManager.default.copyItem(at: draft, to: staleLocal)
        let unknownLocal = staleLocal.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased() + ".m4a")
        try FileManager.default.copyItem(at: draft, to: unknownLocal)
        await phone.sync.syncNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleLocal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownLocal.path), "Never collect a different editor's in-flight local recording")
    }

    func testBadCloudAudioCannotReplaceLocalNotesAndCanBeRetriedAfterRepair() async throws {
        let phone = try device(), tablet = try device(keepBooks: false)
        let book = try await importBook(phone), (note, source) = try await voiceNote(phone, book: book)
        await phone.sync.syncNow()
        let clip = try XCTUnwrap(note.voiceNote), cloud = folder.appendingPathComponent("VoiceNotes/" + clip.fileName)
        try Data("Invalid recording".utf8).write(to: cloud, options: .atomic)
        await tablet.sync.syncNow()
        if case .failed = tablet.sync.status { } else { XCTFail("Corrupt media must fail the sync") }
        XCTAssertTrue(tablet.library.books.isEmpty, "Do not adopt a record pointing at unverified audio")
        try VoiceNoteFiles.verify(try XCTUnwrap(phone.library.voiceNoteURL(clip)), note: clip)
        try FileManager.default.removeItem(at: cloud); try FileManager.default.copyItem(at: source, to: cloud)
        await tablet.sync.syncNow(); XCTAssertEqual(tablet.sync.status, .upToDate)
        XCTAssertEqual(tablet.library.books.first?.annotations, [note])
    }

    func testDeletingABookRemovesItsAudioAndReimportDoesNotRestoreMissingMedia() async throws {
        let phone = try device(), tablet = try device()
        let book = try await importBook(phone), (note, _) = try await voiceNote(phone, book: book)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        let clip = try XCTUnwrap(note.voiceNote), cloud = folder.appendingPathComponent("VoiceNotes/" + clip.fileName)
        phone.library.remove(book.id)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(phone.sync.status, .upToDate); XCTAssertEqual(tablet.sync.status, .upToDate)
        XCTAssertTrue(tablet.library.books.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: cloud.path))
        _ = try await importBook(phone)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(phone.sync.status, .upToDate); XCTAssertEqual(tablet.sync.status, .upToDate)
        XCTAssertTrue(tablet.library.books.first?.annotations.allSatisfy { $0.voiceNote == nil } == true)
    }

    func testVoiceDownloadsAreBoundedAndNeverReplaceAnExistingFileOnFailure() throws {
        let target = try device(), path = folder.appendingPathComponent("too-large.m4a")
        try Data(repeating: 7, count: 100_000).write(to: path)
        let destination = target.root.appendingPathComponent("kept.m4a"), kept = Data("Keep this".utf8)
        try kept.write(to: destination)
        XCTAssertThrowsError(try SyncFolder(root: folder).download(path, to: destination, maximumBytes: 100))
        XCTAssertEqual(try Data(contentsOf: destination), kept)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: target.root.path).filter { $0.hasSuffix(".download") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAutomaticSyncSettlesAndStillSendsLocalChanges() async throws {
        let phone = try device(automaticSync: true)
        defer { phone.sync.disconnect() }
        // Seed before observing the behavior under test. A cold metadata load
        // can yield long enough for import callbacks to sync the fixture first.
        let onSave = try XCTUnwrap(phone.library.onSave)
        phone.library.onSave = nil
        let book = try await importBook(phone)
        phone.library.onSave = onSave
        var starts = 0
        let observation = phone.sync.$status.sink { if $0 == .syncing { starts += 1 } }
        defer { observation.cancel() }
        await phone.sync.syncNow()
        XCTAssertEqual(phone.sync.status, .upToDate)
        let initialStarts = starts
        XCTAssertGreaterThanOrEqual(initialStarts, 1)
        // Observe beyond the real two-second save debounce. The production
        // callback stays connected, unlike the explicit two-device fixtures.
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertEqual(starts, initialStarts, "A completed sync must not schedule itself again")

        let nextStarts = starts + 1
        phone.library.setPosition(book.id, locator: "epubcfi(/6/4!/4/8)", fraction: 0.61)
        let deadline = Date().addingTimeInterval(6)
        while (starts < nextStarts || phone.sync.status != .upToDate) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(starts, nextStarts, "A real local edit must still sync automatically")
        let remote = folder.appendingPathComponent("Library/\(book.fingerprint).json")
        let record = try JSONDecoder().decode(SyncedBook.self, from: Data(contentsOf: remote))
        XCTAssertEqual(record.locator, "epubcfi(/6/4!/4/8)")
        XCTAssertEqual(record.progress, 0.61, accuracy: 0.0001)
        try await Task.sleep(for: .milliseconds(2400))
        XCTAssertEqual(starts, nextStarts, "The automatic pass must settle too")
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

    func testAISettingsChangedOnOneDeviceApplyOnTheOtherWithoutARelaunch() async throws {
        let phone = try device(), tablet = try device()
        let onPhone = AISettingsStore(defaults: phone.defaults, credentials: NoCredentials())
        let onTablet = AISettingsStore(defaults: tablet.defaults, credentials: NoCredentials())
        var changed = onPhone.configuration
        changed.profile.model = "claude-haiku-4-5"; changed.sharePage = false
        try onPhone.save(changed, replacementKey: nil)
        XCTAssertNotEqual(onTablet.configuration, changed)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(onTablet.configuration, changed, "The open app uses the synced model and sharing choice at once")

        try await Task.sleep(for: .milliseconds(20))
        var newer = changed
        newer.profile.maxOutputTokens = 4096; newer.sharePage = true
        try onTablet.save(newer, replacementKey: nil)
        await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(onPhone.configuration, newer, "The newer change wins on the device that made the older one")

        tablet.defaults.set(Data("not settings".utf8), forKey: "ai.configuration")
        XCTAssertEqual(onTablet.configuration, newer, "A value this version cannot read leaves the settings in use alone")
    }

    func testQuickPromptsEditedOnOneDeviceAppearOnTheOtherAndAResetFollows() async throws {
        let phone = try device(), tablet = try device()
        let onPhone = AISettingsStore(defaults: phone.defaults, credentials: NoCredentials())
        let onTablet = AISettingsStore(defaults: tablet.defaults, credentials: NoCredentials())
        let words = ChatQuickPrompt(title: "Words", prompt: "List the hard words.")
        onPhone.saveQuickPrompts(ChatQuickPrompt.defaults + [words])
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(onTablet.quickPrompts.map(\.label), ["Explain", "Summarize", "Words"], "The open app shows them without a relaunch")
        XCTAssertEqual(onTablet.quickPrompts, onPhone.quickPrompts)
        XCTAssertEqual(AISettingsStore(defaults: tablet.defaults, credentials: NoCredentials()).quickPrompts, onPhone.quickPrompts)

        try await Task.sleep(for: .milliseconds(20))
        onTablet.saveQuickPrompts([words])
        await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(onPhone.quickPrompts, [words], "The newer edit wins, deletions included")

        try await Task.sleep(for: .milliseconds(20))
        onPhone.saveQuickPrompts(ChatQuickPrompt.defaults)
        await phone.sync.syncNow(); await tablet.sync.syncNow()
        XCTAssertEqual(onTablet.quickPrompts, ChatQuickPrompt.defaults, "A reset reaches the other device")
        await tablet.sync.syncNow(); await phone.sync.syncNow()
        XCTAssertEqual(onPhone.quickPrompts, ChatQuickPrompt.defaults, "The other device's older list does not come back")
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
