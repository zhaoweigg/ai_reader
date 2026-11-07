import XCTest
import AVFoundation
@testable import LeafReader

@MainActor final class VoiceNoteTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceNotesTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func recording(in root: URL, duration: TimeInterval = 1.2, id: UUID = UUID()) throws -> (URL, VoiceNote) {
        let url = root.appendingPathComponent(UUID().uuidString + ".m4a")
        try VoiceNoteFixture.write(to: url, duration: duration)
        return (url, try VoiceNoteFiles.inspect(url, id: id))
    }
    private func library() throws -> (LibraryStore, Book, URL) {
        let root = try root(), disk = try LibraryDisk(root: root)
        let book = Book(id: UUID(), title: "Voice notes", author: "Leaf", fileName: "book.txt", format: .txt, fingerprint: "voice-book")
        try disk.save([book])
        return (LibraryStore(root: root, seedSamples: false), book, root)
    }
    private func annotation() -> BookAnnotation {
        BookAnnotation(text: "A passage worth remembering 中文", locator: "epubcfi(/6/2!/4/2/1:2)", chapter: "One", fraction: 0.3)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testLegacyNotesDecodeWithoutVoiceFieldsAndVoiceMarksNoteBadge() throws {
        var note = annotation(); note.note = "Original text note"
        let encoded = try JSONEncoder().encode(note)
        let restored = try JSONDecoder().decode(BookAnnotation.self, from: encoded)
        XCTAssertEqual(restored, note); XCTAssertNil(restored.voiceNote); XCTAssertNil(restored.voiceNoteUpdatedAt)
        let (_, clip) = try recording(in: root())
        note.note = ""; note.voiceNote = clip; note.voiceNoteUpdatedAt = Date()
        XCTAssertTrue(note.valid); XCTAssertTrue(note.hasNote); XCTAssertFalse(note.hasTextNote)
        XCTAssertEqual(note.webPayload["hasNote"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(BookAnnotation.self, from: JSONEncoder().encode(note)), note)
    }
    func testAudioAndTextSurviveRelaunchAndRemovalKeepsThePassageAndReadingState() async throws {
        let (library, book, root) = try library()
        library.setPosition(book.id, locator: "epubcfi(/6/4!/4/8)", fraction: 0.6)
        library.toggleBookmark(book.id, locator: "epubcfi(/6/4!/4/6)", fraction: 0.5, label: "Keep")
        let (draft, clip) = try recording(in: root)
        var note = annotation(); note.note = "My text"; note.voiceNote = clip; note.voiceNoteUpdatedAt = Date()
        try await library.saveAnnotation(note, bookID: book.id, voiceDraft: draft)
        let reopened = LibraryStore(root: root, seedSamples: false)
        XCTAssertEqual(reopened.book(book.id)?.annotations, [note])
        try VoiceNoteFiles.verify(try XCTUnwrap(reopened.voiceNoteURL(clip)), note: clip)
        XCTAssertEqual(reopened.book(book.id)?.locator, "epubcfi(/6/4!/4/8)")
        XCTAssertEqual(reopened.book(book.id)?.bookmarks.count, 1)
        note.voiceNote = nil; note.voiceNoteUpdatedAt = Date(); note.updatedAt = Date()
        try reopened.saveAnnotation(note, bookID: book.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(reopened.voiceNoteURL(clip)).path))
        let saved = try XCTUnwrap(LibraryStore(root: root, seedSamples: false).book(book.id)?.annotations.first)
        XCTAssertEqual(saved.note, "My text"); XCTAssertEqual(saved.locator, note.locator); XCTAssertNil(saved.voiceNote)
    }
    func testReplacementAndAnnotationDeletionRemoveOnlyUnreferencedClips() async throws {
        let (library, book, root) = try library()
        let (draft, first) = try recording(in: root)
        var note = annotation(); note.voiceNote = first; note.voiceNoteUpdatedAt = Date()
        try await library.saveAnnotation(note, bookID: book.id, voiceDraft: draft)
        library.removeUnreferencedVoiceNoteFiles([first.id])
        try VoiceNoteFiles.verify(try XCTUnwrap(library.voiceNoteURL(first)), note: first)
        let (replacement, second) = try recording(in: root, duration: 1.6)
        note.voiceNote = second; note.voiceNoteUpdatedAt = Date(); note.updatedAt = Date()
        try await library.saveAnnotation(note, bookID: book.id, voiceDraft: replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(library.voiceNoteURL(first)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(library.voiceNoteURL(second)).path))
        try library.removeAnnotation(note.id, bookID: book.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(library.voiceNoteURL(second)).path))
        XCTAssertTrue(library.book(book.id)?.annotations.isEmpty == true)
    }
    func testFailedManifestCommitKeepsOldAudioAndRollsBackTheNewAsset() async throws {
        let (library, book, root) = try library()
        let (draft, first) = try recording(in: root)
        var note = annotation(); note.note = "Keep"; note.voiceNote = first; note.voiceNoteUpdatedAt = Date()
        try await library.saveAnnotation(note, bookID: book.id, voiceDraft: draft)
        let disk = try XCTUnwrap(library.disk), backup = root.appendingPathComponent("backup.json")
        let original = try Data(contentsOf: disk.manifest)
        try FileManager.default.moveItem(at: disk.manifest, to: backup)
        try FileManager.default.createDirectory(at: disk.manifest, withIntermediateDirectories: false)
        let (nextDraft, next) = try recording(in: root, duration: 1.8)
        var edit = note; edit.voiceNote = next; edit.voiceNoteUpdatedAt = Date(); edit.updatedAt = Date()
        do { try await library.saveAnnotation(edit, bookID: book.id, voiceDraft: nextDraft); XCTFail("Manifest write must fail") } catch { }
        XCTAssertEqual(library.book(book.id)?.annotations, [note])
        try VoiceNoteFiles.verify(try XCTUnwrap(library.voiceNoteURL(first)), note: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(library.voiceNoteURL(next)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nextDraft.path), "Failed Save keeps the editor's draft for retry")
        try FileManager.default.removeItem(at: disk.manifest); try FileManager.default.moveItem(at: backup, to: disk.manifest)
        XCTAssertEqual(try Data(contentsOf: disk.manifest), original)
    }
    func testCorruptOversizedAndSymlinkedFilesCannotReplaceAValidAsset() throws {
        let root = try root(), (source, clip) = try recording(in: root)
        let files = VoiceNoteFiles(directory: root.appendingPathComponent("Assets"))
        XCTAssertTrue(try files.store(source, note: clip))
        let wrong = VoiceNote(id: clip.id, duration: clip.duration, byteCount: clip.byteCount, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try files.store(source, note: wrong))
        try VoiceNoteFiles.verify(files.url(for: clip), note: clip)
        let huge = root.appendingPathComponent("large.m4a")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(VoiceNote.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try VoiceNoteFiles.inspect(huge, id: UUID()))
        let link = root.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try VoiceNoteFiles.inspect(link, id: UUID()))
    }
    func testConcurrentTextAudioAndExplicitAudioRemovalMergeWithoutResurrection() throws {
        let (_, clip) = try recording(in: root())
        var base = annotation(); base.updatedAt = Date(timeIntervalSince1970: 100)
        var audio = base; audio.voiceNote = clip; audio.voiceNoteUpdatedAt = Date(timeIntervalSince1970: 200)
        audio.contentUpdatedAt = base.updatedAt; audio.updatedAt = audio.voiceNoteUpdatedAt!
        var text = base; text.note = "Edited independently"; text.contentUpdatedAt = Date(timeIntervalSince1970: 150); text.updatedAt = text.contentUpdatedAt!
        let merged = audio.mergingEdits(from: text)
        XCTAssertEqual(merged, text.mergingEdits(from: audio))
        XCTAssertEqual(merged.note, text.note); XCTAssertEqual(merged.voiceNote, clip)
        var removed = merged; removed.voiceNote = nil; removed.voiceNoteUpdatedAt = Date(timeIntervalSince1970: 250); removed.updatedAt = removed.voiceNoteUpdatedAt!
        text.updatedAt = Date(timeIntervalSince1970: 300); text.contentUpdatedAt = text.updatedAt; text.note = "Later text"
        let final = text.mergingEdits(from: removed)
        XCTAssertEqual(final.note, "Later text"); XCTAssertNil(final.voiceNote)
        XCTAssertEqual(final, removed.mergingEdits(from: text))
    }
    func testCancellingAuthorizationNeverStartsTheMicrophoneOrCreatesADraft() async throws {
        let recorder = RecorderStub(); recorder.delaysPermission = true
        let session = VoiceNoteSession(recorder: recorder)
        session.startRecording()
        try await eventually { recorder.permission != nil }
        session.close(); recorder.permission?.resume(returning: true); recorder.permission = nil
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(recorder.starts, 0); XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.recordedNote); XCTAssertNil(session.draftURL)
    }
    func testDeniedPermissionAndRecorderFailureRemainRetryableWithoutSavingAnything() async throws {
        let recorder = RecorderStub(); recorder.allowed = false
        let session = VoiceNoteSession(recorder: recorder); defer { session.close() }
        session.startRecording(); try await eventually { session.needsSettings }
        XCTAssertEqual(recorder.starts, 0); XCTAssertEqual(session.state, .idle)
        recorder.allowed = true; recorder.failStart = true
        session.startRecording(); try await eventually { session.state == .idle && session.error != nil && !session.needsSettings }
        XCTAssertNil(session.draftURL); XCTAssertNil(session.recordedNote)
    }
    func testBackgroundStopKeepsAPlayableDraftAndCloseDeletesOnlyTheDraft() async throws {
        let recorder = RecorderStub(), session = VoiceNoteSession(recorder: recorder)
        session.startRecording(); try await eventually { session.state == .recording }
        session.suspend(background: true)
        try await eventually { session.state == .ready }
        let url = try XCTUnwrap(session.draftURL), clip = try XCTUnwrap(session.recordedNote)
        try VoiceNoteFiles.verify(url, note: clip)
        session.togglePlayback(url: url)
        try await eventually { session.isPlaying && session.playbackTime > 0.1 }
        session.pausePlayback(); let paused = session.playbackTime
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.playbackTime, paused, accuracy: 0.02)
        session.togglePlayback(url: url)
        try await eventually { session.isPlaying && session.playbackTime > paused + 0.08 }
        session.close(); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testRecordingLimitAndCompetingAudioStopCaptureWithoutDroppingTheDraft() async throws {
        let recorder = RecorderStub(), session = VoiceNoteSession(recorder: recorder, limit: 0.15)
        defer { session.close() }
        session.startRecording(); try await eventually { session.state == .ready }
        XCTAssertEqual(recorder.receivedLimit, 0.15, accuracy: 0.001)
        XCTAssertNotNil(session.recordedNote)
        let other = VoiceNoteSession(recorder: RecorderStub(), limit: 30)
        defer { other.close() }
        other.startRecording(); try await eventually { other.state == .recording }
        NotificationCenter.default.post(name: ReadAloudAudioSession.willActivate, object: nil)
        try await eventually { other.state == .ready }
        XCTAssertNotNil(other.recordedNote)
    }
    func testVoiceSelectionOpensAnUnsavedDraftAndPreservesExistingText() async throws {
        let (library, book, root) = try library(), (_, clip) = try recording(in: root)
        var note = annotation(); note.note = "Keep this text"
        try library.saveAnnotation(note, bookID: book.id)
        let model = ReaderModel(bookID: book.id, library: library, initialLocator: nil)
        let selection = BookAnnotationSelection(text: note.text, locator: note.locator, chapter: note.chapter, fraction: note.fraction)
        model.annotateSelection(.voiceNote, selection: selection)
        XCTAssertTrue(model.annotationStartsWithVoice); XCTAssertEqual(model.annotationDraft, note)
        XCTAssertNil(library.book(book.id)?.annotations.first?.voiceNote)
        var voiceOnly = note; voiceOnly.voiceNote = clip; voiceOnly.voiceNoteUpdatedAt = Date()
        voiceOnly.contentUpdatedAt = note.updatedAt; voiceOnly.updatedAt = Date()
        var newerText = note; newerText.note = "Text from another editor"; newerText.contentUpdatedAt = Date(); newerText.updatedAt = Date()
        try library.saveAnnotation(newerText, bookID: book.id)
        let source = root.appendingPathComponent("new.m4a"); try VoiceNoteFixture.write(to: source, duration: clip.duration)
        // Use the exact encoded clip; AAC encoding can carry different packet padding.
        let actual = try VoiceNoteFiles.inspect(source, id: clip.id); voiceOnly.voiceNote = actual
        try await library.saveAnnotation(voiceOnly, bookID: book.id, voiceDraft: source)
        XCTAssertEqual(library.book(book.id)?.annotations.first?.note, newerText.note)
        XCTAssertNotNil(library.book(book.id)?.annotations.first?.voiceNote)
    }

    private final class RecorderStub: VoiceNoteRecording {
        var allowed = true, delaysPermission = false, failStart = false
        var permission: CheckedContinuation<Bool, Never>?
        var starts = 0, receivedLimit: TimeInterval = 0
        private var url: URL?
        private var started = Date()
        var currentTime: TimeInterval { Date().timeIntervalSince(started) }
        func authorize() async -> Bool {
            if delaysPermission { return await withCheckedContinuation { permission = $0 } }
            return allowed
        }
        func start(at url: URL, limit: TimeInterval, finished: @escaping (Bool) -> Void) throws {
            starts += 1; receivedLimit = limit
            if failStart { throw VoiceNoteError.unavailable }
            self.url = url; started = Date()
        }
        func stop() { if let url { try? VoiceNoteFixture.write(to: url, duration: 1.2) }; url = nil }
        func cancel() { url = nil }
    }
}
