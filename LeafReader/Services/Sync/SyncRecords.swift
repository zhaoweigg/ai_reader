import Foundation

/// One book as it lives in the sync folder, keyed by its content fingerprint so
/// the same file imported on two devices is one book. Deletions are kept as
/// timestamps so a device that was offline cannot bring a removed item back.
struct SyncedBook: Codable, Equatable {
    var fingerprint: String
    var title: String
    var author: String
    var format: BookFormat
    var importedAt: Date
    var catalogSource: String?
    var lastOpenedAt: Date?
    var progress: Double
    var locator: String
    var positionUpdatedAt: Date?
    var isFavorite: Bool
    var favoriteUpdatedAt: Date?
    var bookmarks: [BookBookmark]
    var annotations: [BookAnnotation]
    var deletedBookmarks: [UUID: Date] = [:]
    var deletedAnnotations: [UUID: Date] = [:]
    var removedAt: Date?

    init(_ book: Book) {
        fingerprint = book.fingerprint; title = book.title; author = book.author; format = book.format
        importedAt = book.importedAt; catalogSource = book.catalogSource; lastOpenedAt = book.lastOpenedAt
        progress = book.progress; locator = book.locator; positionUpdatedAt = book.positionUpdatedAt
        isFavorite = book.isFavorite; favoriteUpdatedAt = book.favoriteUpdatedAt
        bookmarks = book.bookmarks; annotations = book.annotations
    }

    var isRemoved: Bool { removedAt.map { $0 > importedAt } ?? false }

    /// Merges two copies of the same book. Positions and favorites go to the
    /// newer change; bookmarks and highlights are merged item by item.
    func merged(with other: SyncedBook) -> SyncedBook {
        var result = self
        if (other.positionUpdatedAt ?? .distantPast) > (positionUpdatedAt ?? .distantPast) {
            result.progress = other.progress; result.locator = other.locator; result.positionUpdatedAt = other.positionUpdatedAt
        }
        if (other.favoriteUpdatedAt ?? .distantPast) > (favoriteUpdatedAt ?? .distantPast) {
            result.isFavorite = other.isFavorite; result.favoriteUpdatedAt = other.favoriteUpdatedAt
        }
        result.lastOpenedAt = [lastOpenedAt, other.lastOpenedAt].compactMap { $0 }.max()
        result.importedAt = max(importedAt, other.importedAt)
        if title.isEmpty || title == "Unknown title" { result.title = other.title }
        if author.isEmpty || author == "Unknown author" { result.author = other.author }
        result.catalogSource = catalogSource ?? other.catalogSource
        result.removedAt = [removedAt, other.removedAt].compactMap { $0 }.max()
        result.deletedBookmarks = deletedBookmarks.merging(other.deletedBookmarks, uniquingKeysWith: max)
        result.deletedAnnotations = deletedAnnotations.merging(other.deletedAnnotations, uniquingKeysWith: max)

        var bookmarks = self.bookmarks
        for mark in other.bookmarks where !bookmarks.contains(where: { $0.id == mark.id }) { bookmarks.append(mark) }
        result.bookmarks = bookmarks.filter { mark in result.deletedBookmarks[mark.id].map { $0 < mark.createdAt } ?? true }
            .sorted { $0.createdAt < $1.createdAt }

        var annotations = self.annotations
        for note in other.annotations {
            if let index = annotations.firstIndex(where: { $0.id == note.id }) {
                if note.updatedAt > annotations[index].updatedAt { annotations[index] = note }
            } else { annotations.append(note) }
        }
        result.annotations = annotations.filter { note in result.deletedAnnotations[note.id].map { $0 < note.updatedAt } ?? true }
            .sorted { $0.createdAt < $1.createdAt }
        return result
    }

    /// Applies this record to a local book, keeping device-only fields.
    func apply(to book: inout Book) {
        book.title = title; book.author = author; book.catalogSource = catalogSource
        book.lastOpenedAt = lastOpenedAt; book.progress = progress; book.locator = locator
        book.positionUpdatedAt = positionUpdatedAt; book.isFavorite = isFavorite; book.favoriteUpdatedAt = favoriteUpdatedAt
        book.bookmarks = bookmarks; book.annotations = annotations
    }
}

/// What this device last agreed with the sync folder, used to tell a local
/// deletion apart from an item this device never had.
struct SyncBaseline: Codable, Equatable {
    var books: [String: BookIDs] = [:]
    var messages: [String: Set<UUID>] = [:]
    struct BookIDs: Codable, Equatable {
        var bookmarks: Set<UUID> = []
        var annotations: Set<UUID> = []
    }
}

/// One Ask Leaf conversation in the sync folder.
struct SyncedConversation: Codable, Equatable {
    var conversation: String
    var messages: [ReaderChatMessage]
    var deleted: [UUID: Date] = [:]

    /// Keeps this copy's order and appends messages only the other copy has.
    func merged(with other: SyncedConversation) -> SyncedConversation {
        var result = self
        result.deleted = deleted.merging(other.deleted, uniquingKeysWith: max)
        for message in other.messages {
            if let index = result.messages.firstIndex(where: { $0.id == message.id }) {
                // A finished reply replaces a copy saved while it was still streaming.
                if result.messages[index].state == .streaming, message.state != .streaming { result.messages[index] = message }
            } else { result.messages.append(message) }
        }
        result.messages.removeAll { result.deleted[$0.id] != nil }
        return result
    }
}

/// Settings shared across devices, each stamped with when it last changed.
struct SyncedSettings: Codable, Equatable {
    struct Value: Codable, Equatable {
        var data: Data
        var updatedAt: Date
    }
    var values: [String: Value] = [:]

    func merged(with other: SyncedSettings) -> SyncedSettings {
        var result = self
        for (key, value) in other.values where value.updatedAt > (result.values[key]?.updatedAt ?? .distantPast) {
            result.values[key] = value
        }
        return result
    }

    /// Reading and app preferences that mean the same thing on every device.
    /// Device layout (button and panel positions), identities, caches and
    /// anything holding a secret stay local.
    static let keys: Set<String> = [
        "reader.theme", "reader.font", "reader.fontSize", "reader.lineHeight", "reader.scrolling",
        "reader.horizontalMargin", "reader.verticalMargin", "reader.paragraphSpacing",
        "reader.chatButtonTransparency", "chat.dictationLanguage",
        "audio.voice", "audio.followsText", "audio.speed",
        "audio.speed.system",
        "ai.configuration", "zlibrary.origin", "zlibrary.feed", "zlibrary.searchOrder"
    ]
}
