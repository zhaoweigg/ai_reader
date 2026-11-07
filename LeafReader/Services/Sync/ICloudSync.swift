import SwiftUI
import CryptoKit

/// Keeps the library, reading positions, bookmarks, highlights and notes, Ask
/// Leaf conversations and shared settings in a folder the user picked in
/// iCloud Drive. Book files are uploaded once and downloaded when a book is
/// opened (or all at once when books are kept on the device).
@MainActor
final class ICloudSync: ObservableObject {
    enum Status: Equatable { case off, syncing, upToDate, failed(String) }

    @Published private(set) var status = Status.off
    @Published private(set) var lastSynced: Date?
    @Published private(set) var folderName: String?
    @Published private(set) var cloudBytes: Int64 = 0
    @Published private(set) var downloading: Set<UUID> = []
    @Published var keepBooks: Bool { didSet { defaults.set(keepBooks, forKey: Keys.keepBooks); if keepBooks { schedule(after: 0) } } }

    var isConnected: Bool { folder != nil }
    private let library: LibraryStore
    private let defaults: UserDefaults
    private let stateDirectory: URL
    private var folder: SyncFolder?
    private var scopedRoot: URL?
    private var pending: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var timer: Timer?

    enum Keys {
        static let bookmark = "sync.folderBookmark", keepBooks = "sync.keepBooks"
        static let lastSynced = "sync.lastSynced", stamps = "sync.settingsStamps", snapshot = "sync.settingsSnapshot"
    }

