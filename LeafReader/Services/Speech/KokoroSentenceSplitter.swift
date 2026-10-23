import Foundation

/// One spoken unit of a passage: the text handed to the synthesizer and its
/// UTF-16 range inside the passage, so playback progress maps back to the
/// reader's highlight and bookmark offsets.
struct KokoroSentence: Equatable {
    let text: String
    let range: NSRange
}

/// Splits passage text into short chunks for streaming synthesis: whole
/// sentences when they are short, otherwise clauses cut at commas or spaces.
/// Chunk size bounds both first-audio latency (a chunk must finish synthesizing
/// before it can play) and progress precision (ranges are exact only at chunk
/// boundaries). Kokoro's Chinese front end spends roughly ten phoneme tokens per
/// character, so Chinese chunks stay well under the English limit; 48 Chinese
/// characters took about 3 s to synthesize on a 2-thread Mac run.
enum KokoroSentenceSplitter {
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

    static func split(_ text: String) -> [KokoroSentence] {
        let units = Array(text.utf16)
        var sentences: [KokoroSentence] = []
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
                    sentences.append(KokoroSentence(text: piece, range: NSRange(location: first, length: last - first)))
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
                var cut = index
                while cut > start + limit / 3, !(softBreaks.contains(units[cut]) || isSpace(units[cut])) { cut -= 1 }
                if cut <= start + limit / 3 { cut = index }
                flush(cut + 1); index = cut + 1; continue
            }
            index += 1
        }
        flush(units.count)
        return sentences
    }
}
