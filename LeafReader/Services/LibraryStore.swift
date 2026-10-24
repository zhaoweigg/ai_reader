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
                try await commit(imported, on: disk)
                importCount += 1
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        isImporting = false
        if !failures.isEmpty {
            notice = LibraryNotice(title: importCount > 0 ? "Imported \(importCount) book\(importCount == 1 ? "" : "s")" : "Could not import", message: failures.joined(separator: "\n\n"))
        }
    }

    func importCatalogBook(_ source: URL, catalogID: String, title: String, author: String) async throws -> Book {
        if let existing = books.first(where: { $0.catalogSource == catalogID }) { return existing }
        guard !isImporting else { throw ZLibraryError.busy }
        guard canSave, let disk else { throw LibraryError.unavailable }
        isImporting = true; importCount = 0
        defer { isImporting = false }
        let existing = Set(books.map(\.fingerprint))
        let imported: Book
        do {
            imported = try await Task.detached(priority: .userInitiated) { try disk.prepareImport(source, existing: existing) }.value
        } catch LibraryError.duplicate {
            let fingerprint = try await Task.detached(priority: .userInitiated) { try LibraryDisk.fingerprint(source) }.value
            guard let book = books.first(where: { $0.fingerprint == fingerprint }) else { throw LibraryError.duplicate }
            // A book previously added from Files keeps its position, bookmarks, and chat fingerprint.
            var updated = books; let index = updated.firstIndex(where: { $0.id == book.id })!
            updated[index].catalogSource = catalogID
            try disk.save(updated); books = updated
            return updated[index]
        }
        var book = imported
        book.catalogSource = catalogID
        if !title.isEmpty { book.title = title }
        if !author.isEmpty { book.author = author }
        try await commit(book, on: disk)
        importCount = 1
        return self.book(book.id) ?? book
    }

    /// Publishes a prepared import only after the manifest holds it; a failed
    /// manifest write removes the copied files again. Metadata loads afterwards.
    private func commit(_ book: Book, on disk: LibraryDisk) async throws {
        do { try disk.save(books + [book]); books.append(book) }
        catch { try? disk.removeFiles(book); throw error }
        await refreshMetadata(book.id)
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
    func saveAnnotation(_ annotation: BookAnnotation, bookID: UUID) throws {
        guard annotation.note.count <= 20_000 else { throw BookAnnotationError.noteTooLong }
        guard annotation.valid else { throw BookAnnotationError.selection }
        guard let book = book(bookID), (book.format == .pdf) == !annotation.pdfRanges.isEmpty else { throw BookAnnotationError.selection }
        try changeAnnotations(bookID) { annotations in
            if let index = annotations.firstIndex(where: { $0.id == annotation.id }) { annotations[index] = annotation }
            else if let index = annotations.firstIndex(where: { $0.locator == annotation.locator && $0.pdfRanges == annotation.pdfRanges }) {
                var replacement = annotation
                replacement.id = annotations[index].id; replacement.createdAt = annotations[index].createdAt
                annotations[index] = replacement
            }
            else { annotations.append(annotation) }
        }
    }
    func removeAnnotation(_ annotationID: UUID, bookID: UUID) throws {
        try changeAnnotations(bookID) { $0.removeAll { $0.id == annotationID } }
    }
    private func changeAnnotations(_ bookID: UUID, change: (inout [BookAnnotation]) -> Void) throws {
        guard canSave, let disk, let index = books.firstIndex(where: { $0.id == bookID }) else { throw BookAnnotationError.unavailable }
        var updated = books
        change(&updated[index].annotations)
        // Publish only after an atomic disk write succeeds, including pending reading progress.
        try disk.save(updated)
        books = updated
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
