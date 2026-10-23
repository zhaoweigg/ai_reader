import Foundation
import WebKit
import PDFKit

@MainActor extension ReaderModel {
    func highlightReadAloud(_ passage: ReadAloudPassage?, range: NSRange, follow: Bool) {
        if let pdfView {
            guard let passage, let cursor = PDFReadAloudSource.cursor(passage.locator),
                  let page = pdfView.document?.page(at: cursor.page), range.location != NSNotFound,
                  let selection = page.selection(for: NSRange(location: cursor.offset + range.location, length: range.length)) else {
                pdfView.highlightedSelections = nil
                return
            }
            selection.color = UIColor.systemYellow.withAlphaComponent(0.48)
            pdfView.highlightedSelections = [selection]
            let bounds = selection.bounds(for: page)
            if follow, !pdfView.bounds.insetBy(dx: 0, dy: 8).contains(pdfView.convert(bounds, from: page)) {
                pdfView.go(to: bounds, on: page)
            }
            return
        }
        guard let webView else { spokenHighlightLocator = nil; spokenHighlightView = nil; return }
        guard let passage else {
            spokenHighlightLocator = nil; spokenHighlightView = nil
            webView.evaluateJavaScript("window.Leaf?.clearSpokenRange()", completionHandler: nil)
            return
        }
        var arguments: [String: Any] = ["passage": NSNull(), "locator": passage.locator, "location": range.location, "length": range.length, "follow": follow]
        if spokenHighlightLocator != passage.locator || spokenHighlightView != ObjectIdentifier(webView) {
            guard let data = try? JSONEncoder().encode(passage), let packet = try? JSONSerialization.jsonObject(with: data) else { return }
            arguments["passage"] = packet
            spokenHighlightLocator = passage.locator; spokenHighlightView = ObjectIdentifier(webView)
        }
        // Only the bounded passage map crosses the bridge once; subsequent word
        // callbacks send offsets. The renderer retains no detached DOM ranges.
        webView.callAsyncJavaScript("await window.Leaf.setSpokenRange({passage,locator,location,length,follow});",
            arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }
    func readAloudPassage(at position: String?) async throws -> ReadAloudPassage? {
        guard isReady, !isLocked, error == nil else { throw ReadAloudError.unavailable }
        if let pdfView, let document = pdfView.document {
            return try await PDFReadAloudSource.passage(in: document, at: position ?? visiblePDFListeningPosition())
        }
        guard let webView else { throw ReadAloudError.unavailable }
        let value = try await webView.callAsyncJavaScript("return await window.Leaf.readAloudChunk({locator});",
            arguments: ["locator": position ?? locator], in: nil, contentWorld: .page)
        guard !(value is NSNull), let dictionary = value as? [String: Any] else { return nil }
        return try JSONDecoder().decode(ReadAloudPassage.self, from: JSONSerialization.data(withJSONObject: dictionary))
    }
    func revealReadAloud(at position: String) async {
        guard isReady else { return }
        if let pdfView, let document = pdfView.document, let cursor = PDFReadAloudSource.cursor(position),
           let page = document.page(at: cursor.page) {
            let rect = page.characterBounds(at: min(cursor.offset, max(0, page.numberOfCharacters - 1)))
            if !rect.isEmpty { pdfView.go(to: rect, on: page) }
            else { pdfView.go(to: page) }
        } else if let webView {
            _ = try? await webView.callAsyncJavaScript("await window.Leaf.revealReadAloud({locator});",
                arguments: ["locator": position], in: nil, contentWorld: .page)
        }
    }
    func listeningSelectionPosition() -> String? {
        if let pdfView, let document = pdfView.document, let selection = pdfView.currentSelection,
           let page = selection.pages.first, selection.numberOfTextRanges(on: page) > 0 {
            let range = selection.range(at: 0, on: page)
            if range.location != NSNotFound { return "pdf:\(document.index(for: page)):\(range.location)" }
        }
        return selectedReadingContext()?.locator
    }
    func visiblePDFListeningPosition() -> String {
        guard let view = pdfView, let document = view.document, let page = view.currentPage else { return locator }
        let rect = view.convert(view.bounds, to: page).intersection(page.bounds(for: view.displayBox))
        let selection = page.selection(for: rect)
        let offset = selection.flatMap { $0.numberOfTextRanges(on: page) > 0 ? $0.range(at: 0, on: page).location : nil }
        return "pdf:\(document.index(for: page)):\(offset == NSNotFound ? 0 : offset ?? 0)"
    }
}

enum PDFReadAloudSource {
    static func cursor(_ position: String) -> (page: Int, offset: Int)? {
        let parts = position.split(separator: ":")
        guard parts.count >= 2, parts[0] == "pdf", let page = Int(parts[1]), page >= 0 else { return nil }
        let offset = parts.count > 2 ? Int(parts[2]) : 0
        guard let offset, offset >= 0 else { return nil }
        return (page, offset)
    }
    @MainActor static func passage(in document: PDFDocument, at position: String) async throws -> ReadAloudPassage? {
        guard let start = cursor(position), start.page < document.pageCount else { return nil }
        for index in start.page..<document.pageCount {
            try Task.checkCancellation()
            let text = (document.page(at: index)?.string ?? "") as NSString
            var offset = index == start.page ? min(start.offset, text.length) : 0
            while offset < text.length {
                var end = min(text.length, offset + 800)
                if end < text.length, CFStringIsSurrogateLowCharacter(text.character(at: end)) { end -= 1 }
                if end < text.length, end - offset > 400 {
                    let breaks = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?。！？"))
                    let boundary = text.rangeOfCharacter(from: breaks, options: .backwards,
                        range: NSRange(location: offset + 400, length: end - offset - 400))
                    if boundary.location != NSNotFound { end = NSMaxRange(boundary) }
                }
                let range = NSRange(location: offset, length: end - offset)
                let content = text.substring(with: range)
                let next = end == text.length ? "pdf:\(index + 1):0" : "pdf:\(index):\(end)"
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ReadAloudPassage(text: content, locator: "pdf:\(index):\(offset)", nextLocator: next,
                        language: "", label: "Page \(index + 1)")
                }
                offset = end
            }
            await Task.yield()
        }
        return nil
    }
}
