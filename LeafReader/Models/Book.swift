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
    var isFinished: Bool { progress >= 0.995 }
    var progressLabel: String { isFinished ? "Finished" : "\(Int(progress * 100))% read" }
    var paletteIndex: Int { Int(fingerprint.prefix(4), radix: 16).map { $0 % 5 } ?? 0 }
}

struct Chapter: Identifiable, Equatable {
    var id: String { href }
    let label: String
    let href: String
    var depth: Int = 0
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
