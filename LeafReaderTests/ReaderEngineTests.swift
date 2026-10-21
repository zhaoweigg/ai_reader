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
    func testChatContextUsesVisiblePassageOrSelectionWithoutMovingTheBook() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        _ = try await waitForLayout(model, preferences: preferences)
        let web = try XCTUnwrap(model.webView)
        let location = model.locator
        let visible = try await web.evaluateJavaScript("document.querySelector('foliate-view').lastLocation.range.toString()") as? String
        let whole = try await web.evaluateJavaScript("window.Leaf.visibleText()") as? String
        let snapshot = try await model.readingChatContext()
        let context = try XCTUnwrap(snapshot)
        XCTAssertFalse(context.isEmpty)
        XCTAssertEqual(context.text, String((visible ?? "").prefix(12000)))
        XCTAssertLessThan(context.text.count, (whole ?? "").count)
        XCTAssertEqual(context.locator, location)
        XCTAssertEqual(context.source, "page")
        let selected = try await web.evaluateJavaScript("""
            (() => {
                const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc;
                const range = doc.createRange(); range.selectNodeContents(doc.querySelector('p'));
                const selection = doc.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                return selection.toString();
            })()
            """) as? String
        let selectedSnapshot = try await model.readingChatContext()
        let selection = try XCTUnwrap(selectedSnapshot)
        XCTAssertEqual(selection.source, "selection")
        XCTAssertEqual(selection.text, selected)
        XCTAssertEqual(model.locator, location)
    }
    func testPDFChatContextUsesCurrentPageAndSelection() async throws {
        let (book, url) = try prepare("Notes from the Coast.pdf", format: .pdf)
        let model = ReaderModel(bookID: book.id, library: try XCTUnwrap(store), initialLocator: nil)
        self.model = model
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        model.configurePDF(view, url: url)
        model.send("navigate", value: "pdf:2"); model.pdfPageChanged()
        let page = try XCTUnwrap(view.currentPage)
        let snapshot = try await model.readingChatContext()
        let context = try XCTUnwrap(snapshot)
        XCTAssertEqual(context.text, String((page.string ?? "").prefix(12000)))
        XCTAssertEqual(context.locator, "pdf:2")
        view.currentSelection = page.selection(for: page.bounds(for: .cropBox))
        let selectedSnapshot = try await model.readingChatContext()
        let selection = try XCTUnwrap(selectedSnapshot)
        XCTAssertEqual(selection.source, "selection")
        XCTAssertFalse(selection.isEmpty)
    }
    func testPageTurnsAnimateAndCancelledSwipesKeepThePassage() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        _ = try await waitForLayout(model, preferences: preferences)
        let web = try XCTUnwrap(model.webView)
        let result = try await web.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view');
            const renderer = view.renderer;
            const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
            // Use the real document touch handlers, including their time stamps.
            const touch = (type, x) => {
                const doc = renderer.getContents()[0].doc;
                const event = new Event(type, { bubbles:true, cancelable:true });
                const point = { screenX:x, screenY:250, clientX:x, clientY:250 };
                Object.defineProperties(event, {
                    changedTouches: { value:[point] },
                    touches: { value:type === 'touchend' || type === 'touchcancel' ? [] : [point] }
                });
                doc.dispatchEvent(event);
            };
            const origin = renderer.start;
            const locator = view.lastLocation.cfi;
            const size = renderer.size;
            touch('touchstart', 280);
            await sleep(30);
            touch('touchmove', 240);
            await sleep(120); // Short drag held still: must return, not become a stale flick.
            touch('touchend', 240);
            await sleep(110);
            const returning = renderer.start;
            await sleep(400);
            const returned = renderer.start;
            const cancelledKeepsPassage = view.lastLocation.cfi === locator;
            const began = performance.now();
            const forward = view.next();
            await sleep(110);
            const advancing = renderer.start;
            // A second command/gesture during settling must not skip another page.
            view.next();
            touch('touchstart', 280); touch('touchmove', 40); touch('touchend', 40);
            await forward;
            const forwardDuration = performance.now() - began;
            const advanced = renderer.start;
            const advancedLocator = view.lastLocation.cfi;
            await view.prev();
            const back = renderer.start;
            const restored = view.lastLocation.cfi === locator;
            touch('touchstart', 280);
            await sleep(50);
            touch('touchmove', 40);
            touch('touchcancel', 40); // System interruption must return even after a long drag.
            await sleep(500);
            const interrupted = renderer.start;
            const interruptedKeepsPassage = view.lastLocation.cfi === locator;
            // A long, slow swipe commits even without flick velocity.
            touch('touchstart', 280);
            await sleep(100);
            touch('touchmove', 40);
            await sleep(120);
            touch('touchend', 40);
            await sleep(500);
            const swiped = renderer.start;
            return { origin, size, returning, returned, cancelledKeepsPassage, advancing,
                advanced, forwardDuration, changed:view.lastLocation.cfi !== locator,
                advancedLocator, back, restored, interrupted, interruptedKeepsPassage, swiped };
            """, arguments: [:], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [String: Any])
        func number(_ key: String) throws -> Double { try XCTUnwrap(metrics[key] as? Double, key) }
        let origin = try number("origin"), size = try number("size")
        XCTAssertGreaterThan(try number("returning"), origin + 1)
        XCTAssertLessThan(try number("returning"), origin + 40)
        XCTAssertEqual(try number("returned"), origin, accuracy: 1)
        XCTAssertEqual(metrics["cancelledKeepsPassage"] as? Bool, true)
        XCTAssertGreaterThan(try number("advancing"), origin + 1)
        XCTAssertLessThan(try number("advancing"), origin + size - 1)
        XCTAssertEqual(try number("advanced"), origin + size, accuracy: 1)
        XCTAssertGreaterThan(try number("forwardDuration"), 300)
        XCTAssertLessThan(try number("forwardDuration"), 1000)
        XCTAssertEqual(try number("back"), origin, accuracy: 1)
        XCTAssertEqual(metrics["restored"] as? Bool, true)
        XCTAssertEqual(try number("interrupted"), origin, accuracy: 1)
        XCTAssertEqual(metrics["interruptedKeepsPassage"] as? Bool, true)
        XCTAssertEqual(try number("swiped"), origin + size, accuracy: 1)
        XCTAssertEqual(metrics["changed"] as? Bool, true)
        XCTAssertNil(model.error)
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Page turn timing and swipe outcomes"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPlainTextRenders() async throws {
        let (book, url) = try prepare("A Field Guide to Slow Days.txt", format: .txt)
        try await assertOpened(show(book, url: url), contains: "morning")
    }
    func testEveryTextSizeAcrossScrollAndPageLayout() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        _ = try await waitForLayout(model, preferences: preferences)
        let web = try XCTUnwrap(model.webView)
        let result = try await web.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view');
            const renderer = view.renderer;
            const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
            const results = [];
            await view.goToFraction(0.4);
            await sleep(100);
            for (const scrolling of [true, false, true, false]) {
                const sizes = Array.from({length:21}, (_, i) => scrolling ? i + 12 : 32 - i);
                for (const fontSize of sizes) {
                    const saved = view.lastLocation.cfi;
                    window.Leaf.applyPreferences({...base, scrolling, fontSize});
                    await sleep(130);
                    const doc = renderer.getContents()[0].doc;
                    const p = doc.querySelector('p');
                    const style = doc.defaultView.getComputedStyle(p);
                    const root = doc.documentElement;
                    const glyph = doc.createRange();
                    glyph.setStart(p.firstChild, 0); glyph.setEnd(p.firstChild, 1);
                    const rect = glyph.getBoundingClientRect();
                    const savedRange = view.resolveCFI(saved).anchor(doc);
                    savedRange.collapse(true);
                    if (savedRange.startContainer.nodeType === 3 && savedRange.startOffset < savedRange.startContainer.length)
                        savedRange.setEnd(savedRange.startContainer, savedRange.startOffset + 1);
                    const savedRect = savedRange.getBoundingClientRect();
                    results.push({scrolling, requested:fontSize, actual:parseFloat(style.fontSize),
                        saved, current:view.lastLocation.cfi, savedTop:savedRect.top, savedBottom:savedRect.bottom,
                        lineHeight:parseFloat(style.lineHeight), glyphWidth:rect.width, glyphHeight:rect.height,
                        paragraphWidth:p.getBoundingClientRect().width, bodyWidth:doc.body.clientWidth,
                        rootWidth:root.clientWidth, rootHeight:root.clientHeight, viewportWidth:view.clientWidth,
                        viewportHeight:view.clientHeight, start:renderer.start, size:renderer.size,
                        visibleCharacters:view.lastLocation.range.toString().replace(/\\s/g, '').length,
                        keptPassage:window.Leaf.isLocationVisible(saved)});
                }
            }
            return results;
            """, arguments: ["base": preferences.payload], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [[String: Any]])
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Every font size and flow geometry"; attachment.lifetime = .keepAlways; add(attachment)
        for row in metrics {
            let size = try XCTUnwrap(row["requested"] as? Double)
            let scrolling = row["scrolling"] as? Bool == true
            let label = "\(scrolling ? "Scroll" : "Pages") at \(size) pt"
            XCTAssertEqual(try XCTUnwrap(row["actual"] as? Double), size, accuracy: 0.1, label)
            XCTAssertEqual(try XCTUnwrap(row["glyphWidth"] as? Double), size, accuracy: 1, label)
            XCTAssertEqual(try XCTUnwrap(row["lineHeight"] as? Double), size * preferences.lineHeight, accuracy: 0.2, label)
            XCTAssertEqual(try XCTUnwrap(row["paragraphWidth"] as? Double),
                           try XCTUnwrap(row["viewportWidth"] as? Double) - 2 * preferences.horizontalMargin, accuracy: 2, label)
            XCTAssertTrue(row["keptPassage"] as? Bool == true, label)
            XCTAssertGreaterThan(try XCTUnwrap(row["visibleCharacters"] as? Double), 5, label)
        }
        XCTAssertNil(model.error)
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
