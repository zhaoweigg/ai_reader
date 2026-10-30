import Foundation

/// Removes only the old, app-owned downloaded model. Books and listening cursors
/// live elsewhere; local build/test model directories are never inspected.
enum RetiredVoicePackCleanup {
    static func removeDownloadedPack(applicationSupport: URL) throws {
        let retired = applicationSupport.appendingPathComponent("KokoroVoices", isDirectory: true)
        if FileManager.default.fileExists(atPath: retired.path) {
            try FileManager.default.removeItem(at: retired)
        }
    }
}
