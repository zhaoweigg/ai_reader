import Foundation
import SQLite3
import UIKit

struct ChatHistoryPage {
    var messages: [ReaderChatMessage] = []
    /// Where each message sits in the saved conversation, in the order of `messages`.
    var sequences: [Int64] = []
    var oldest: Int64?
    var newest: Int64?
    var hasEarlier = false
    var hasNewer = false
}

enum ChatDraftSelectionUpdate { case unchanged, set(ReadingChatContext?) }

@MainActor
protocol ChatHistoryStorage {
    func page(before: Int64?, after: Int64?, limit: Int) throws -> ChatHistoryPage
    func save(_ messages: [ReaderChatMessage], draft: String?, selection: ChatDraftSelectionUpdate) throws
    func loadDraft() throws -> String
    func loadSelectedContext() throws -> ReadingChatContext?
    func remove(_ messageID: UUID) throws
    func clear() throws
}

extension ChatHistoryStorage {
    func save(_ messages: [ReaderChatMessage], draft: String?) throws { try save(messages, draft: draft, selection: .unchanged) }
}

/// Pictures generated in chat, one file each beside the chat database. Messages
/// keep only the file name, so the database stays small and old histories decode.
enum ChatImageStore {
    static let maxBytes = 16 << 20

    /// Writes a decodable JPEG, PNG or WebP picture and returns its file name.
    static func save(_ data: Data, in directory: URL) throws -> String {
        guard data.count <= maxBytes, let ext = fileExtension(data), UIImage(data: data) != nil else { throw ChatError.invalidResponse }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let name = UUID().uuidString + "." + ext
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return name
    }
    /// The file for a stored name. Names arrive from synced history too, so only
    /// names this store could have written resolve; anything else is ignored.
    static func url(_ name: String, in directory: URL) -> URL? {
        guard isStoredName(name) else { return nil }
        return directory.appendingPathComponent(name)
    }
    static func remove(_ names: [String], in directory: URL) {
        for name in names { if let url = url(name, in: directory) { try? FileManager.default.removeItem(at: url) } }
    }
    static func isStoredName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, ["jpg", "png", "webp"].contains(parts[1]) else { return false }
        return UUID(uuidString: String(parts[0])) != nil && String(parts[0]) == UUID(uuidString: String(parts[0]))?.uuidString
    }
    static func fileExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.count == 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return nil
    }
}

enum ChatHistoryError: LocalizedError {
    case unavailable, unreadable, write
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Saved chat history could not be opened. Your existing history has been kept. Reopen the book to try again."
        case .unreadable: return "Saved chat history could not be read. Your existing history has been kept. Reopen the book to try again."
        case .write: return "Chat changes could not be saved on this device. Free some storage and try saving again."
        }
    }
}

