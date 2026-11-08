import Foundation
import CryptoKit
import PDFKit

struct LibraryDisk {
    let root: URL
    var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
    var coversDirectory: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    var voiceNotesDirectory: URL { root.appendingPathComponent("VoiceNotes", isDirectory: true) }
    var manifest: URL { root.appendingPathComponent("library.json") }

    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: voiceNotesDirectory, withIntermediateDirectories: true)
    }

    func load() throws -> [Book]? {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        return try JSONDecoder().decode([Book].self, from: Data(contentsOf: manifest))
    }

    func save(_ books: [Book]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(books).write(to: manifest, options: .atomic)
    }

    func fileURL(_ book: Book) -> URL { booksDirectory.appendingPathComponent(book.fileName) }

    func prepareImport(_ source: URL, existing: Set<String>) throws -> Book {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let format = BookFormat.detect(source) else { throw LibraryError.unsupported(source.lastPathComponent) }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw LibraryError.unavailable }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw LibraryError.empty }
        guard size <= 100 * 1024 * 1024 else { throw LibraryError.tooLarge }
        let fingerprint = try Self.fingerprint(source)
        guard !existing.contains(fingerprint) else { throw LibraryError.duplicate }
        let id = UUID()
        let fileName = id.uuidString + "." + format.rawValue
        let destination = booksDirectory.appendingPathComponent(fileName)
        var book = Book(id: id, title: source.deletingPathExtension().lastPathComponent,
                        author: "Unknown author", fileName: fileName, format: format, fingerprint: fingerprint)
        if format == .pdf {
            guard let document = PDFDocument(url: source) else { throw LibraryError.invalidPDF }
            if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { book.title = title }
            if let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { book.author = author }
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return book
    }

    static func fingerprint(_ source: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func removeFiles(_ book: Book) throws {
        let file = fileURL(book)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        if let name = book.coverFileName { try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(name)) }
    }
}
