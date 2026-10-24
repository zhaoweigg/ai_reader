import Foundation
import PDFKit

/// Locators inside a PDF: `pdf:<page>` names a page (navigation, bookmarks,
/// highlights, search results) and `pdf:<page>:<offset>` a character offset on
/// that page (listening cursors). Pages and offsets are zero-based.
enum PDFLocator {
    static func page(_ index: Int) -> String { "pdf:\(index)" }
    static func position(page: Int, offset: Int) -> String { "pdf:\(page):\(offset)" }
    /// The page of a page or position locator; nil for any other locator.
    static func pageIndex(_ locator: String) -> Int? { cursor(locator)?.page }
    /// The page and offset of a locator; a page locator has offset 0. Negative values are rejected.
    static func cursor(_ locator: String) -> (page: Int, offset: Int)? {
        let parts = locator.split(separator: ":")
        guard parts.count >= 2, parts[0] == "pdf", let page = Int(parts[1]), page >= 0 else { return nil }
        let offset = parts.count > 2 ? Int(parts[2]) : 0
        guard let offset, offset >= 0 else { return nil }
        return (page, offset)
    }
}

extension PDFSelection {
    /// The selected character ranges, one per text range on each selected page.
    func annotationRanges(in document: PDFDocument) -> [PDFAnnotationRange] {
        pages.flatMap { page in
            (0..<numberOfTextRanges(on: page)).map { index in
                let range = self.range(at: index, on: page)
                return PDFAnnotationRange(page: document.index(for: page), location: range.location, length: range.length)
            }
        }
    }
}