// One indexed database per library. Each book's fingerprint is a separate
// conversation, so reimporting the same file can restore its saved discussion.
@MainActor
final class ChatHistoryStore: ChatHistoryStorage {
    private var database: OpaquePointer?
    private let conversation: String
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL, conversation: String) throws {
        self.conversation = conversation
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let file = directory.appendingPathComponent("conversations.sqlite")
            guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw ChatHistoryError.unavailable
            }
            sqlite3_busy_timeout(database, 1000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-256; PRAGMA mmap_size=0; PRAGMA secure_delete=ON;")
            try execute("""
                CREATE TABLE IF NOT EXISTS messages (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL,
                    UNIQUE(conversation, id));
                CREATE INDEX IF NOT EXISTS conversation_sequence ON messages(conversation, sequence);
                CREATE TABLE IF NOT EXISTS drafts (conversation TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS selected_drafts (conversation TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS deleted_messages (conversation TEXT NOT NULL, id TEXT NOT NULL, deleted_at REAL NOT NULL,
                    PRIMARY KEY(conversation, id));
                """)
        } catch {
            sqlite3_close(database); database = nil
            throw ChatHistoryError.unavailable
        }
    }
    deinit { sqlite3_close(database) }

    func page(before: Int64? = nil, after: Int64? = nil, limit: Int = 24) throws -> ChatHistoryPage {
        let ascending = after != nil
        let bound = before != nil ? "AND sequence < ?" : after != nil ? "AND sequence > ?" : ""
        let statement = try prepare("SELECT sequence, payload FROM messages WHERE conversation = ? \(bound) ORDER BY sequence \(ascending ? "ASC" : "DESC") LIMIT ?")
        defer { sqlite3_finalize(statement) }
        bind(conversation, to: statement, at: 1)
        var index: Int32 = 2
        if let cursor = before ?? after { sqlite3_bind_int64(statement, index, cursor); index += 1 }
        sqlite3_bind_int(statement, index, Int32(min(48, max(1, limit))))
        var rows: [(Int64, ReaderChatMessage)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ChatHistoryError.unreadable }
            let sequence = sqlite3_column_int64(statement, 0)
            guard let bytes = sqlite3_column_blob(statement, 1) else { throw ChatHistoryError.unreadable }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
            guard var message = try? JSONDecoder().decode(ReaderChatMessage.self, from: data) else { throw ChatHistoryError.unreadable }
            // A previous process cannot still be delivering this response.
            if message.state == .streaming { message.state = .stopped }
            rows.append((sequence, message))
        }
        if !ascending { rows.reverse() }
        var page = ChatHistoryPage(messages: rows.map(\.1), sequences: rows.map(\.0), oldest: rows.first?.0, newest: rows.last?.0)
        if let oldest = page.oldest { page.hasEarlier = try exists("sequence < ?", cursor: oldest) }
        if let newest = page.newest { page.hasNewer = try exists("sequence > ?", cursor: newest) }
        return page
    }
    func loadDraft() throws -> String {
        let statement = try prepare("SELECT payload FROM drafts WHERE conversation = ?")
        defer { sqlite3_finalize(statement) }
        bind(conversation, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return "" }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0),
              let value = String(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))), encoding: .utf8) else { throw ChatHistoryError.unreadable }
        return value
    }
    func loadSelectedContext() throws -> ReadingChatContext? {
        let statement = try prepare("SELECT payload FROM selected_drafts WHERE conversation = ?")
        defer { sqlite3_finalize(statement) }
        bind(conversation, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0),
              let context = try? JSONDecoder().decode(ReadingChatContext.self,
                from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) else { throw ChatHistoryError.unreadable }
        return context.bounded()
    }
    func save(_ messages: [ReaderChatMessage], draft: String?, selection: ChatDraftSelectionUpdate = .unchanged) throws {
        try transaction {
            if case .set(let context) = selection {
                let statement = try prepare(context == nil ? "DELETE FROM selected_drafts WHERE conversation = ?" : "INSERT INTO selected_drafts(conversation, payload) VALUES(?, ?) ON CONFLICT(conversation) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(statement) }
                bind(conversation, to: statement, at: 1)
                if let context { try bind(JSONEncoder().encode(context.bounded()), to: statement, at: 2) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
            }
            for message in messages {
                let statement = try prepare("INSERT INTO messages(conversation, id, payload) VALUES(?, ?, ?) ON CONFLICT(conversation, id) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(statement) }
                bind(conversation, to: statement, at: 1); bind(message.id.uuidString, to: statement, at: 2)
                try bind(JSONEncoder().encode(message), to: statement, at: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
            }
            if let draft {
                let statement = try prepare(draft.isEmpty ? "DELETE FROM drafts WHERE conversation = ?" : "INSERT INTO drafts(conversation, payload) VALUES(?, ?) ON CONFLICT(conversation) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(statement) }
                bind(conversation, to: statement, at: 1)
                if !draft.isEmpty { try bind(Data(draft.utf8), to: statement, at: 2) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
            }
        }
    }
    func remove(_ messageID: UUID) throws {
        try transaction {
            try recordDeletion(conversation, ids: [messageID])
            let statement = try prepare("DELETE FROM messages WHERE conversation = ? AND id = ?")
            defer { sqlite3_finalize(statement) }
            bind(conversation, to: statement, at: 1); bind(messageID.uuidString, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
        }
    }
    func clear() throws {
        try transaction {
            // Other devices must remove these messages too, not bring them back.
            try recordDeletion(conversation, ids: messageIDs(conversation))
            for table in ["messages", "drafts", "selected_drafts"] {
                let statement = try prepare("DELETE FROM \(table) WHERE conversation = ?")
                defer { sqlite3_finalize(statement) }
                bind(conversation, to: statement, at: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
            }
        }
        // Discard old WAL pages too; failures here do not undo the committed clear.
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
    // MARK: iCloud sync

    /// Every conversation with messages or deletions on this device.
    func conversations() throws -> [String] {
        let statement = try prepare("SELECT DISTINCT conversation FROM messages UNION SELECT DISTINCT conversation FROM deleted_messages")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        }
        return result
    }
    /// A conversation's messages in order, with the messages deleted from it.
    func export(_ conversation: String) throws -> SyncedConversation {
        let statement = try prepare("SELECT payload FROM messages WHERE conversation = ? ORDER BY sequence ASC")
        defer { sqlite3_finalize(statement) }
        bind(conversation, to: statement, at: 1)
        var messages: [ReaderChatMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0),
                  let message = try? JSONDecoder().decode(ReaderChatMessage.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))) else { continue }
            messages.append(message)
        }
        let deletions = try prepare("SELECT id, deleted_at FROM deleted_messages WHERE conversation = ?")
        defer { sqlite3_finalize(deletions) }
        bind(conversation, to: deletions, at: 1)
        var deleted: [UUID: Date] = [:]
        while sqlite3_step(deletions) == SQLITE_ROW {
            if let text = sqlite3_column_text(deletions, 0), let id = UUID(uuidString: String(cString: text)) {
                deleted[id] = Date(timeIntervalSince1970: sqlite3_column_double(deletions, 1))
            }
        }
        return SyncedConversation(conversation: conversation, messages: messages, deleted: deleted)
    }
    /// Applies a merged conversation: deletions are removed here, messages
    /// this device lacks are appended in order, and finished replies replace
    /// copies saved mid-stream. Local messages are never reordered.
    func adopt(_ synced: SyncedConversation) throws {
        let local = try export(synced.conversation)
        try transaction {
            let newlyDeleted = synced.deleted.filter { local.deleted[$0.key] == nil }
            for (id, date) in newlyDeleted {
                let statement = try prepare("INSERT OR IGNORE INTO deleted_messages(conversation, id, deleted_at) VALUES(?, ?, ?)")
                defer { sqlite3_finalize(statement) }
                bind(synced.conversation, to: statement, at: 1); bind(id.uuidString, to: statement, at: 2)
                sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
                let remove = try prepare("DELETE FROM messages WHERE conversation = ? AND id = ?")
                defer { sqlite3_finalize(remove) }
                bind(synced.conversation, to: remove, at: 1); bind(id.uuidString, to: remove, at: 2)
                guard sqlite3_step(remove) == SQLITE_DONE else { throw ChatHistoryError.write }
            }
            for message in synced.messages {
                guard synced.deleted[message.id] == nil else { continue }
                let existing = local.messages.first { $0.id == message.id }
                if let existing, existing == message || existing.state != .streaming { continue }
                let statement = try prepare("INSERT INTO messages(conversation, id, payload) VALUES(?, ?, ?) ON CONFLICT(conversation, id) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(statement) }
                bind(synced.conversation, to: statement, at: 1); bind(message.id.uuidString, to: statement, at: 2)
                try bind(JSONEncoder().encode(message), to: statement, at: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
            }
        }
    }
    private func messageIDs(_ conversation: String) throws -> [UUID] {
        let statement = try prepare("SELECT id FROM messages WHERE conversation = ?")
        defer { sqlite3_finalize(statement) }
        bind(conversation, to: statement, at: 1)
        var ids: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) { ids.append(id) }
        }
        return ids
    }
    private func recordDeletion(_ conversation: String, ids: [UUID]) throws {
        let now = Date().timeIntervalSince1970
        for id in ids {
            let statement = try prepare("INSERT OR REPLACE INTO deleted_messages(conversation, id, deleted_at) VALUES(?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(conversation, to: statement, at: 1); bind(id.uuidString, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, now)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ChatHistoryError.write }
        }
    }

    private func exists(_ condition: String, cursor: Int64) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM messages WHERE conversation = ? AND \(condition) LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(conversation, to: statement, at: 1); sqlite3_bind_int64(statement, 2, cursor)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw ChatHistoryError.unreadable }
        return result == SQLITE_ROW
    }
    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ChatHistoryError.write }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ChatHistoryError.unreadable }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
    }
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
        guard result == SQLITE_OK else { throw ChatHistoryError.write }
    }
}
