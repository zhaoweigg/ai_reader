import SwiftUI
import Translation

/// A selected passage the reader asked the system to translate.
struct ReaderTranslationRequest: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

enum ReaderTranslation {
    /// The system translation sheet arrived with iOS 17.4; earlier systems get no Translate action.
    static var isAvailable: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }
    /// The palette's symbol, with a stand-in for a system that lacks the translate glyph.
    static var symbol: String { UIImage(systemName: "translate") == nil ? "character.bubble" : "translate" }
    /// The passage as the sheet should receive it, or nil when nothing readable is selected.
    /// A selection across PDF rows carries a hard line break per row, which a
    /// translator reads as a sentence end, so a single break becomes a space
    /// (nothing between two CJK characters). A blank line still separates paragraphs.
    static func passage(_ selection: String?) -> String? {
        guard let selection else { return nil }
        var paragraphs: [String] = [], current = "", gap = "", last: Character?
        for character in selection {
            if character.isWhitespace { gap.append(character); continue }
            let breaks = gap.filter(\.isNewline).count
            if breaks >= 2 {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""; last = nil
            } else if let last, !gap.isEmpty, !(breaks == 1 && isCJK(last) && isCJK(character)) {
                current.append(" ")
            }
            gap = ""; current.append(character); last = character
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
    }
    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x2E80...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) || (0xFF00...0xFFEF).contains(value)
    }
}

/// Presents Apple's translation sheet for the reader's request. The sheet is the
/// system's own: it translates on the device, offers the language choice and
/// downloads, and never changes the book.
struct ReaderTranslationSheet: ViewModifier {
    @Binding var request: ReaderTranslationRequest?
    func body(content: Content) -> some View {
        #if DEBUG
        if UITesting.flag(.translationProbe) { content.overlay(alignment: .top) { probe } } else { sheet(content) }
        #else
        sheet(content)
        #endif
    }
    @ViewBuilder private func sheet(_ content: Content) -> some View {
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                                            text: request?.text ?? "")
        } else {
            content
        }
    }
    #if DEBUG
    /// The simulator cannot be relied on to show the system sheet, so UI tests
    /// read the request here instead; tapping it stands in for closing the sheet.
    @ViewBuilder private var probe: some View {
        if let request {
            Button("Translation request") { self.request = nil }
                .font(.caption).padding(8).background(.thinMaterial, in: Capsule()).padding(.top, 8)
                .accessibilityIdentifier("readerTranslationProbe").accessibilityValue(request.text)
        }
    }
    #endif
}
