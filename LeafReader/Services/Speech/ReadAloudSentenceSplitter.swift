import Foundation

/// One spoken unit of a passage: the text handed to the synthesizer and its
/// UTF-16 range inside the passage, so playback progress maps back to the
/// reader's highlight and bookmark offsets.
struct ReadAloudSentence: Equatable {
    let text: String
    let range: NSRange
}

/// Sentence/clause boundaries keep Apple speech progress moving even when a
/// voice reports utterance starts without individual word ranges. UTF-16 offsets
/// stay relative to the original passage for highlighting and saved cursors.
enum ReadAloudSentenceSplitter {
    static let englishLimit = 160
    static let chineseLimit = 48
    private static let terminators: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x3B, 0x0A, 0x3002, 0xFF01, 0xFF1F, 0xFF1B, 0x2026]
    private static let softBreaks: Set<UInt16> = [0x2C, 0x3A, 0xFF0C, 0xFF1A, 0x3001, 0x2014, 0x2013]
    private static let closers: Set<UInt16> = [0x22, 0x27, 0x29, 0x5D, 0x201D, 0x2019, 0x300D, 0x300F, 0x300B, 0xFF09, 0x3011, 0x2026, 0x2E, 0x3002, 0xFF01, 0xFF1F, 0x21, 0x3F]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "vs", "etc", "eg", "ie", "no", "vol", "fig", "ch", "pp"]
    /// A period after an abbreviation or an initial (`Dr.`, `J. K.`, `a.m.`) does not end the sentence.
    private static func endsAbbreviation(_ units: [UInt16], before index: Int, start: Int) -> Bool {
        var wordStart = index
        while wordStart > start, let scalar = Unicode.Scalar(units[wordStart - 1]), scalar.properties.isAlphabetic { wordStart -= 1 }
        let length = index - wordStart
        guard length > 0, length <= 4 else { return false }
        if length == 1 { return true }
        let word = String(utf16CodeUnits: Array(units[wordStart..<index]), count: length).lowercased()
        return abbreviations.contains(word)
    }

    static func split(_ text: String) -> [ReadAloudSentence] {
        let units = Array(text.utf16)
        var sentences: [ReadAloudSentence] = []
        var start = 0
        var index = 0
        var han = 0
        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x3000 }
        func flush(_ end: Int) {
            var first = start, last = end
            while first < last, isSpace(units[first]) { first += 1 }
            while last > first, isSpace(units[last - 1]) { last -= 1 }
            if last > first {
                let piece = String(utf16CodeUnits: Array(units[first..<last]), count: last - first)
                if piece.unicodeScalars.contains(where: { $0.properties.isAlphabetic || $0.properties.numericType != nil }) {
                    sentences.append(ReadAloudSentence(text: piece, range: NSRange(location: first, length: last - first)))
                }
            }
            start = end; han = 0
        }
        while index < units.count {
            let unit = units[index]
            if (0x4E00...0x9FFF).contains(unit) || (0x3400...0x4DBF).contains(unit) { han += 1 }
            let length = index - start + 1
            let limit = han * 3 > length ? chineseLimit : englishLimit
            if terminators.contains(unit) {
                var end = index + 1
                while end < units.count, closers.contains(units[end]) { end += 1 }
                // Keep decimals, abbreviations and ellipses together.
                let continues = unit == 0x2E && end < units.count
                    && ((!isSpace(units[end]) && units[end] != 0x0A) || endsAbbreviation(units, before: index, start: start))
                if !continues, length >= 2 || unit == 0x0A { flush(end); index = end; continue }
            } else if length >= limit {
                // Prefer the last comma-like break in the latter two thirds of the
                // window, then the last space, then a hard cut.
                let floor = start + limit / 3
                var cut = index
                while cut > floor, !softBreaks.contains(units[cut]) { cut -= 1 }
                if cut <= floor {
                    cut = index
                    while cut > floor, !isSpace(units[cut]) { cut -= 1 }
                    if cut <= floor { cut = index }
                }
                flush(cut + 1); index = cut + 1; continue
            }
            index += 1
        }
        flush(units.count)
        return sentences
    }
}