    init(library: LibraryStore, defaults: UserDefaults, stateDirectory: URL, folderOverride: URL? = nil) {
        self.library = library; self.defaults = defaults; self.stateDirectory = stateDirectory
        keepBooks = defaults.object(forKey: Keys.keepBooks) as? Bool ?? true
        lastSynced = defaults.object(forKey: Keys.lastSynced) as? Date
        if let folderOverride { connect(folderOverride, persist: false) }
        else if let bookmark = defaults.data(forKey: Keys.bookmark) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) {
                connect(url, persist: stale)
            }
        }
        library.onSave = { [weak self] in self?.schedule(after: 2) }
        stampSettings()
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stampSettings() }
        }
    }
    private var settingsObserver: NSObjectProtocol?

    // MARK: Connecting

    /// Uses a folder from the Files picker. The folder must be in iCloud Drive
    /// for other devices to see it.
    func choose(_ url: URL) { connect(url, persist: true); schedule(after: 0) }

    func disconnect() {
        pending?.cancel(); timer?.invalidate(); timer = nil
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil; folder = nil; folderName = nil
        defaults.removeObject(forKey: Keys.bookmark)
        try? FileManager.default.removeItem(at: baselineURL)
        status = .off
    }

    private func connect(_ url: URL, persist: Bool) {
        scopedRoot?.stopAccessingSecurityScopedResource()
        let scoped = url.startAccessingSecurityScopedResource()
        scopedRoot = scoped ? url : nil
        if persist, let bookmark = try? url.bookmarkData() { defaults.set(bookmark, forKey: Keys.bookmark) }
        folder = SyncFolder(root: url)
        folderName = FileManager.default.displayName(atPath: url.path)
        status = lastSynced == nil ? .syncing : .upToDate
        timer?.invalidate()
        // Other devices' changes arrive through iCloud Drive without notice; check once a minute.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0) }
        }
    }

    var isInICloud: Bool {
        guard let root = folder?.root else { return false }
        return (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false
    }

    // MARK: Syncing

    func schedule(after seconds: Double) {
        guard folder != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let folder else { return }
        if let running { await running.value; return }
        // This pass includes the edits that queued an automatic sync already.
        pending?.cancel()
        pending = nil
        let task = Task { await perform(folder) }
        running = task
        await task.value
        running = nil
    }

    private func perform(_ folder: SyncFolder) async {
        status = .syncing
        // Persist the latest passage without scheduling another pass through
        // our own onSave callback. Real edits during the exchange still notify.
        library.flush(notifyObservers: false)
        let local = library.books
        let baseline = loadBaseline()
        let settings = localSettings()
        let chatDirectory = library.disk?.root.appendingPathComponent("ChatHistory", isDirectory: true)
        let archive = chatDirectory.flatMap { try? ChatHistoryStore(directory: $0, conversation: "") }
        let chats = (try? archive?.conversations().map { try archive!.export($0) }) ?? []
        let localCovers = Dictionary(uniqueKeysWithValues: local.compactMap { book in library.coverURL(book).map { (book.fingerprint, $0) } })
        let localFiles = Dictionary(uniqueKeysWithValues: local.compactMap { book in
            library.isDownloaded(book) ? library.fileURL(book).map { (book.fingerprint, $0) } : nil })
        let coversDirectory = library.disk?.coversDirectory
        do {
            let result = try await Task.detached(priority: .utility) {
                try Self.exchange(folder: folder, local: local, baseline: baseline, localFiles: localFiles,
                                  localCovers: localCovers, coversDirectory: coversDirectory,
                                  settings: settings, chats: archive == nil ? nil : chats)
            }.value
            adopt(result)
            for conversation in result.chats { try archive?.adopt(conversation) }
            if keepBooks { await downloadMissing() }
            lastSynced = Date(); defaults.set(lastSynced, forKey: Keys.lastSynced)
            cloudBytes = result.cloudBytes
            status = .upToDate
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    struct Exchange {
        var records: [SyncedBook]
        var newCovers: [String: String]
        var settings: SyncedSettings
        var chats: [SyncedConversation]
        var baseline: SyncBaseline
        var cloudBytes: Int64
    }

    /// Reads, merges and writes every record. Runs off the main actor; file
    /// coordination may wait for iCloud downloads.
    nonisolated static func exchange(folder: SyncFolder, local: [Book], baseline: SyncBaseline, localFiles: [String: URL],
                                     localCovers: [String: URL], coversDirectory: URL?, settings: SyncedSettings,
                                     chats: [SyncedConversation]?, now: Date = Date()) throws -> Exchange {
        try folder.prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        let remoteNames = folder.names(in: folder.library).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        let fingerprints = Set(local.map(\.fingerprint)).union(remoteNames).union(baseline.books.keys)
        var records: [SyncedBook] = []
        var newCovers: [String: String] = [:]
        var nextBaseline = SyncBaseline()

        for fingerprint in fingerprints.sorted() {
            let url = folder.library.appendingPathComponent(fingerprint + ".json")
            let versions = try folder.readAllVersions(url).compactMap { try? decoder.decode(SyncedBook.self, from: $0) }
            let remote = versions.dropFirst().reduce(versions.first) { $0?.merged(with: $1) }
            let book = local.first { $0.fingerprint == fingerprint }
            var mine = book.map(SyncedBook.init)
            if let base = baseline.books[fingerprint] {
                if book == nil, var removed = remote, !removed.isRemoved {
                    // Removed on this device since the last sync.
                    removed.removedAt = now
                    mine = removed
                }
                if var current = mine, book != nil {
                    for id in base.bookmarks where !current.bookmarks.contains(where: { $0.id == id }) { current.deletedBookmarks[id] = now }
                    for id in base.annotations where !current.annotations.contains(where: { $0.id == id }) { current.deletedAnnotations[id] = now }
                    mine = current
                }
            }
            guard let merged = [mine, remote].compactMap({ $0 }).reduce(nil, { (sum: SyncedBook?, next) in sum?.merged(with: next) ?? next }) else { continue }
            if merged != remote || versions.count > 1 {
                try folder.write(encoder.encode(merged), to: url)
                folder.resolveConflicts(url)
            }
            let bookURL = folder.books.appendingPathComponent(fingerprint + "." + merged.format.rawValue)
            let coverURL = folder.covers.appendingPathComponent(fingerprint + ".png")
            if merged.isRemoved {
                try? folder.remove(bookURL); try? folder.remove(coverURL)
            } else {
                if let file = localFiles[fingerprint], !folder.exists(bookURL) { try folder.upload(file, to: bookURL) }
                if let cover = localCovers[fingerprint], FileManager.default.fileExists(atPath: cover.path), !folder.exists(coverURL) {
                    try? folder.upload(cover, to: coverURL)
                }
                if book == nil, let coversDirectory, folder.exists(coverURL) {
                    let name = fingerprint + ".png"
                    if (try? folder.download(coverURL, to: coversDirectory.appendingPathComponent(name))) != nil { newCovers[fingerprint] = name }
                }
                nextBaseline.books[fingerprint] = .init(bookmarks: Set(merged.bookmarks.map(\.id)), annotations: Set(merged.annotations.map(\.id)))
            }
            records.append(merged)
        }

        var mergedChats: [SyncedConversation] = []
        if let chats {
            let remoteChats = folder.names(in: folder.chats).filter { $0.hasSuffix(".json") }
            var conversations = Set(chats.map(\.conversation))
            var remoteByName: [String: SyncedConversation] = [:]
            for name in remoteChats {
                let url = folder.chats.appendingPathComponent(name)
                let versions = try folder.readAllVersions(url).compactMap { try? decoder.decode(SyncedConversation.self, from: $0) }
                guard let first = versions.first else { continue }
                remoteByName[name] = versions.dropFirst().reduce(first) { $0.merged(with: $1) }
                conversations.insert(first.conversation)
            }
            for conversation in conversations.sorted() {
                let name = chatFileName(conversation)
                let url = folder.chats.appendingPathComponent(name)
                let mine = chats.first { $0.conversation == conversation } ?? SyncedConversation(conversation: conversation, messages: [])
                let remote = remoteByName[name]
                let merged = remote.map { mine.merged(with: $0) } ?? mine
                if merged != remote { try folder.write(encoder.encode(merged), to: url); folder.resolveConflicts(url) }
                if merged != mine { mergedChats.append(merged) }
            }
        }

        let remoteSettings = try folder.readAllVersions(folder.settings).compactMap { try? decoder.decode(SyncedSettings.self, from: $0) }
        let mergedSettings = remoteSettings.reduce(settings) { $0.merged(with: $1) }
        if mergedSettings != remoteSettings.first || remoteSettings.count > 1 {
            try folder.write(encoder.encode(mergedSettings), to: folder.settings)
            folder.resolveConflicts(folder.settings)
        }
        return Exchange(records: records, newCovers: newCovers, settings: mergedSettings, chats: mergedChats, baseline: nextBaseline,
                        cloudBytes: folder.size(of: folder.books) + folder.size(of: folder.covers))
    }

    nonisolated static func chatFileName(_ conversation: String) -> String {
        if conversation.count <= 80, conversation.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) {
            return conversation + ".json"
        }
        return SHA256.hash(data: Data(conversation.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Applies merged records to the library. Changes made on this device while
    /// the exchange ran are merged in again, so they are not lost.
    private func adopt(_ result: Exchange) {
        var books: [Book] = []
        for record in result.records {
            if let existing = library.books.first(where: { $0.fingerprint == record.fingerprint }) {
                guard !record.isRemoved else { continue }
                var book = existing
                record.merged(with: SyncedBook(existing)).apply(to: &book)
                books.append(book)
            } else if !record.isRemoved {
                let id = UUID()
                var book = Book(id: id, title: record.title, author: record.author, fileName: id.uuidString + "." + record.format.rawValue,
                                format: record.format, fingerprint: record.fingerprint, importedAt: record.importedAt)
                book.coverFileName = result.newCovers[record.fingerprint]
                book.metadataVersion = book.coverFileName == nil ? nil : BookMetadataLoader.version
                record.apply(to: &book)
                books.append(book)
            }
        }
        // Books imported here during the exchange are kept for the next pass.
        books += library.books.filter { book in !result.records.contains { $0.fingerprint == book.fingerprint } }
        let order = Dictionary(uniqueKeysWithValues: library.books.enumerated().map { ($1.fingerprint, $0) })
        books.sort { (order[$0.fingerprint] ?? .max, $0.importedAt) < (order[$1.fingerprint] ?? .max, $1.importedAt) }
        library.adoptSynced(books)
        adoptSettings(result.settings)
        saveBaseline(result.baseline)
    }

    // MARK: Book files

    /// Downloads a synced book's file before it is opened.
    func download(_ book: Book) async throws {
        guard !library.isDownloaded(book) else { return }
        guard let folder, let destination = library.fileURL(book) else { throw LibraryError.unavailable }
        let source = folder.books.appendingPathComponent(book.fingerprint + "." + book.format.rawValue)
        downloading.insert(book.id)
        defer { downloading.remove(book.id) }
        try await Task.detached(priority: .userInitiated) { try folder.download(source, to: destination) }.value
        await library.refreshMissingMetadata()
    }

    private func downloadMissing() async {
        for book in library.books where !library.isDownloaded(book) {
            try? await download(book)
        }
    }

    /// Frees space by deleting local copies of books already in iCloud Drive.
    func removeDownloads(keeping open: UUID? = nil) {
        guard let folder else { return }
        keepBooks = false
        for book in library.books where book.id != open && library.isDownloaded(book) {
            let cloud = folder.books.appendingPathComponent(book.fingerprint + "." + book.format.rawValue)
            guard folder.exists(cloud), let file = library.fileURL(book) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        objectWillChange.send()
    }

    var localBookBytes: Int64 {
        library.books.reduce(0) { total, book in
            guard library.isDownloaded(book), let url = library.fileURL(book) else { return total }
            return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: Settings

    /// Shared settings with when each last changed on this device.
    private func localSettings() -> SyncedSettings {
        stampSettings()
        let stamps = defaults.dictionary(forKey: Keys.stamps) as? [String: Date] ?? [:]
        var result = SyncedSettings()
        for key in SyncedSettings.keys {
            guard let data = encodedSetting(key) else { continue }
            result.values[key] = .init(data: data, updatedAt: stamps[key] ?? .distantPast)
        }
        return result
    }

    /// Records when shared settings change, so the newer change wins on another
    /// device. Writes only when something changed: it runs on every defaults change.
    private func stampSettings() {
        // Writing the stamps posts another defaults change synchronously.
        guard !stamping else { return }
        stamping = true
        defer { stamping = false }
        var stamps = defaults.dictionary(forKey: Keys.stamps) as? [String: Date] ?? [:]
        var snapshot = defaults.dictionary(forKey: Keys.snapshot) as? [String: Data] ?? [:]
        var changed = false
        for key in SyncedSettings.keys {
            guard let data = encodedSetting(key), snapshot[key] != data else { continue }
            snapshot[key] = data; stamps[key] = Date(); changed = true
        }
        guard changed else { return }
        defaults.set(snapshot, forKey: Keys.snapshot); defaults.set(stamps, forKey: Keys.stamps)
    }
    private var stamping = false

    private func encodedSetting(_ key: String) -> Data? {
        defaults.object(forKey: key).flatMap { try? PropertyListSerialization.data(fromPropertyList: [$0], format: .binary, options: 0) }
    }

    private func adoptSettings(_ merged: SyncedSettings) {
        var stamps = defaults.dictionary(forKey: Keys.stamps) as? [String: Date] ?? [:]
        var snapshot = defaults.dictionary(forKey: Keys.snapshot) as? [String: Data] ?? [:]
        var incoming: [String: Any] = [:]
        for (key, value) in merged.values where SyncedSettings.keys.contains(key) && snapshot[key] != value.data {
            guard let decoded = try? PropertyListSerialization.propertyList(from: value.data, format: nil) as? [Any],
                  let first = decoded.first else { continue }
            incoming[key] = first
            snapshot[key] = value.data; stamps[key] = value.updatedAt
        }
        guard !incoming.isEmpty else { return }
        // Record the incoming values first, so the change observer does not
        // restamp them as this device's own edits.
        defaults.set(snapshot, forKey: Keys.snapshot); defaults.set(stamps, forKey: Keys.stamps)
        for (key, value) in incoming { defaults.set(value, forKey: key) }
    }

    // MARK: Baseline

    private var baselineURL: URL { stateDirectory.appendingPathComponent("sync-baseline.json") }
    private func loadBaseline() -> SyncBaseline {
        (try? JSONDecoder().decode(SyncBaseline.self, from: Data(contentsOf: baselineURL))) ?? SyncBaseline()
    }
    private func saveBaseline(_ baseline: SyncBaseline) {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(baseline).write(to: baselineURL, options: .atomic)
    }
}
