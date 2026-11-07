import Foundation

/// The folder the user picked in iCloud Drive. Every read and write goes
/// through file coordination, so iCloud never sees a half-written file and a
/// file that is still in the cloud is downloaded before it is read.
struct SyncFolder {
    let root: URL
    var books: URL { root.appendingPathComponent("Books", isDirectory: true) }
    var covers: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    var library: URL { root.appendingPathComponent("Library", isDirectory: true) }
    var chats: URL { root.appendingPathComponent("Chats", isDirectory: true) }
    var voiceNotes: URL { root.appendingPathComponent("VoiceNotes", isDirectory: true) }
    var settings: URL { root.appendingPathComponent("Settings.json") }

    func prepare() throws {
        for directory in [books, covers, library, chats, voiceNotes] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Names of the files in a directory, including ones iCloud has not
    /// downloaded yet (listed as `.name.icloud` placeholders on some systems).
    func names(in directory: URL) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Array(Set(entries.compactMap { name -> String? in
            if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(7)) }
            return name.hasPrefix(".") ? nil : name
        })).sorted()
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder(url).path)
    }

    func read(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadNoSuchFile))
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// The current contents plus any versions iCloud kept from simultaneous
    /// edits on other devices. The caller merges them all, writes the result
    /// and then calls `resolveConflicts`, so no device's change is dropped.
    func readAllVersions(_ url: URL) throws -> [Data] {
        guard exists(url) else { return [] }
        var versions = [try read(url)]
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            if let data = try? Data(contentsOf: version.url) { versions.append(data) }
        }
        return versions
    }

    func resolveConflicts(_ url: URL) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else { return }
        for version in versions { version.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }

    func write(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try data.write(to: url, options: .atomic) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Copies a local file into the folder (a book or cover upload).
    func upload(_ source: URL, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result {
                let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).upload")
                try FileManager.default.copyItem(at: source, to: staging)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Copies a file out of the folder, downloading it from iCloud first if needed.
    func download(_ url: URL, to destination: URL, maximumBytes: Int64? = nil) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).download")
                defer { try? FileManager.default.removeItem(at: staging) }
                if let maximumBytes {
                    guard maximumBytes > 0, maximumBytes <= VoiceNote.maximumBytes else { throw VoiceNoteError.invalidRecording }
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw VoiceNoteError.unavailable }
                    let output = try FileHandle(forWritingTo: staging)
                    defer { try? output.close() }
                    var count: Int64 = 0
                    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        count += Int64(chunk.count)
                        guard count <= maximumBytes else { throw VoiceNoteError.invalidRecording }
                        try output.write(contentsOf: chunk)
                    }
                    try output.close()
                } else { try FileManager.default.copyItem(at: url, to: staging) }
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    func remove(_ url: URL) throws {
        guard exists(url) else { return }
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            result = Result { try FileManager.default.removeItem(at: url) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    /// Bytes of the files in a directory, counting ones still in the cloud.
    func size(of directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.reduce(0) { total, url in total + Int64((try? url.resourceValues(forKeys: keys).fileSize) ?? 0) }
    }

    private func placeholder(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }
}
