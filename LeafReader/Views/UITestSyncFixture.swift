#if DEBUG
import Foundation

/// A sync folder that another device has already filled: one sample book with
/// a reading position and a note, and its file waiting in Books/. UI tests use
/// it to check how a new device lists and downloads a synced library.
enum UITestSyncFixture {
    static func seed(next root: URL) -> URL? {
        let folder = SyncFolder(root: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-iCloud", isDirectory: true))
        guard let source = Bundle.main.url(forResource: "A Field Guide to Slow Days.txt", withExtension: nil, subdirectory: "Samples"),
              let fingerprint = try? LibraryDisk.fingerprint(source) else { return nil }
        do {
            try folder.prepare()
            var book = Book(id: UUID(), title: "A Field Guide to Slow Days", author: "Leaf Editions",
                            fileName: "", format: .txt, fingerprint: fingerprint)
            book.lastOpenedAt = Date(); book.progress = 0.4; book.positionUpdatedAt = Date()
            let destination = folder.books.appendingPathComponent(fingerprint + ".txt")
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
            try JSONEncoder().encode(SyncedBook(book)).write(to: folder.library.appendingPathComponent(fingerprint + ".json"))
            return folder.root
        } catch { return nil }
    }
}
#endif
