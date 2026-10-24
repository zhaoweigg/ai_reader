import SwiftUI

enum BookAnnotationColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hex: String {
        switch self {
        case .yellow: return "#F2C94C"
        case .green: return "#69C58C"
        case .blue: return "#6DAEF0"
        case .pink: return "#E994B4"
        }
    }
    var color: Color {
        switch self {
        case .yellow: return Color(red: 0.95, green: 0.79, blue: 0.30)
        case .green: return Color(red: 0.41, green: 0.77, blue: 0.55)
        case .blue: return Color(red: 0.43, green: 0.68, blue: 0.94)
        case .pink: return Color(red: 0.91, green: 0.58, blue: 0.71)
        }
    }
}

struct PDFAnnotationRange: Codable, Equatable {
    let page: Int
    let location: Int
    let length: Int
    var valid: Bool { page >= 0 && page < 100_000 && location >= 0 && length > 0 && location <= Int.max - length }
}

struct BookAnnotationSelection: Equatable {
    let text: String
    let locator: String
    let chapter: String
    let fraction: Double
    var pdfRanges: [PDFAnnotationRange] = []
    func annotation() -> BookAnnotation {
        BookAnnotation(text: text, locator: locator, chapter: chapter, fraction: fraction, pdfRanges: pdfRanges)
    }
}

struct BookAnnotation: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var locator: String
    var chapter: String
    var fraction: Double
    var pdfRanges: [PDFAnnotationRange] = []
    var color: BookAnnotationColor = .yellow
    var note = ""
    var createdAt = Date()
    var updatedAt = Date()
    var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var valid: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 12_000,
              note.count <= 20_000, chapter.count <= 300, locator.count <= 8_000,
              fraction.isFinite, (0...1).contains(fraction) else { return false }
        if pdfRanges.isEmpty { return locator.hasPrefix("epubcfi(") && locator.hasSuffix(")") }
        return pdfRanges.count <= 128 && pdfRanges.allSatisfy(\.valid) && locator == PDFLocator.page(pdfRanges[0].page)
    }
    func matches(_ selection: BookAnnotationSelection) -> Bool {
        locator == selection.locator && pdfRanges == selection.pdfRanges
    }
    var webPayload: [String: Any] { ["id": id.uuidString, "value": locator, "color": color.hex, "hasNote": hasNote] }
}

enum BookAnnotationError: LocalizedError {
    case selection, noteTooLong, unavailable
    var errorDescription: String? {
        switch self {
        case .selection: return "Select a passage of up to 12,000 characters before adding a highlight or note."
        case .noteTooLong: return "Keep this note under 20,000 characters."
        case .unavailable: return "This book could not be updated. Your saved passages have been kept."
        }
    }
}
