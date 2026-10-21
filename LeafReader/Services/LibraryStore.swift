import SwiftUI
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published var notice: LibraryNotice?
    @Published private(set) var isImporting = false
    @Published private(set) var importCount = 0
    private(set) var disk: LibraryDisk?
    private var canSave = false
    private var saveTask: Task<Void, Never>?
    private let metadataLoader: (Book, URL) async throws -> BookMetadata
    private var metadataTasks: [UUID: Task<Void, Never>] = [:]

    init(root: URL? = nil, seedSamples: Bool = true,
         metadataLoader: @escaping (Book, URL) async throws -> BookMetadata = { book, url in try await BookMetadataLoader.load(book, from: url) }) {
        self.metadataLoader = metadataLoader
        do {
            let storage = try LibraryDisk(root: root)
            disk = storage
            if let existing = try storage.load() {
                books = existing
                canSave = true
            } else {
                canSave = true
                if seedSamples { try installSamples(storage) }
                try storage.save(books)
            }
        } catch {
            notice = LibraryNotice(title: "Library could not be loaded", message: "Your existing files have been kept. \(error.localizedDescription)")
        }
    }

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }
    func fileURL(_ book: Book) -> URL? { disk?.fileURL(book) }
    func coverURL(_ book: Book) -> URL? { book.coverFileName.flatMap { disk?.coversDirectory.appendingPathComponent($0) } }

    func importBooks(_ urls: [URL]) async {
        guard !isImporting, canSave, let disk else {
            if !canSave { notice = LibraryNotice(title: "Library unavailable", message: "Restart the app to try loading your library again.") }
            return
        }
        isImporting = true
        importCount = 0
        var failures: [String] = []
        for url in urls {
            let existing = Set(books.map(\.fingerprint))
            do {
                let imported = try await Task.detached(priority: .userInitiated) { try disk.prepareImport(url, existing: existing) }.value
                do {
                    try disk.save(books + [imported])
                    books.append(imported)
                    await refreshMetadata(imported.id)
                    importCount += 1
                } catch {
                    try? disk.removeFiles(imported)
                    throw error
                }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        isImporting = false
        if !failures.isEmpty {
            notice = LibraryNotice(title: importCount > 0 ? "Imported \(importCount) book\(importCount == 1 ? "" : "s")" : "Could not import", message: failures.joined(separator: "\n\n"))
        }
    }

    func refreshMissingMetadata() async {
        guard canSave else { return }
        for book in books where needsMetadata(book) { await refreshMetadata(book.id) }
    }

    private func needsMetadata(_ book: Book) -> Bool {
        guard book.format.hasLibraryArtwork else { return false }
        if let url = coverURL(book), FileManager.default.fileExists(atPath: url.path) { return false }
        return book.metadataVersion != BookMetadataLoader.version || book.coverFileName != nil
    }

    private func refreshMetadata(_ id: UUID) async {
        if let pending = metadataTasks[id] { await pending.value; return }
        guard let book = book(id), needsMetadata(book), let url = fileURL(book) else { return }
        let loader = metadataLoader
        let task = Task { [weak self] in
            do {
                let metadata = try await loader(book, url)
                guard !Task.isCancelled, let self, self.book(id)?.fingerprint == book.fingerprint else { return }
                self.setMetadata(id, title: metadata.title, author: metadata.author, cover: metadata.cover)
                self.update(id, { $0.metadataVersion = BookMetadataLoader.version }, immediately: true)
            } catch { /* Keep the imported book and its placeholder if metadata is unavailable. */ }
        }
        metadataTasks[id] = task
        await task.value
        metadataTasks[id] = nil
    }

    private func installSamples(_ disk: LibraryDisk) throws {
        let samples: [(String, String, String)] = [
            ("The Art of Noticing.epub", "The Art of Noticing", "Leaf Editions"),
            ("A Short History of Stars.fb2", "A Short History of Stars", "Mira Ellis"),
            ("Notes from the Coast.pdf", "Notes from the Coast", "Rowan Hale"),
            ("A Field Guide to Slow Days.txt", "A Field Guide to Slow Days", "Leaf Editions")
        ]
        for (file, title, author) in samples {
            guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Samples") else { continue }
            var book = try disk.prepareImport(url, existing: Set(books.map(\.fingerprint)))
            book.title = title
            book.author = author
            books.append(book)
        }
    }

    func update(_ id: UUID, _ change: (inout Book) -> Void, immediately: Bool = false) {
        guard canSave, let index = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[index])
        if immediately { flush() } else { scheduleSave() }
    }
    func open(_ id: UUID) { update(id, { $0.lastOpenedAt = Date() }, immediately: true) }
    func setPosition(_ id: UUID, locator: String, fraction: Double) {
        update(id) { book in
            book.locator = locator
            book.progress = min(1, max(0, fraction.isFinite ? fraction : 0))
        }
    }
    func setMetadata(_ id: UUID, title: String?, author: String?, cover: Data?) {
        update(id) { book in
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { book.title = title }
            if let author, !author.isEmpty { book.author = author }
            if let cover, cover.count < 8 * 1024 * 1024, let image = UIImage(data: cover), let png = image.pngData(), let disk {
                let name = id.uuidString + ".png"
                do {
                    try png.write(to: disk.coversDirectory.appendingPathComponent(name), options: .atomic)
                    book.coverFileName = name
                } catch { /* A missing cover must not interrupt reading. */ }
            }
        }
    }
    func toggleFavorite(_ id: UUID) { update(id, { $0.isFavorite.toggle() }, immediately: true) }
    func toggleBookmark(_ id: UUID, locator: String, fraction: Double, label: String) {
        guard !locator.isEmpty else { return }
        update(id, { book in
            if let index = book.bookmarks.firstIndex(where: { $0.locator == locator }) { book.bookmarks.remove(at: index) }
            else { book.bookmarks.append(BookBookmark(label: label, locator: locator, fraction: fraction)) }
        }, immediately: true)
    }
    func removeBookmark(_ bookID: UUID, bookmarkID: UUID) {
        update(bookID, { $0.bookmarks.removeAll { $0.id == bookmarkID } }, immediately: true)
    }
    func remove(_ id: UUID) {
        guard canSave, let disk, let book = book(id) else { return }
        let remaining = books.filter { $0.id != id }
        do {
            try disk.save(remaining)
            books = remaining
            metadataTasks.removeValue(forKey: id)?.cancel()
            try disk.removeFiles(book)
        } catch { notice = LibraryNotice(title: "Could not remove book", message: error.localizedDescription) }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        saveTask?.cancel()
        guard canSave, let disk else { return }
        do { try disk.save(books) }
        catch { notice = LibraryNotice(title: "Reading position could not be saved", message: error.localizedDescription) }
    }
}
