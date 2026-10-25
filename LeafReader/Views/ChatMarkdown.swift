import SwiftUI

/// Keep the stored reply unchanged; formatting belongs only to its presentation.
enum ChatMarkdown {
    static func render(_ source: String) -> AttributedString {
        guard let parsed = try? AttributedString(markdown: source) else { return AttributedString(source) }
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
}
