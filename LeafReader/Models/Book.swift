import Foundation

// Formats are deliberately explicit: unsupported or encrypted books are never silently converted.
enum BookFormat: String, Codable, CaseIterable, Identifiable {
    case epub, pdf, mobi, azw, azw3, prc, fb2, fbz, cbz, txt, md, html, rtf
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var isWebBook: Bool { self != .pdf }
    var hasLibraryArtwork: Bool { ![BookFormat.txt, .md, .html, .rtf].contains(self) }
    static func detect(_ url: URL) -> BookFormat? {
        if url.lastPathComponent.lowercased().hasSuffix(".fb2.zip") { return .fbz }
        switch url.pathExtension.lowercased() {
        case "htm": return .html
        case "markdown": return .md
        default: return BookFormat(rawValue: url.pathExtension.lowercased())
        }
    }
    static let summary = "EPUB, PDF, MOBI, AZW, AZW3, PRC, FB2, FBZ, CBZ, TXT, Markdown, HTML, and RTF"
}

struct BookBookmark: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var locator: String
    var fraction: Double
    var createdAt = Date()
}

struct Book: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var author: String
    var fileName: String
    var format: BookFormat
    var fingerprint: String
    var importedAt = Date()
    var lastOpenedAt: Date?
    var progress: Double = 0
    var locator: String = ""
    var coverFileName: String?
    var metadataVersion: Int?
    var catalogSource: String?
    var isFavorite = false
    var bookmarks: [BookBookmark] = []
    var annotations: [BookAnnotation] = []
    var isFinished: Bool { progress >= 0.995 }
    var progressLabel: String { isFinished ? "Finished" : "\(Int(progress * 100))% read" }
    var paletteIndex: Int { Int(fingerprint.prefix(4), radix: 16).map { $0 % 5 } ?? 0 }
}

extension Book {
    // New annotations must not make libraries saved by earlier versions unreadable.
    private enum CodingKeys: String, CodingKey {
        case id, title, author, fileName, format, fingerprint, importedAt, lastOpenedAt
        case progress, locator, coverFileName, metadataVersion, catalogSource, isFavorite, bookmarks, annotations
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        author = try values.decode(String.self, forKey: .author)
        fileName = try values.decode(String.self, forKey: .fileName)
        format = try values.decode(BookFormat.self, forKey: .format)
        fingerprint = try values.decode(String.self, forKey: .fingerprint)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        lastOpenedAt = try values.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        progress = try values.decode(Double.self, forKey: .progress)
        locator = try values.decode(String.self, forKey: .locator)
        coverFileName = try values.decodeIfPresent(String.self, forKey: .coverFileName)
        metadataVersion = try values.decodeIfPresent(Int.self, forKey: .metadataVersion)
        catalogSource = try values.decodeIfPresent(String.self, forKey: .catalogSource)
        isFavorite = try values.decode(Bool.self, forKey: .isFavorite)
        bookmarks = try values.decode([BookBookmark].self, forKey: .bookmarks)
        annotations = try values.decodeIfPresent([BookAnnotation].self, forKey: .annotations) ?? []
    }
}

struct Chapter: Identifiable, Equatable {
    var id: String { tocID ?? href }
    let label: String
    let href: String
    var depth: Int = 0
    // A volume and its first chapter can share an href; TOC identity stays unique.
    var tocID: String? = nil
}

struct BookSearchResult: Identifiable {
    let id = UUID()
    let label: String
    let excerpt: String
    let locator: String
}

struct LibraryNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum LibraryError: LocalizedError {
    case unsupported(String), tooLarge, empty, unavailable, invalidPDF, unsafePath, duplicate
    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "\(name) is not a supported book. Choose \(BookFormat.summary)."
        case .tooLarge: return "This book is larger than 100 MB. Import a smaller copy to keep reading responsive."
        case .empty: return "This file is empty. Download the book again and try importing it."
        case .unavailable: return "The book file could not be found. Remove this entry and import the book again."
        case .invalidPDF: return "This file could not be opened as a PDF. Check that the download is complete."
        case .unsafePath: return "The file path could not be opened."
        case .duplicate: return "This book is already in your library."
        }
    }
}
