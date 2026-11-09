import Foundation
import AVFoundation

/// Files stay separate from the library manifest. Inspection and transfers read
/// bounded chunks; recordings are never encoded into the JSON or loaded whole.
struct VoiceNoteFiles {
    let directory: URL
    func url(for note: VoiceNote) -> URL { directory.appendingPathComponent(note.fileName) }

    static func inspect(_ url: URL, id: UUID) throws -> VoiceNote {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, Int64(size) <= VoiceNote.maximumBytes else { throw VoiceNoteError.invalidRecording }
        let audio: AVAudioFile
        do { audio = try AVAudioFile(forReading: url) } catch { throw VoiceNoteError.invalidRecording }
        guard audio.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC,
              audio.processingFormat.sampleRate > 0 else { throw VoiceNoteError.invalidRecording }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration >= 0.1 else { throw VoiceNoteError.tooShort }
        let result = VoiceNote(id: id, duration: duration, byteCount: Int64(size), sha256: try LibraryDisk.fingerprint(url))
        guard result.valid else { throw VoiceNoteError.invalidRecording }
        return result
    }
    static func verify(_ url: URL, note: VoiceNote) throws {
        guard note.valid else { throw VoiceNoteError.invalidRecording }
        let actual = try inspect(url, id: note.id)
        guard actual.sha256 == note.sha256, actual.byteCount == note.byteCount,
              abs(actual.duration - note.duration) < 0.1 else { throw VoiceNoteError.invalidRecording }
    }
    /// Returns whether this commit created the file, for safe rollback if saving
    /// the annotation fails. A different clip can never replace the same ID.
    @discardableResult func store(_ source: URL, note: VoiceNote) throws -> Bool {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: note)
        if FileManager.default.fileExists(atPath: destination.path) {
            try Self.verify(destination, note: note); return false
        }
        try Self.verify(source, note: note)
        let staging = directory.appendingPathComponent("." + UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        try Self.verify(staging, note: note)
        do { try FileManager.default.moveItem(at: staging, to: destination); return true }
        catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                try Self.verify(destination, note: note); return false
            }
            throw error
        }
    }
    func remove(_ note: VoiceNote) { try? FileManager.default.removeItem(at: url(for: note)) }
}
