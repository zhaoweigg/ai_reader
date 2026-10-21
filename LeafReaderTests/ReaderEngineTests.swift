import XCTest
import SwiftUI
import WebKit
import PDFKit
@testable import LeafReader

@MainActor
final class ReaderEngineTests: XCTestCase {
    private var window: UIWindow?
    private var model: ReaderModel?
    private var store: LibraryStore?
    private var root: URL?
    private let preferences = ReaderPreferences(fontSize: 19, lineHeight: 1.65, font: "Georgia", theme: .day, scrolling: false)

    private func prepare(_ name: String, format: BookFormat, fixtures: Bool = false) throws -> (Book, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = directory
        let disk = try LibraryDisk(root: directory)
        let source = fixtures
            ? Bundle(for: type(of: self)).url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            : Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Samples")
        let url = try XCTUnwrap(source, "Missing test book: \(name)")
        let book = try disk.prepareImport(url, existing: [])
        try disk.save([book])
        store = LibraryStore(root: directory, seedSamples: false)
        addTeardownBlock { @MainActor [weak self] in
            self?.model?.webView?.stopLoading(); self?.window?.isHidden = true; self?.window = nil; self?.model = nil; self?.store = nil
            try? FileManager.default.removeItem(at: directory)
        }
        return (book, disk.fileURL(book))
    }
    private func show(_ book: Book, url: URL, locator: String? = nil) throws -> ReaderModel {
        let model = ReaderModel(bookID: book.id, library: try XCTUnwrap(store), initialLocator: locator)
        self.model = model
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let host = UIHostingController(rootView: WebBookSurface(model: model, url: url, preferences: preferences))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        return model
    }
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Timed out waiting for reader. Error: \(model?.error ?? "none")")
    }
    private func assertOpened(_ model: ReaderModel, contains text: String) async throws {
        try await waitUntil { model.isReady || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.isReady)
        let rendered = try await model.webView?.evaluateJavaScript("window.Leaf.visibleText()") as? String
        XCTAssertTrue(rendered?.localizedCaseInsensitiveContains(text) == true, "Missing '\(text)' in rendered content: \(rendered?.prefix(500) ?? "nil")")
    }
    func testEPUBRendersSearchesAndRestoresPosition() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        XCTAssertEqual(model.chapters.count, 4)
        model.search("attention")
        try await waitUntil { !model.isSearching }
        XCTAssertFalse(model.searchResults.isEmpty)
        model.send("seek", value: 0.55)
        try await waitUntil { model.fraction > 0.4 }
        let locator = model.locator
        model.toggleBookmark()
        XCTAssertEqual(store?.book(book.id)?.bookmarks.count, 1)
        store?.flush()
        model.webView?.stopLoading()
        window?.isHidden = true
        window = nil
        let reopened = try show(book, url: url, locator: locator)
        try await waitUntil { reopened.isReady || reopened.error != nil }
        XCTAssertNil(reopened.error)
        let encodedLocator = String(decoding: try JSONEncoder().encode(locator), as: UTF8.self)
        let passageVisible = try await reopened.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(encodedLocator))") as? Bool
        // Progress estimates depend on pagination; verify the saved text itself.
        XCTAssertEqual(passageVisible, true, "Reopening must show the start of the saved passage.")
        XCTAssertGreaterThan(reopened.fraction, 0.4)
    }
    func testFictionBookRenders() async throws {
        let (book, url) = try prepare("A Short History of Stars.fb2", format: .fb2)
        try await assertOpened(show(book, url: url), contains: "light")
    }
    func testPlainTextRenders() async throws {
        let (book, url) = try prepare("A Field Guide to Slow Days.txt", format: .txt)
        try await assertOpened(show(book, url: url), contains: "morning")
    }
    private func pageMetrics(_ model: ReaderModel) async throws -> [String: Double] {
        let result = try await model.webView?.evaluateJavaScript("""
            (() => {
                const view = document.querySelector('foliate-view');
                const doc = view.renderer.getContents()[0].doc;
                const style = doc.defaultView.getComputedStyle(doc.querySelector('p'));
                const rootStyle = doc.defaultView.getComputedStyle(doc.documentElement);
                return { viewportHeight: view.clientHeight, contentHeight: doc.documentElement.clientHeight,
                    viewportWidth: view.clientWidth, columnWidth: parseFloat(rootStyle.columnWidth) || 0,
                    sidePadding: parseFloat(rootStyle.paddingLeft),
                    scrolling: Number(view.renderer.getAttribute('flow') === 'scrolled'),
                    fontSize: parseFloat(style.fontSize), lineHeight: parseFloat(style.lineHeight),
                    paragraphSpacing: parseFloat(style.marginBottom),
                    visibleCharacters: view.lastLocation.range.toString().replace(/\\s/g, '').length };
            })()
            """)
        return try XCTUnwrap(result as? [String: Double])
    }
    private func waitForLayout(_ model: ReaderModel, preferences: ReaderPreferences) async throws -> [String: Double] {
        let deadline = Date().addingTimeInterval(8)
        var metrics: [String: Double] = [:]
        var settled = 0
        while Date() < deadline {
            let next = try await pageMetrics(model)
            let correct = abs((next["contentHeight"] ?? 0) - (next["viewportHeight"] ?? 0) + 2 * preferences.verticalMargin) < 2
                && abs((next["columnWidth"] ?? 0) - (next["viewportWidth"] ?? 0) + 2 * preferences.horizontalMargin) < 2
                && abs((next["fontSize"] ?? 0) - preferences.fontSize) < 0.1
                && abs((next["paragraphSpacing"] ?? 0) - preferences.paragraphSpacing * preferences.fontSize) < 0.1
            settled = correct && next == metrics ? settled + 1 : 0
            metrics = next
            if settled >= 3 { return metrics }
            try await Task.sleep(for: .milliseconds(75))
        }
        XCTFail("Page layout did not settle: \(metrics)")
        return metrics
    }
    func testPageDensityUsesFullHeightAndKeepsSavedPassage() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        let initial = try await waitForLayout(model, preferences: preferences)
        XCTAssertGreaterThan(try XCTUnwrap(initial["contentHeight"]), try XCTUnwrap(initial["viewportHeight"]) * 0.9)
        model.send("seek", value: 0.45)
        try await waitUntil { model.fraction > 0.3 }
        let locator = model.locator
        let saved = String(decoding: try JSONEncoder().encode(locator), as: UTF8.self)
        let spacious = ReaderPreferences(fontSize: 25, lineHeight: 2, font: "Georgia", theme: .day, scrolling: false,
                                          horizontalMargin: 48, verticalMargin: 48, paragraphSpacing: 1.2)
        let host = try XCTUnwrap(window?.rootViewController as? UIHostingController<WebBookSurface>)
        host.rootView = WebBookSurface(model: model, url: url, preferences: spacious)
        let fewer = try await waitForLayout(model, preferences: spacious)
        let spaciousShowsSavedPassage = try await model.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(saved))") as? Bool
        XCTAssertEqual(spaciousShowsSavedPassage, true)
        let compact = ReaderPreferences(fontSize: 17, lineHeight: 1.35, font: "Georgia", theme: .day, scrolling: false,
                                         horizontalMargin: 12, verticalMargin: 8, paragraphSpacing: 0.35)
        host.rootView = WebBookSurface(model: model, url: url, preferences: compact)
        let more = try await waitForLayout(model, preferences: compact)
        XCTAssertGreaterThan(try XCTUnwrap(more["visibleCharacters"]), try XCTUnwrap(fewer["visibleCharacters"]) * 1.5)
        let compactShowsSavedPassage = try await model.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(saved))") as? Bool
        XCTAssertEqual(compactShowsSavedPassage, true)
        XCTAssertNil(model.error)
        let metrics = try JSONSerialization.data(withJSONObject: ["default": initial, "spacious": fewer, "compact": more], options: [.prettyPrinted, .sortedKeys])
        let result = XCTAttachment(data: metrics, uniformTypeIdentifier: "public.json")
        result.name = "Page density measurements"; result.lifetime = .keepAlways; add(result)
        let webView = try XCTUnwrap(model.webView)
        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                XCTAssertNil(error)
                continuation.resume(returning: image)
            }
        }
        let screenshot = XCTAttachment(image: try XCTUnwrap(image))
        screenshot.name = "Chinese compact page"; screenshot.lifetime = .keepAlways; add(screenshot)
        var scrolling = compact
        scrolling.scrolling = true
        host.rootView = WebBookSurface(model: model, url: url, preferences: scrolling)
        let deadline = Date().addingTimeInterval(5)
        var scrolled: [String: Double] = [:]
        while Date() < deadline {
            scrolled = try await pageMetrics(model)
            if scrolled["scrolling"] == 1, abs((scrolled["sidePadding"] ?? 0) - compact.horizontalMargin) < 1 { break }
            try await Task.sleep(for: .milliseconds(75))
        }
        XCTAssertEqual(scrolled["scrolling"], 1)
        XCTAssertEqual(try XCTUnwrap(scrolled["sidePadding"]), compact.horizontalMargin, accuracy: 1)
        let scrollShowsSavedPassage = try await model.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(saved))") as? Bool
        XCTAssertEqual(scrollShowsSavedPassage, true)
    }
    func testMOBIWithPalmDOCCompressionRenders() async throws {
        let (book, url) = try prepare("Afternoon.mobi", format: .mobi, fixtures: true)
        try await assertOpened(show(book, url: url), contains: "afternoon")
    }
    func testEncryptedMOBIShowsUsefulError() async throws {
        let (book, url) = try prepare("Protected.mobi", format: .mobi, fixtures: true)
        let model = try show(book, url: url)
        try await waitUntil { model.error != nil }
        XCTAssertTrue(model.error?.contains("protected") == true)
        XCTAssertFalse(model.isReady)
    }
    func testHTMLScriptsAreRemoved() async throws {
        let (book, url) = try prepare("Safe.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "safe passage")
        let executed = try await model.webView?.evaluateJavaScript("window.Leaf.visibleText().includes('SCRIPT EXECUTED')") as? Bool
        XCTAssertEqual(executed, false)
    }
    func testCBZRendersAndNavigates() async throws {
        let (book, url) = try prepare("Panels.cbz", format: .cbz, fixtures: true)
        let model = try show(book, url: url)
        try await waitUntil { model.isReady || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.chapters.count, 2)
        model.send("seek", value: 1.0)
        try await waitUntil { model.fraction > 0.5 }
    }
    func testPDFRendersSearchesAndNavigates() throws {
        let (book, url) = try prepare("Notes from the Coast.pdf", format: .pdf)
        let model = ReaderModel(bookID: book.id, library: try XCTUnwrap(store), initialLocator: nil)
        self.model = model
        let pdf = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        model.configurePDF(pdf, url: url)
        XCTAssertTrue(model.isReady)
        XCTAssertEqual(pdf.document?.pageCount, 4)
        model.search("coast")
        XCTAssertFalse(model.searchResults.isEmpty)
        model.send("navigate", value: "pdf:2")
        model.pdfPageChanged()
        XCTAssertEqual(model.locator, "pdf:2")
        XCTAssertEqual(model.fraction, 2.0 / 3.0, accuracy: 0.001)
    }
}
