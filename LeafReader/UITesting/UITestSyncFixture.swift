#if DEBUG
import Foundation
import UIKit

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
            if UITesting.flag(.syncOtherDevice) { imitateOtherDevice(in: folder) }
            return folder.root
        } catch { return nil }
    }

    /// Each time the app leaves the foreground, another device changes shared
    /// settings in the folder: first the AI model, then the model again together
    /// with the quick prompts. The sync on return brings them into the open app.
    private static func imitateOtherDevice(in folder: SyncFolder) {
        otherDevice = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            otherDeviceEdits += 1
            var configuration = ChatConfiguration()
            configuration.profile.model = otherDeviceEdits == 1 ? "claude-haiku-4-5" : "claude-opus-5-5"
            do {
                var stored = ["ai.configuration": try JSONEncoder().encode(configuration)]
                if otherDeviceEdits > 1 {
                    let prompts = ChatQuickPrompt.defaults + [ChatQuickPrompt(title: "Words", prompt: "List the hard words.")]
                    stored["chat.quickPrompts"] = try JSONEncoder().encode(prompts)
                }
                var settings = SyncedSettings()
                for (key, value) in stored {
                    // The same wrapping the app gives a stored value.
                    let data = try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
                    settings.values[key] = .init(data: data, updatedAt: Date())
                }
                try JSONEncoder().encode(settings).write(to: folder.settings, options: .atomic)
            } catch {}
        }
    }
    private static var otherDeviceEdits = 0
    private static var otherDevice: NSObjectProtocol?
}
#endif
