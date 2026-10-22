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
    private func show(_ book: Book, url: URL, locator: String? = nil, readerPreferences: ReaderPreferences? = nil) throws -> ReaderModel {
        let model = ReaderModel(bookID: book.id, library: try XCTUnwrap(store), initialLocator: locator)
        self.model = model
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let host = UIHostingController(rootView: WebBookSurface(model: model, url: url, preferences: readerPreferences ?? preferences))
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
    func testBothFlowsPreserveChapterBoundariesBookEndsAndReopenedPassage() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let result = try await model.webView?.callAsyncJavaScript("""
                const view = document.querySelector('foliate-view'), r = view.renderer;
                const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
                await view.goTo(1); r.scrollToAnchor(1); await sleep(100); await r.next(); await sleep(100);
                const forward = r.getContents()[0].index;
                r.scrollToAnchor(0); await sleep(100); await r.prev(); await sleep(100);
                const backward = r.getContents()[0].index;
                await view.goTo(0); r.scrollToAnchor(0); await sleep(100); await r.prev();
                const beginning = r.getContents()[0].index;
                const last = view.book.sections.length - 1;
                await view.goTo(last); r.scrollToAnchor(1); await sleep(100); await r.next();
                const end = r.getContents()[0].index;
                await view.goTo(1); r.scrollToAnchor(0.35); await sleep(100);
                return {forward,backward,beginning,end,last,documents:r.getContents().length};
                """, arguments: [:], in: nil, contentWorld: .page)
            let metrics = try XCTUnwrap(result as? [String: Int])
            XCTAssertEqual(metrics["forward"], 2, "scrolling=\(scrolling)")
            XCTAssertEqual(metrics["backward"], 1, "scrolling=\(scrolling)")
            XCTAssertEqual(metrics["beginning"], 0)
            XCTAssertEqual(metrics["end"], metrics["last"])
            XCTAssertEqual(metrics["documents"], 1)
            let locator = model.locator
            model.toggleBookmark(); store?.flush()
            model.webView?.stopLoading(); window?.isHidden = true; window = nil
            let reopened = try show(book, url: url, locator: locator, readerPreferences: prefs)
            try await waitUntil { reopened.isReady || reopened.error != nil }
            XCTAssertNil(reopened.error)
            let encoded = String(decoding: try JSONEncoder().encode(locator), as: UTF8.self)
            let visible = try await reopened.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(encoded))") as? Bool
            XCTAssertEqual(visible, true, "scrolling=\(scrolling)")
            XCTAssertTrue(store?.book(book.id)?.bookmarks.contains { $0.locator == locator } == true)
            reopened.webView?.stopLoading(); window?.isHidden = true; window = nil
        }
    }
    func testFictionBookRenders() async throws {
        let (book, url) = try prepare("A Short History of Stars.fb2", format: .fb2)
        try await assertOpened(show(book, url: url), contains: "light")
    }
    func testDiskByteRangesRejectInvalidAndOverflowingRequests() {
        XCTAssertEqual(ReaderAssetHandler.byteRange("bytes=0-9", size: 100), 0..<10)
        XCTAssertEqual(ReaderAssetHandler.byteRange("bytes=95-999", size: 100), 95..<100)
        XCTAssertEqual(ReaderAssetHandler.byteRange("bytes=50-", size: 100), 50..<100)
        XCTAssertEqual(ReaderAssetHandler.byteRange("bytes=-5", size: 100), 95..<100)
        XCTAssertEqual(ReaderAssetHandler.byteRange("bytes=-999", size: 100), 0..<100)
        for header in ["bytes=100-", "bytes=5-4", "bytes=-0", "bytes=-", "bytes=0-1,3-4", "bytes=+1-2", "bytes=0-9999999999999999999999999", "items=0-1"] {
            XCTAssertNil(ReaderAssetHandler.byteRange(header, size: 100), header)
        }
        XCTAssertNil(ReaderAssetHandler.byteRange("bytes=0-1", size: 0))
    }
    func testNativeDiskDeliveryIsChunkedAndStopsAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("book.epub")
        try Data(repeating: 7, count: 1024 * 1024).write(to: file)
        let handler = ReaderAssetHandler(bookURL: file, format: .epub, assets: root)
        let web = WKWebView()
        var request = URLRequest(url: URL(string: "leaf-reader://reader/book")!)
        request.setValue("bytes=100-300099", forHTTPHeaderField: "Range")
        let ranged = MemorySchemeTask(request: request)
        handler.webView(web, start: ranged)
        try await waitUntil { ranged.finished || ranged.error != nil }
        XCTAssertNil(ranged.error)
        XCTAssertEqual(ranged.response?.statusCode, 206)
        XCTAssertEqual(ranged.response?.value(forHTTPHeaderField: "Content-Range"), "bytes 100-300099/1048576")
        XCTAssertEqual(ranged.received, 300000)
        XCTAssertLessThanOrEqual(ranged.largestChunk, 64 * 1024)
        let cancelled = MemorySchemeTask(request: URLRequest(url: request.url!))
        cancelled.onChunk = { handler.webView(web, stop: cancelled) }
        handler.webView(web, start: cancelled)
        try await waitUntil { cancelled.received > 0 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cancelled.received, 64 * 1024)
        XCTAssertFalse(cancelled.finished)
        XCTAssertNil(cancelled.error)
        cancelled.onChunk = nil
    }
    func testEPUBResourcesStayBoundedAcrossManyChapterChanges() async throws {
        let (book, url) = try prepare("MemoryStress.epub", format: .epub, fixtures: true)
        let model = try show(book, url: url)
        try await waitUntil { model.isReady || model.error != nil }
        XCTAssertNil(model.error)
        let web = try XCTUnwrap(model.webView)
        let result = try await web.callAsyncJavaScript("""
            const active = new Map(); let peakCount = 0, peakBytes = 0, requests = 0, largestRead = 0;
            let nonRangeReads = 0, heads = 0;
            const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
            const fetchOriginal = window.fetch.bind(window);
            URL.createObjectURL = blob => {
                const url = create(blob); active.set(url, blob.size);
                peakCount = Math.max(peakCount, active.size);
                peakBytes = Math.max(peakBytes, [...active.values()].reduce((a,b) => a+b, 0));
                return url;
            };
            URL.revokeObjectURL = url => { active.delete(url); revoke(url); };
            window.fetch = async (url, options) => {
                const response = await fetchOriginal(url, options);
                if (String(url).endsWith('/book')) {
                    if (options?.method === 'HEAD') heads++;
                    else {
                        requests++;
                        if (!options?.headers?.Range) nonRangeReads++;
                        largestRead = Math.max(largestRead, Number(response.headers.get('Content-Length')));
                    }
                }
                return response;
            };
            try {
                await window.Leaf.open(config);
                const view = document.querySelector('foliate-view');
                const count = view.book.sections.length;
                let maxDocuments = 0;
                for (let n = 0; n < 160; n++) {
                    await view.goTo((n * 37) % count);
                    maxDocuments = Math.max(maxDocuments, view.renderer.getContents().length);
                    if (n % 20 === 0) await new Promise(resolve => setTimeout(resolve, 10));
                }
                const finalCount = active.size;
                window.Leaf.close();
                return {count, heads, requests, nonRangeReads, largestRead, peakCount, peakBytes,
                    finalCount, afterClose:active.size, maxDocuments};
            } finally {
                window.fetch = fetchOriginal; URL.createObjectURL = create; URL.revokeObjectURL = revoke;
            }
            """, arguments: ["config": ["name": "MemoryStress.epub", "format": "epub", "locator": "", "preferences": preferences.payload]], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [String: Int])
        XCTAssertGreaterThanOrEqual(metrics["count"] ?? 0, 128)
        XCTAssertEqual(metrics["heads"], 1)
        XCTAssertGreaterThan(metrics["requests"] ?? 0, 160)
        XCTAssertEqual(metrics["nonRangeReads"], 0)
        XCTAssertLessThanOrEqual(metrics["largestRead"] ?? .max, 256 * 1024)
        XCTAssertLessThanOrEqual(metrics["peakCount"] ?? .max, 16)
        XCTAssertLessThanOrEqual(metrics["peakBytes"] ?? .max, 16 * 1024 * 1024)
        XCTAssertLessThanOrEqual(metrics["finalCount"] ?? .max, 8)
        XCTAssertEqual(metrics["afterClose"], 0)
        XCTAssertEqual(metrics["maxDocuments"], 1)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(metrics), uniformTypeIdentifier: "public.json")
        attachment.name = "160 chapter changes and released resources"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testRendererTerminationRestoresPassageAndLimitsRecoveryLoops() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        model.send("seek", value: 0.55)
        try await waitUntil { model.fraction > 0.4 }
        let locator = model.locator, oldID = model.reloadID
        let oldWeb = try XCTUnwrap(model.webView)
        let now = Date()
        model.webProcessTerminated(oldWeb, now: now)
        XCTAssertNotEqual(model.reloadID, oldID)
        XCTAssertFalse(model.isReady)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.locator, locator)
        // Rebuild the surface as ReaderView's reloadID does in production.
        window?.rootViewController = UIHostingController(rootView: WebBookSurface(model: model, url: url, preferences: preferences))
        try await waitUntil { model.isReady || model.error != nil }
        XCTAssertNil(model.error)
        let encoded = String(decoding: try JSONEncoder().encode(locator), as: UTF8.self)
        let visible = try await model.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(encoded))") as? Bool
        XCTAssertEqual(visible, true)
        let restoredID = model.reloadID
        model.webProcessTerminated(oldWeb, now: now.addingTimeInterval(1))
        XCTAssertEqual(model.reloadID, restoredID) // Ignore callbacks from a discarded surface.
        model.webProcessTerminated(try XCTUnwrap(model.webView), now: now.addingTimeInterval(2))
        XCTAssertEqual(model.reloadID, restoredID)
        XCTAssertTrue(model.error?.contains("renderer stopped") == true)
        XCTAssertFalse(model.error?.contains("memory") == true)
    }
    func testClosingReaderReleasesNativeWebView() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        weak var closedView = model.webView
        XCTAssertNotNil(closedView)
        window?.rootViewController = nil
        try await waitUntil({ closedView == nil }, timeout: 10)
        XCTAssertNil(model.webView)
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
    func testFloatingOverlayLeavesFullTextWidthAtEverySizeInBothFlows() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        _ = try await waitForLayout(model, preferences: preferences)
        let web = try XCTUnwrap(model.webView)
        let result = try await web.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view');
            const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
            const initialDoc = view.renderer.getContents()[0].doc;
            const first = initialDoc.querySelector('p').firstChild;
            const savedRange = initialDoc.createRange();
            savedRange.setStart(first, 8); savedRange.setEnd(first, 20);
            const saved = view.getCFI(0, savedRange), savedText = savedRange.toString();
            const originalText = initialDoc.body.textContent;
            const metrics = [];
            const measure = (scrolling,size,step) => {
                const doc = view.renderer.getContents()[0].doc;
                const frame = doc.defaultView.frameElement.getBoundingClientRect();
                const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
                const range = doc.createRange();
                let farRight = 0;
                for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                    if (node.parentElement.closest('script,style')) continue;
                    range.selectNodeContents(node);
                    for (const r of range.getClientRects()) {
                        const y = r.top + frame.top, x = r.right + frame.left;
                        if (y > 0 && y < innerHeight && x > 0 && x <= innerWidth)
                            farRight = Math.max(farRight, x);
                    }
                }
                return {scrolling,size,step,farRight,expectedRight:innerWidth-base.horizontalMargin,
                    paragraphWidth:doc.querySelector('p').getBoundingClientRect().width, expectedWidth:innerWidth-2*base.horizontalMargin,
                    markers:doc.querySelectorAll('[data-leaf-reading-exclusion]').length,
                    rendererExclusion:view.renderer.hasAttribute('reading-exclusion'),
                    viewportWidth:view.getBoundingClientRect().width,
                    sameText:doc.body.textContent === originalText,
                    sameCFIText:view.resolveCFI(saved).anchor(doc).toString() === savedText};
            };
            for (const scrolling of [false,true]) {
                for (const size of Array.from({length:21}, (_, i) => i + 12)) {
                    window.Leaf.applyPreferences({...base, scrolling, fontSize:size});
                    await sleep(100);
                    await view.goTo(0); await sleep(80);
                    for (let step = 0; step < 5; step++) {
                        if (scrolling) {
                            const doc = view.renderer.getContents()[0].doc;
                            const container = doc.defaultView.frameElement.parentElement.parentElement;
                            container.scrollTop = [0,250,700,1200,100][step];
                            await sleep(100);
                        }
                        metrics.push(measure(scrolling,size,step));
                        if (!scrolling) { await view.goRight(); await sleep(30); }
                    }
                }
            }
            return metrics;
            """, arguments: ["base": preferences.payload], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(metrics.count, 210)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "Pages and Scroll full text width without exclusions"; attachment.lifetime = .keepAlways; add(attachment)
        for row in metrics {
            XCTAssertEqual(row["markers"] as? Int, 0, "\(row)")
            XCTAssertEqual(row["rendererExclusion"] as? Bool, false, "\(row)")
            XCTAssertEqual(try XCTUnwrap(row["paragraphWidth"] as? Double), try XCTUnwrap(row["expectedWidth"] as? Double), accuracy: 2, "\(row)")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(row["farRight"] as? Double), try XCTUnwrap(row["expectedRight"] as? Double) - (row["size"] as? Double ?? 0) - 6, "\(row)")
            XCTAssertEqual(row["sameText"] as? Bool, true)
            XCTAssertEqual(row["sameCFIText"] as? Bool, true)
        }
        XCTAssertNil(model.error)
    }
    func testFloatingButtonPositionClampsAndSurvivesRotation() {
        let portrait = CGSize(width: 402, height: 800), landscape = CGSize(width: 800, height: 340)
        let initial = ReaderChatPlacement.center(x: -1, y: -1, in: portrait)
        XCTAssertEqual(initial, CGPoint(x: 358, y: 662))
        for point in [CGPoint(x: -500, y: -200), CGPoint(x: 3000, y: 900), CGPoint(x: 88, y: 275)] {
            let normalized = ReaderChatPlacement.normalized(point, in: portrait)
            XCTAssertTrue((0...1).contains(normalized.x)); XCTAssertTrue((0...1).contains(normalized.y))
            let rotated = ReaderChatPlacement.center(x: normalized.x, y: normalized.y, in: landscape)
            XCTAssertTrue(ReaderChatPlacement.bounds(in: landscape).insetBy(dx: -0.1, dy: -0.1).contains(rotated))
            let restored = ReaderChatPlacement.center(x: normalized.x, y: normalized.y, in: portrait)
            XCTAssertEqual(restored.x, ReaderChatPlacement.clamp(point, in: portrait).x, accuracy: 0.01)
            XCTAssertEqual(restored.y, ReaderChatPlacement.clamp(point, in: portrait).y, accuracy: 0.01)
        }
        XCTAssertEqual(ReaderChatPlacement.center(x: .nan, y: .infinity, in: portrait), initial)
        XCTAssertEqual(ReaderChatPlacement.clamp(.zero, in: CGSize(width: 30, height: 20)), CGPoint(x: 15, y: 10))
    }
    func testScrollPreservesTheVisibleAnchorAcrossMarginsAndRepeatedScrolls() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view');
            const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
            const rows = [];
            for (const margin of [12,20,36,48]) {
                window.Leaf.applyPreferences({...base,scrolling:true,font:'System',fontSize:20,horizontalMargin:margin});
                await sleep(100);
                const doc = view.renderer.getContents()[0].doc;
                const container = doc.defaultView.frameElement.parentElement.parentElement;
                for (const offset of [0,200,700,1300,350,50]) {
                    container.scrollTop = offset;
                    const range = doc.caretRangeFromPoint(margin+5,container.scrollTop+24);
                    if (!range || range.startContainer.nodeType!==3) continue;
                    if (range.startOffset < range.startContainer.length) range.setEnd(range.startContainer,range.startOffset+1);
                    const y = range.getBoundingClientRect().top-container.scrollTop;
                    await sleep(120);
                    rows.push({margin,offset,drift:range.getBoundingClientRect().top-container.scrollTop-y});
                }
            }
            return rows;
            """, arguments: ["base": preferences.payload], in: nil, contentWorld: .page)
        let rows = try XCTUnwrap(result as? [[String: Double]])
        XCTAssertGreaterThan(rows.count, 12)
        for row in rows { XCTAssertLessThan(abs(row["drift"] ?? 999), 2, "\(row)") }
    }
    func testScrollGesturesContinueAcrossChapterEdgesAndKeepOneDocumentLoaded() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view');
            const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
            window.Leaf.applyPreferences({...base, scrolling:true}); await sleep(150);
            await view.goTo(1); await sleep(100);
            const renderer = view.renderer;
            const touch = (type,y) => {
                const doc = renderer.getContents()[0].doc;
                const event = new Event(type, {bubbles:true,cancelable:true});
                const point = {screenX:150,screenY:y,clientX:150,clientY:y};
                Object.defineProperties(event,{changedTouches:{value:[point]},touches:{value:type==='touchend'||type==='touchcancel'?[]:[point]}});
                doc.dispatchEvent(event);
            };
            const edge = end => {
                const doc = renderer.getContents()[0].doc;
                const container = doc.defaultView.frameElement.parentElement.parentElement;
                container.scrollTop = end ? container.scrollHeight : 0;
            };
            edge(true); await sleep(100);
            touch('touchstart',350); touch('touchmove',200); touch('touchend',200); await sleep(300);
            const next = renderer.getContents()[0].index;
            edge(false); await sleep(80);
            touch('touchstart',200); touch('touchmove',350); touch('touchend',350); await sleep(300);
            const previous = renderer.getContents()[0].index;
            await view.goTo(1); edge(false); await sleep(100);
            touch('touchstart',350); touch('touchmove',200); touch('touchend',200);
            edge(true); await sleep(300); // A flick reaches the edge after the finger lifts.
            const momentumNext = renderer.getContents()[0].index;
            await view.goTo(0); edge(false); await sleep(100);
            touch('touchstart',200); touch('touchmove',350); touch('touchend',350); await sleep(100);
            const start = renderer.getContents()[0].index;
            await view.goTo(view.book.sections.length-1); edge(true); await sleep(100);
            touch('touchstart',350); touch('touchmove',200); touch('touchend',200); await sleep(100);
            return {next,previous,momentumNext,start,end:renderer.getContents()[0].index,last:view.book.sections.length-1,documents:renderer.getContents().length};
            """, arguments: ["base": preferences.payload], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [String: Int])
        XCTAssertEqual(metrics["next"], 2)
        XCTAssertEqual(metrics["previous"], 1)
        XCTAssertEqual(metrics["momentumNext"], 2)
        XCTAssertEqual(metrics["start"], 0)
        XCTAssertEqual(metrics["end"], metrics["last"])
        XCTAssertEqual(metrics["documents"], 1)
        XCTAssertNil(model.error)
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
            for (const [fontIndex,font] of ['Georgia','Palatino','System'].entries()) {
              const horizontalMargin = [12,20,36][fontIndex];
              const background = ['#FFFFFF','#F4EDDD','#17232E'][fontIndex];
              const foreground = ['#263440','#493F30','#D7DEE4'][fontIndex];
              for (const scrolling of [true, false]) {
                const sizes = Array.from({length:21}, (_, i) => scrolling ? i + 12 : 32 - i);
                for (const fontSize of sizes) {
                    const saved = view.lastLocation.cfi;
                    window.Leaf.applyPreferences({...base, scrolling, fontSize, font, horizontalMargin, background, foreground});
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
                    results.push({scrolling, font, horizontalMargin, requested:fontSize, actual:parseFloat(style.fontSize),
                        saved, current:view.lastLocation.cfi, savedTop:savedRect.top, savedBottom:savedRect.bottom,
                        lineHeight:parseFloat(style.lineHeight), glyphWidth:rect.width, glyphHeight:rect.height,
                        paragraphWidth:p.getBoundingClientRect().width, bodyWidth:doc.body.clientWidth,
                        rootWidth:root.clientWidth, rootHeight:root.clientHeight, viewportWidth:view.clientWidth,
                        viewportHeight:view.clientHeight, start:renderer.start, size:renderer.size,
                        visibleCharacters:view.lastLocation.range.toString().replace(/\\s/g, '').length,
                        keptPassage:window.Leaf.isLocationVisible(saved)});
                }
            }
            }
            return results;
            """, arguments: ["base": preferences.payload], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(metrics.count, 126)
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Every font size and flow geometry"; attachment.lifetime = .keepAlways; add(attachment)
        for row in metrics {
            let size = try XCTUnwrap(row["requested"] as? Double)
            let scrolling = row["scrolling"] as? Bool == true
            let label = "\(scrolling ? "Scroll" : "Pages") \(row["font"] ?? "") at \(size) pt"
            XCTAssertEqual(try XCTUnwrap(row["actual"] as? Double), size, accuracy: 0.1, label)
            XCTAssertEqual(try XCTUnwrap(row["glyphWidth"] as? Double), size, accuracy: 1, label)
            XCTAssertEqual(try XCTUnwrap(row["lineHeight"] as? Double), size * preferences.lineHeight, accuracy: 0.2, label)
            XCTAssertEqual(try XCTUnwrap(row["paragraphWidth"] as? Double),
                           try XCTUnwrap(row["viewportWidth"] as? Double) - 2 * (row["horizontalMargin"] as? Double ?? 0), accuracy: 2, label)
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

@MainActor private final class MemorySchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: HTTPURLResponse?
    var received = 0
    var largestChunk = 0
    var finished = false
    var error: Error?
    var onChunk: (() -> Void)?
    init(request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { received += data.count; largestChunk = max(largestChunk, data.count); onChunk?() }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}
