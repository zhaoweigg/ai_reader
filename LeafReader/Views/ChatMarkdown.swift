import SwiftUI

/// Keep the stored reply unchanged; formatting belongs only to its presentation.
enum ChatMarkdown {
    /// Bridge semantic Markdown explicitly: SwiftUI Font attributes do not
    /// become UIFont attributes in a UITextView. Ranges use UTF-16, as UIKit does.
    static func selectableText(_ source: String, markdown: Bool = true, traits: UITraitCollection? = nil) -> NSAttributedString {
        let rendered = markdown ? render(source) : AttributedString(source)
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        for run in rendered.runs {
            let inline = run.inlinePresentationIntent
            let components = run.presentationIntent?.components ?? []
            let code = inline?.contains(.code) == true || components.contains { if case .codeBlock = $0.kind { return true }; return false }
            let heading = components.contains { if case .header = $0.kind { return true }; return false }
            let base = UIFont.preferredFont(forTextStyle: heading ? .headline : .subheadline, compatibleWith: traits)
            let font = code ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
            var fontTraits = font.fontDescriptor.symbolicTraits
            if inline?.contains(.stronglyEmphasized) == true { fontTraits.insert(.traitBold) }
            if inline?.contains(.emphasized) == true { fontTraits.insert(.traitItalic) }
            let descriptor = font.fontDescriptor.withSymbolicTraits(fontTraits) ?? font.fontDescriptor
            var attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(descriptor: descriptor, size: font.pointSize),
                .foregroundColor: UIColor.label, .paragraphStyle: paragraph
            ]
            if let link = run.link { attributes[.link] = link }
            if inline?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: String(rendered[run.range].characters), attributes: attributes))
        }
        return result
    }

    static func render(_ source: String) -> AttributedString {
        guard let strict = try? AttributedString(markdown: source) else { return AttributedString(source) }
        let parsed = tolerateBoldMarkers(strict)
        var result = AttributedString()
        var previousList: Int?
        var previousItem: Int?
        for (intent, range) in parsed.runs[\.presentationIntent] {
            var block = AttributedString(parsed[range])
            let components = intent?.components ?? []
            var heading: Int?
            var codeBlock = false
            var quoted = false
            var list: Int?
            var item: Int?
            var ordinal = 1
            var ordered = false
            var depth = 0
            for component in components {
                switch component.kind {
                case .header(level: let level): heading = level
                case .codeBlock: codeBlock = true
                case .blockQuote: quoted = true
                case .listItem(ordinal: let value):
                    // Components start at the innermost block.
                    if item == nil { item = component.identity; ordinal = value }
                case .orderedList, .unorderedList:
                    if list == nil {
                        list = component.identity
                        if case .orderedList = component.kind { ordered = true }
                    }
                    depth += 1
                default: break
                }
            }
            // The parser removes block separators and list markers. Restore them
            // explicitly rather than letting headings and paragraphs run together.
            if !result.characters.isEmpty {
                result += AttributedString(list != nil && list == previousList ? "\n" : "\n\n")
            }
            if let item, item != previousItem {
                result += AttributedString(String(repeating: "  ", count: max(0, depth - 1)) + (ordered ? "\(ordinal). " : "• "))
            }
            if quoted { result += AttributedString("▎ ") }
            for run in block.runs {
                if codeBlock || run.inlinePresentationIntent?.contains(.code) == true {
                    block[run.range].font = .system(.subheadline, design: .monospaced)
                } else if let heading {
                    block[run.range].font = heading <= 2 ? .headline : .subheadline.bold()
                }
            }
            // Fenced code includes a terminal newline, unlike other blocks.
            if codeBlock, block.characters.last == "\n" {
                block.removeSubrange(block.characters.index(before: block.endIndex)..<block.endIndex)
            }
            result += block
            previousList = list
            previousItem = item
        }
        return result
    }

    /// Models often write bold the way people do, not the way CommonMark reads it:
    /// "**标题：**内容" (closer glued to punctuation), "名称。 **下一句" (space before
    /// the closer) or "** 词**" (space after the opener). The parser's flanking rules
    /// reject those pairs and leave the asterisks in the reply. Whatever `**` survived
    /// parsing outside code is therefore paired up within its paragraph and the text
    /// between is bolded; an unmatched marker (a reply still streaming) stays literal.
    static func tolerateBoldMarkers(_ parsed: AttributedString) -> AttributedString {
        let characters = parsed.characters
        var pairs: [(open: Int, close: Int)] = []
        for (intent, block) in parsed.runs[\.presentationIntent] {
            if intent?.components.contains(where: { if case .codeBlock = $0.kind { return true }; return false }) == true { continue }
            var markers: [Int] = []
            for run in parsed[block].runs where run.inlinePresentationIntent?.contains(.code) != true {
                var index = run.range.lowerBound
                let offset = characters.distance(from: characters.startIndex, to: index)
                var position = offset
                while index < run.range.upperBound {
                    guard characters[index] == "*" else { index = characters.index(after: index); position += 1; continue }
                    var end = index, count = 0
                    while end < run.range.upperBound, characters[end] == "*" { end = characters.index(after: end); count += 1 }
                    // Exactly two asterisks form a bold marker; longer runs are left alone.
                    if count == 2 { markers.append(position) }
                    index = end; position += count
                }
            }
            var pending: Int?
            for marker in markers {
                if let open = pending, marker > open + 2 { pairs.append((open, marker)); pending = nil }
                else { pending = marker }
            }
        }
        guard !pairs.isEmpty else { return parsed }
        var result = parsed
        // Later pairs first, so earlier character offsets stay valid after removals.
        for pair in pairs.reversed() {
            var text = result.characters
            let openStart = text.index(text.startIndex, offsetBy: pair.open), openEnd = text.index(openStart, offsetBy: 2)
            let closeStart = text.index(text.startIndex, offsetBy: pair.close)
            for run in result[openEnd..<closeStart].runs {
                var intent = run.inlinePresentationIntent ?? []
                intent.insert(.stronglyEmphasized)
                result[run.range].inlinePresentationIntent = intent
            }
            text = result.characters
            let closeLower = text.index(text.startIndex, offsetBy: pair.close)
            result.removeSubrange(closeLower..<text.index(closeLower, offsetBy: 2))
            text = result.characters
            let openLower = text.index(text.startIndex, offsetBy: pair.open)
            result.removeSubrange(openLower..<text.index(openLower, offsetBy: 2))
        }
        return result
    }
}
