import Foundation
import PDFKit

// Book text for the chat agent: EPUB/TXT/FB2 sections through the reader
// bridge, PDF pages through PDFKit. Offsets match between text and boundary.
extension ReaderModel: BookTextSource {
    func bookSectionCount() async throws -> Int {
        if let document = pdfView?.document { return document.pageCount }
        guard let webView else { throw CancellationError() }
        return (try await webView.evaluateJavaScript("window.Leaf.bookSectionCount()") as? NSNumber)?.intValue ?? 0
    }
    func bookSectionText(_ index: Int) async throws -> BookTextSection {
        if let document = pdfView?.document {
            guard let page = document.page(at: index) else { throw CancellationError() }
            return BookTextSection(label: "Page \(index + 1)", text: page.string ?? "")
        }
        guard let webView else { throw CancellationError() }
        let value = try await webView.callAsyncJavaScript("return await window.Leaf.sectionText({index});",
            arguments: ["index": index], in: nil, contentWorld: .page) as? [String: Any]
        return BookTextSection(label: value?["label"] as? String ?? "", text: value?["text"] as? String ?? "")
    }
    func bookBoundary(for locator: String) async throws -> BookTextBoundary? {
        if let view = pdfView, let document = view.document {
            // A page locator means the whole visible page; a position locator ends at the selection.
            let cursor = PDFLocator.cursor(locator)
            let page = cursor?.page ?? view.currentPage.map(document.index(for:)) ?? 0
            guard page >= 0, page < document.pageCount else { return nil }
            let length = (document.page(at: page)?.string ?? "").utf16.count
            let offset = locator.split(separator: ":").count > 2 ? min(cursor?.offset ?? length, length) : length
            return BookTextBoundary(section: page, offset: offset)
        }
        guard let webView, !locator.isEmpty else { return nil }
        let value = try await webView.callAsyncJavaScript("return await window.Leaf.textBoundary({locator});",
            arguments: ["locator": locator], in: nil, contentWorld: .page) as? [String: Any]
        guard let section = (value?["section"] as? NSNumber)?.intValue, let offset = (value?["offset"] as? NSNumber)?.intValue else { return nil }
        return BookTextBoundary(section: section, offset: offset)
    }
}
