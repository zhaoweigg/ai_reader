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
    func testSelectionRefreshSnapshotsTheCurrentRangeAndIgnoresCancellationInBothFlows() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let selectWord = """
            const view=document.querySelector('foliate-view'),content=view.renderer.getContents()[0],doc=content.doc,node=doc.querySelector('p').firstChild;
            const start=node.data.indexOf(word);if(start<0)throw new Error('Missing fixture word');
            const range=doc.createRange();range.setStart(node,start);range.setEnd(node,start+word.length);
            const selection=doc.getSelection();selection.removeAllRanges();selection.addRange(range);
            return {text:selection.toString(),locator:view.getCFI(content.index,range),place:view.lastLocation.cfi};
            """
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let web = try XCTUnwrap(model.webView)
            if !model.isBookmarked { model.toggleBookmark() }
            let bookmarks = model.book?.bookmarks
            _ = try await web.callAsyncJavaScript(selectWord, arguments: ["word": "Attention"], in: nil, contentWorld: .page)
            try await waitUntil { model.selectedReadingContext()?.text == "Attention" }
            // An IPC selection message may still be pending when the menu is requested.
            // Disconnecting that bridge leaves the cache stale while the real DOM changes.
            web.configuration.userContentController.removeScriptMessageHandler(forName: "leaf")
            let expected = try await web.callAsyncJavaScript(selectWord, arguments: ["word": "way"], in: nil, contentWorld: .page) as? [String: String]
            XCTAssertEqual(model.selectedReadingContext()?.text, "Attention")
            _ = try await web.evaluateJavaScript("window.savedContextForTest=window.Leaf.chatContext;window.Leaf.chatContext=()=>{const value=window.savedContextForTest();const end=performance.now()+180;while(performance.now()<end){};return value;};void 0;")
            let cancelled = Task { await model.refreshSelectedWebContext() }
            try await Task.sleep(for: .milliseconds(25)); cancelled.cancel(); await cancelled.value
            XCTAssertEqual(model.selectedReadingContext()?.text, "Attention", "A cancelled request cannot attach a late selection")
            _ = try await web.evaluateJavaScript("window.Leaf.chatContext=window.savedContextForTest;delete window.savedContextForTest;")
            await model.refreshSelectedWebContext()
            XCTAssertEqual(model.selectedReadingContext()?.text, expected?["text"])
            XCTAssertEqual(model.selectedReadingContext()?.locator, expected?["locator"])
            let currentPlace = try await web.evaluateJavaScript("window.Leaf.currentLocation()") as? String
            XCTAssertEqual(currentPlace, expected?["place"])
            XCTAssertEqual(model.book?.bookmarks, bookmarks)
            model.clearNativeSelection(); await model.refreshSelectedWebContext()
            XCTAssertNil(model.selectedReadingContext(), "Clearing selection must not substitute page text for a selected quote")
        }
    }
    func testSelectionRefreshKeepsTheLatestNeighborCFIWhenAnotherChapterRetainsASelection() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        var prefs = preferences; prefs.scrolling = true
        let model = try show(book, url: url, readerPreferences: prefs)
        try await assertOpened(model, contains: "attention")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            await view.goTo(1);
            const end=performance.now()+8000;
            while(!r.getContents().some(c=>c.index===2&&c.doc?.body)){if(performance.now()>end)throw new Error('Neighbor not ready');await sleep(10);}
            const frame=r.getContents().find(c=>c.index===2).doc.defaultView.frameElement,container=frame.parentElement.parentElement;
            container.scrollTop=frame.parentElement.getBoundingClientRect().top-container.getBoundingClientRect().top+container.scrollTop-container.clientHeight*.45;
            await sleep(300);
            """, arguments: [:], in: nil, contentWorld: .page)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "leaf")
        let state = try await web.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),contents=view.renderer.getContents();
            const earlier=contents.find(c=>c.index===1),latest=contents.find(c=>c.index===2);
            function select(content){const doc=content.doc,node=doc.querySelector('p').firstChild,range=doc.createRange();range.setStart(node,2);range.setEnd(node,12);doc.body.tabIndex=-1;doc.body.focus({preventScroll:true});const selected=doc.getSelection();selected.removeAllRanges();selected.addRange(range);return {range,selected};}
            const old=select(earlier);
            await new Promise(resolve=>setTimeout(resolve,80));
            const current=select(latest);
            latest.doc.body.focus({preventScroll:true});
            await new Promise(resolve=>setTimeout(resolve,80));
            return {text:current.selected.toString(),expected:view.getCFI(2,current.range),oldRetained:!old.selected.isCollapsed,place:view.lastLocation.cfi};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let expected = try XCTUnwrap(state)
        XCTAssertEqual(expected["oldRetained"] as? Bool, true, "Keep the older chapter range to reproduce the stale lookup")
        XCTAssertFalse((expected["text"] as? String ?? "").isEmpty)
        await model.refreshSelectedWebContext()
        XCTAssertEqual(model.selectedReadingContext()?.text, expected["text"] as? String)
        XCTAssertEqual(model.selectedReadingContext()?.locator, expected["expected"] as? String, "The latest selection owns the CFI")
        let currentPlace = try await web.evaluateJavaScript("window.Leaf.currentLocation()") as? String
        XCTAssertEqual(currentPlace, expected["place"] as? String)
        _ = try await web.callAsyncJavaScript("""
            const contents=document.querySelector('foliate-view').renderer.getContents();
            contents.find(c=>c.index===2).doc.getSelection().removeAllRanges();
            await new Promise(resolve=>setTimeout(resolve,80));
            return contents.find(c=>c.index===1).doc.getSelection().toString();
            """, arguments: [:], in: nil, contentWorld: .page)
        await model.refreshSelectedWebContext()
        XCTAssertNil(model.selectedReadingContext(), "Clearing the current range must not resurrect the retained older chapter selection")
        let mountedAfterNavigation = try await web.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),doc=view.renderer.getContents().find(c=>c.index===2).doc;
            const range=doc.createRange(),node=doc.querySelector('p').firstChild;
            range.setStart(node,2);range.setEnd(node,12);doc.getSelection().addRange(range);
            await new Promise(resolve=>setTimeout(resolve,80));
            await window.Leaf.command({action:'navigate',value:'section:0'});
            await new Promise(resolve=>setTimeout(resolve,100));
            return view.renderer.getContents().map(c=>c.index);
            """, arguments: [:], in: nil, contentWorld: .page) as? [Int]
        XCTAssertFalse(try XCTUnwrap(mountedAfterNavigation).contains(2), "Navigation must evict the distant selection owner")
        await model.refreshSelectedWebContext()
        XCTAssertNil(model.selectedReadingContext(), "An evicted owner cannot fall back to an older mounted selection")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: expected), uniformTypeIdentifier: "public.json")
        attachment.name = "Latest neighboring selection and retained prior range"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testSpokenPositionFollowsInsideLongChineseParagraphInBothFlows() async throws {
        let (book, url) = try prepare("SpokenLines.html", format: .html, fixtures: true)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "窗外")
            let rows = try await model.webView?.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'),content=view.renderer.getContents()[0],doc=content.doc,p=doc.querySelector('p');
                const whole=doc.createRange();whole.selectNodeContents(p);
                const packet=await window.Leaf.readAloudChunk({locator:view.getCFI(0,whole)}),rows=[];
                for(const [location,length] of [[3,1],[300,180],[650,60],[12,1]]){
                    // Simulate a cached semantic snapshot spanning the paragraph.
                    // Navigation must use physical line visibility, even if layout
                    // has changed since this snapshot was recorded.
                    view.lastLocation.range=whole.cloneRange();
                    await window.Leaf.setSpokenRange({passage:packet,locator:packet.locator,location,length,follow:true});
                    await new Promise(r=>setTimeout(r,80));
                    const segment=packet.segments.find(s=>location>=s.offset&&location<s.offset+s.length),word=view.resolveCFI(segment.locator).anchor(doc);
                    word.setStart(word.startContainer,word.startOffset+location-segment.offset);word.setEnd(word.startContainer,word.startOffset+1);
                    const rect=[...word.getClientRects()].find(r=>r.width>0&&r.height>0),frame=doc.defaultView.frameElement.getBoundingClientRect();
                    const x=frame.left+rect.left,y=frame.top+rect.top;
                    rows.push({location,x,y,width:rect.width,height:rect.height,viewport:[innerWidth,innerHeight],
                        visible:x>=-1&&y>=-1&&x+rect.width<=innerWidth+1&&y+rect.height<=innerHeight+1,
                        locator:view.lastLocation.cfi,paint:[...content.overlayer.element.querySelectorAll('[data-leaf-spoken-word] rect')].map(r=>['x','y','width','height'].map(k=>Number(r.getAttribute(k))))});
                }
                return rows;
                """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
            let value = try XCTUnwrap(rows)
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value), uniformTypeIdentifier: "public.json")
            attachment.name = "Long Chinese speech follow scrolling=\(scrolling)"; attachment.lifetime = .keepAlways; add(attachment)
            for row in value {
                XCTAssertEqual(row["visible"] as? Bool, true, "scrolling=\(scrolling) \(row)")
                let paint = row["paint"] as? [[Double]] ?? []
                XCTAssertEqual(paint.count, 1)
                XCTAssertGreaterThan(paint.first?[2] ?? 0, (row["width"] as? Double ?? 0) * 3, "Highlight the rendered line, not a character")
            }
            XCTAssertNil(model.error)
        }
    }
    func testSpokenRangeMapsTrimmedInlineRubyBreaksAndLeavesSavedHighlightsInteractiveInBothFlows() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "窗外")
            let result = try await model.webView?.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'),content=view.renderer.getContents()[0],doc=content.doc,p=doc.querySelector('p');
                p.innerHTML='  Before <em>in</em>line<br><ruby>中<rt>zhong</rt></ruby>文 😀 after.  ';
                const whole=doc.createRange();whole.selectNodeContents(p);
                const packet=await window.Leaf.readAloudChunk({locator:view.getCFI(0,whole)});
                const html=doc.body.innerHTML, before=view.lastLocation.cfi;
                await window.Leaf.setAnnotations({items:[{id:'saved',value:packet.locator,color:'#FFD85C'}]});
                const selected=doc.getSelection();selected.removeAllRanges();selected.addRange(whole);
                const originalSelection=selected.toString();
                const mapped=packet.segments.every(s=>view.resolveCFI(s.locator).anchor(doc).toString()===packet.text.slice(s.offset,s.offset+s.length));
                await window.Leaf.setSpokenRange({passage:packet,locator:packet.locator,location:7,length:6,follow:false});
                const group=content.overlayer.element.querySelector('[data-leaf-spoken-word]');
                const rectangles=[...group.querySelectorAll('rect')],r=rectangles[0];
                const hit=content.overlayer.hitTest({x:Number(r.getAttribute('x'))+1,y:Number(r.getAttribute('y'))+1})[0];
                const spoken=group.getAttribute('data-leaf-spoken-text');
                await window.Leaf.setSpokenRange({locator:packet.locator,location:packet.text.indexOf('😀'),length:2,follow:false});
                const emoji=content.overlayer.element.querySelector('[data-leaf-spoken-word]').getAttribute('data-leaf-spoken-text');
                window.Leaf.clearSpokenRange();
                return {text:packet.text,mapped,spoken,emoji,rectangles:rectangles.length,hit,
                    saved:packet.locator,html:html===doc.body.innerHTML,selection:originalSelection===selected.toString(),
                    samePlace:before===view.lastLocation.cfi,cleared:!content.overlayer.element.querySelector('[data-leaf-spoken-word]'),
                    savedStillPresent:!!content.overlayer.element.querySelector('[data-leaf-highlight="saved"]')};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            let value = try XCTUnwrap(result)
            XCTAssertEqual(value["text"] as? String, "Before inline\n中文 😀 after.")
            XCTAssertEqual(value["spoken"] as? String, "inline"); XCTAssertEqual(value["emoji"] as? String, "😀")
            XCTAssertEqual(value["hit"] as? String, value["saved"] as? String)
            for key in ["mapped", "html", "selection", "samePlace", "cleared", "savedStillPresent"] { XCTAssertEqual(value[key] as? Bool, true, "\(key): \(value)") }
            XCTAssertGreaterThan(value["rectangles"] as? Int ?? 0, 0)
        }
    }
    func testActualChineseSpeechRestoresAnOffscreenOffsetAndKeepsItsWholeLineVisible() async throws {
        let (book, url) = try prepare("SpokenLines.html", format: .html, fixtures: true)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "窗外")
            let web = try XCTUnwrap(model.webView)
            let loaded = try await model.readAloudPassage(at: "section:0")
            let passage = try XCTUnwrap(loaded)
            let name = "RealChineseLine.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            let session = ReadAloudSession(defaults: defaults)
            defer { session.stop(); defaults.removePersistentDomain(forName: name) }
            session.followsText = true; session.speed = 2
            session.source = { [weak model] locator in try await model?.readAloudPassage(at: locator) }
            session.highlight = { [weak model] passage, range, follow in model?.highlightReadAloud(passage, range: range, follow: follow) }
            session.start(at: passage.locator, offset: 650)
            try await waitUntil({ !session.spokenText.isEmpty || session.error != nil }, timeout: 20)
            XCTAssertNil(session.error); XCTAssertFalse(session.spokenText.isEmpty)
            session.pause()
            let offset = try XCTUnwrap(session.bookmark?.offset)
            XCTAssertGreaterThanOrEqual(offset, 650)
            try await Task.sleep(for: .milliseconds(150))
            let value = try await web.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'),content=view.renderer.getContents()[0],doc=content.doc;
                const segment=packet.segments.find(s=>offset>=s.offset&&offset<s.offset+s.length),word=view.resolveCFI(segment.locator).anchor(doc);
                word.setStart(word.startContainer,word.startOffset+offset-segment.offset);word.setEnd(word.startContainer,word.startOffset+1);
                const seed=word.getBoundingClientRect(),frame=doc.defaultView.frameElement.getBoundingClientRect();
                const rect=content.overlayer.element.querySelector('[data-leaf-spoken-line] rect');
                return {x:seed.left+frame.left,y:seed.top+frame.top,visible:seed.left+frame.left>=-1&&seed.right+frame.left<=innerWidth+1&&seed.top+frame.top>=-1&&seed.bottom+frame.top<=innerHeight+1,
                    width:Number(rect?.getAttribute('width')),wordWidth:seed.width,spoken:content.overlayer.element.querySelector('[data-leaf-spoken-line]')?.getAttribute('data-leaf-spoken-text')};
                """, arguments: ["packet": try JSONSerialization.jsonObject(with: JSONEncoder().encode(passage)), "offset": offset], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(value?["visible"] as? Bool, true, "\(value ?? [:])")
            XCTAssertGreaterThan(value?["width"] as? Double ?? 0, (value?["wordWidth"] as? Double ?? 0) * 3)
            let image: UIImage? = await withCheckedContinuation { continuation in web.takeSnapshot(with: nil) { image, error in XCTAssertNil(error); continuation.resume(returning: image) } }
            let screenshot = XCTAttachment(image: try XCTUnwrap(image)); screenshot.name = "Actual Chinese speech full line scrolling=\(scrolling) offset=\(offset)"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
    }
    func testSpokenLinesReflowAtEverySizeInBothViewportOrientationsAndFlows() async throws {
        let (book, url) = try prepare("SpokenLines.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        let web = try XCTUnwrap(model.webView)
        let loaded = try await model.readAloudPassage(at: "section:0")
        let packet = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try XCTUnwrap(loaded)))
        var rows: [[String: Any]] = []
        for viewport in [CGSize(width: 390, height: 720), CGSize(width: 720, height: 390)] {
            window?.frame.size = viewport
            try await Task.sleep(for: .milliseconds(250))
            for scrolling in [false, true] {
                for (variant, font) in ["Georgia", "Palatino", "System"].enumerated() {
                    for size in 12...32 {
                        var prefs = preferences
                        prefs.scrolling = scrolling; prefs.font = font; prefs.fontSize = Double(size)
                        prefs.horizontalMargin = [12, 20, 36][variant]; prefs.verticalMargin = [4, 12, 24][variant]
                        prefs.lineHeight = [1.2, 1.65, 2.1][variant]; prefs.theme = [.day, .paper, .night][variant]
                        let result = try await web.callAsyncJavaScript("""
                            const sleep=ms=>new Promise(r=>setTimeout(r,ms)),view=document.querySelector('foliate-view');
                            window.Leaf.applyPreferences(settings);await sleep(100);
                            await window.Leaf.setSpokenRange({passage:packet,locator:packet.locator,location:650,length:1,follow:true});await sleep(50);
                            const content=view.renderer.getContents()[0],doc=content.doc,segment=packet.segments.find(s=>650>=s.offset&&650<s.offset+s.length);
                            const range=view.resolveCFI(segment.locator).anchor(doc),node=range.startContainer;
                            range.setStart(node,range.startOffset+650-segment.offset);range.setEnd(node,range.startOffset+1);
                            // WebKit can include a zero-width caret on the previous
                            // line/column. Its bounding union is not the glyph box.
                            const glyphRects=[...range.getClientRects()],word=glyphRects.find(r=>r.width>0&&r.height>0),frame=doc.defaultView.frameElement.getBoundingClientRect(),whole=doc.createRange();whole.selectNodeContents(node);
                            const expected=[...whole.getClientRects()].find(r=>Math.abs(r.top-word.top)<1&&r.left<=word.left&&r.right>=word.right);
                            const actual=[...content.overlayer.element.querySelectorAll('[data-leaf-spoken-line] rect')];
                            return {font:settings.font,size:settings.fontSize,scrolling:settings.scrolling,theme:settings.background,viewport:[innerWidth,innerHeight],
                                visible:word.left+frame.left>=-1&&word.right+frame.left<=innerWidth+1&&word.top+frame.top>=-1&&word.bottom+frame.top<=innerHeight+1,
                                exactLine:!!expected&&actual.length===1&&['x','y','width','height'].every((key,i)=>Math.abs(Number(actual[0].getAttribute(key))-expected[['left','top','width','height'][i]])<.8),
                                unchanged:view.resolveCFI(packet.locator).anchor(doc).toString()===packet.text,
                                caret:glyphRects.some(r=>!r.width||!r.height),glyphRects:glyphRects.map(r=>[r.left,r.top,r.width,r.height]),
                                expectedLine:expected&&[expected.left,expected.top,expected.width,expected.height],
                                word:[word.left,word.top,word.width,word.height],paint:actual.map(r=>['x','y','width','height'].map(k=>Number(r.getAttribute(k))))};
                            """, arguments: ["settings": prefs.payload, "packet": packet], in: nil, contentWorld: .page) as? [String: Any]
                        let row = try XCTUnwrap(result); rows.append(row)
                        for key in ["visible", "exactLine", "unchanged"] { XCTAssertEqual(row[key] as? Bool, true, "\(key): \(row)") }
                        let dimensions = row["viewport"] as? [Double] ?? []
                        XCTAssertEqual((dimensions.first ?? 0) > (dimensions.last ?? 0), viewport.width > viewport.height)
                        if [12, 22, 32].contains(size) || (size == 23 && viewport.width > viewport.height && !scrolling && variant == 2) {
                            let image: UIImage? = await withCheckedContinuation { continuation in web.takeSnapshot(with: nil) { image, error in XCTAssertNil(error); continuation.resume(returning: image) } }
                            let screenshot = XCTAttachment(image: try XCTUnwrap(image)); screenshot.name = "Spoken line \(Int(viewport.width))x\(Int(viewport.height)) scroll=\(scrolling) \(font) \(size)pt \(prefs.theme)"; screenshot.lifetime = .keepAlways; add(screenshot)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 252); XCTAssertNil(model.error)
        XCTAssertTrue(rows.contains { $0["caret"] as? Bool == true }, "Exercise actual WebKit caret rectangles at wrapping boundaries")
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
        attachment.name = "Spoken line 252 viewport-flow-font-size-theme measurements"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testSpokenRangeOnlyLoadsColdChaptersWhenFollowingAndLatestRangeWins() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let value = try await model.webView?.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'),first=await window.Leaf.readAloudChunk({locator:'section:2'}),last=await window.Leaf.readAloudChunk({locator:'section:3'});
                const before=view.lastLocation.cfi,loaded=view.renderer.getContents().map(x=>x.index).join(',');
                await window.Leaf.setSpokenRange({passage:last,locator:last.locator,location:3,length:4,follow:false});
                const unchanged=before===view.lastLocation.cfi&&loaded===view.renderer.getContents().map(x=>x.index).join(',');
                const older=window.Leaf.setSpokenRange({passage:first,locator:first.locator,location:3,length:4,follow:true});
                const latest=window.Leaf.setSpokenRange({passage:last,locator:last.locator,location:3,length:4,follow:true});
                await Promise.all([older,latest]);
                const active=view.renderer.getContents().find(x=>x.index===3),group=active?.overlayer.element.querySelector('[data-leaf-spoken-word]');
                const packetText=group?.getAttribute('data-leaf-spoken-text');
                window.Leaf.clearReadAloud();
                return {unchanged,active:!!active,text:packetText,expected:last.text.slice(3,7),
                    cleared:view.renderer.getContents().every(x=>!x.overlayer?.element.querySelector('[data-leaf-spoken-word]'))};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(value?["unchanged"] as? Bool, true)
            XCTAssertEqual(value?["active"] as? Bool, true)
            XCTAssertEqual(value?["text"] as? String, value?["expected"] as? String)
            XCTAssertEqual(value?["cleared"] as? Bool, true)
        }
    }
    func testPDFSpeechHighlightDoesNotReplaceUserSelectionOrSavedAnnotations() async throws {
        let (book, url) = try prepare("Notes from the Coast.pdf", format: .pdf)
        let model = ReaderModel(bookID: book.id, library: try XCTUnwrap(store), initialLocator: nil)
        self.model = model
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        model.configurePDF(view, url: url)
        let page = try XCTUnwrap(view.document?.page(at: 1)), text = try XCTUnwrap(page.string) as NSString
        let town = text.range(of: "town"), before = text.range(of: "Before")
        view.currentSelection = page.selection(for: before)
        let selected = view.currentSelection?.string, annotations = page.annotations.count
        let original = try Data(contentsOf: url)
        let passage = ReadAloudPassage(text: text as String, locator: "pdf:1:0", nextLocator: "pdf:2:0", language: "en", label: "Page 2")
        model.highlightReadAloud(passage, range: town, follow: false)
        let line = try XCTUnwrap(view.highlightedSelections?.first?.string)
        XCTAssertTrue(line.contains("town")); XCTAssertGreaterThan(line.count, 4)
        model.highlightReadAloud(passage, range: NSRange(location: town.location, length: min(200, text.length - town.location)), follow: false)
        XCTAssertEqual(view.highlightedSelections?.first?.string, line, "A sentence callback spanning lines must still highlight only its leading line")
        XCTAssertEqual(view.currentSelection?.string, selected)
        XCTAssertEqual(page.annotations.count, annotations)
        model.highlightReadAloud(nil, range: NSRange(location: 0, length: 0), follow: false)
        XCTAssertNil(view.highlightedSelections); XCTAssertEqual(view.currentSelection?.string, selected)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testReadAloudStartsAtExactSelectionInBothFlowsAndKeepsChatAndBookmarks() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let web = try XCTUnwrap(model.webView)
            model.toggleBookmark(); let bookmarks = model.book?.bookmarks
            let value = try await web.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'), doc=view.renderer.getContents()[0].doc;
                const p=[...doc.querySelectorAll('p')].find(p=>p.textContent.includes('Attention'));
                const node=p.firstChild, start=node.data.indexOf('way');
                const range=doc.createRange(); range.setStart(node,start);range.setEnd(node,start+3);
                const selection=doc.getSelection(); selection.removeAllRanges();selection.addRange(range);
                const snapshot=window.Leaf.chatContext(), before=view.lastLocation.cfi;
                const chunk=await window.Leaf.readAloudChunk({locator:snapshot.locator});
                const target=view.resolveCFI(chunk.locator), text=target.anchor(doc).toString();
                return {chunk,rangeText:text,before,after:view.lastLocation.cfi,selection:window.Leaf.chatContext().text};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            let result = try XCTUnwrap(value), chunk = try XCTUnwrap(result["chunk"] as? [String: Any])
            XCTAssertTrue((chunk["text"] as? String)?.hasPrefix("way of arriving") == true, "\(result)")
            XCTAssertEqual((result["rangeText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), chunk["text"] as? String)
            XCTAssertEqual(result["before"] as? String, result["after"] as? String)
            XCTAssertEqual(result["selection"] as? String, "way")
            XCTAssertEqual(model.book?.bookmarks, bookmarks)
            let parsed = try await model.readAloudPassage(at: chunk["locator"] as? String)
            XCTAssertEqual(parsed?.text, chunk["text"] as? String)
            _ = try await model.webView?.evaluateJavaScript("window.Leaf.close()")
        }
    }
    func testReadAloudTraversesEveryChapterLazilyWithoutMovingReadingViewport() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let result = try await model.webView?.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view');
                const before=view.lastLocation.cfi, visited=new Set(), cursors=new Set(), parsed=[];
                for(const [index,section] of view.book.sections.entries()) {
                    const create=section.createDocument;
                    if(create)section.createDocument=()=>{parsed[index]=(parsed[index]??0)+1;return create();};
                }
                let locator='section:0', count=0, longest=0, maxDocuments=0, ended=false;
                for (;count<1000;++count) {
                    const chunk=await window.Leaf.readAloudChunk({locator});
                    if (!chunk) {ended=true;break;}
                    if(cursors.has(chunk.locator)) throw new Error('Repeated listening cursor');
                    cursors.add(chunk.locator);visited.add(chunk.index);longest=Math.max(longest,chunk.text.length);
                    maxDocuments=Math.max(maxDocuments,view.renderer.getContents().length);
                    locator=chunk.nextLocator;
                }
                return {ended,count,longest,maxDocuments,parsed:Array.from({length:view.book.sections.length},(_,i)=>parsed[i]??0),visited:[...visited],sections:view.book.sections.length,
                    before,after:view.lastLocation.cfi};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            let value = try XCTUnwrap(result)
            XCTAssertEqual(value["ended"] as? Bool, true); XCTAssertGreaterThan(value["count"] as? Int ?? 0, 4)
            XCTAssertEqual(value["visited"] as? [Int], [0, 1, 2, 3], "\(value)")
            XCTAssertLessThanOrEqual(value["longest"] as? Int ?? 9999, 800)
            XCTAssertLessThanOrEqual(value["maxDocuments"] as? Int ?? 99, scrolling ? 3 : 1)
            XCTAssertEqual(value["before"] as? String, value["after"] as? String)
            XCTAssertTrue((value["parsed"] as? [Int] ?? []).allSatisfy { $0 <= 1 }, "A chapter must not be reparsed for each spoken paragraph: \(value)")
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: value), uniformTypeIdentifier: "public.json")
            attachment.name = "Read aloud lazy traversal scrolling=\(scrolling)"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    func testReadAloudSessionFollowsAcrossRealChapterBoundariesAndRestoresSavedCursor() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let speaker = RecordingSpeaker()
            let bookmarkURL = try XCTUnwrap(root).appendingPathComponent("speech-\(scrolling).json")
            let name = "SpeechEngine.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            let session = ReadAloudSession(bookmarkURL: bookmarkURL, defaults: defaults, speaker: speaker)
            session.followsText = true
            session.source = { [weak model] locator in try await model?.readAloudPassage(at: locator) }
            session.reveal = { [weak model] locator in await model?.revealReadAloud(at: locator) }
            let oldChapter = model.chapterTitle
            session.start(at: model.locator)
            try await waitUntil { session.state == .playing }
            var reached = false
            for _ in 0..<80 {
                let prior = session.passage?.locator
                speaker.finished?()
                try await waitUntil { session.passage?.locator != prior || session.state == .finished || session.state == .failed }
                if model.chapterTitle != oldChapter { reached = true; break }
            }
            XCTAssertTrue(reached, "Spoken passages must cross an actual chapter boundary in scrolling=\(scrolling)")
            XCTAssertNil(session.error)
            session.pause()
            let saved = try XCTUnwrap(session.bookmark)
            session.stop()
            let reopened = ReadAloudSession(bookmarkURL: bookmarkURL, defaults: defaults, speaker: RecordingSpeaker())
            reopened.source = session.source; reopened.reveal = session.reveal
            reopened.resumeSaved(); try await waitUntil { reopened.state == .playing }
            XCTAssertEqual(reopened.passage?.locator, saved.locator)
            let encoded = String(decoding: try JSONEncoder().encode(saved.locator), as: UTF8.self)
            // Source restoration is exact even while native reveal finishes asynchronously.
            let restored = try await model.readAloudPassage(at: saved.locator)
            XCTAssertEqual(restored?.text, reopened.passage?.text)
            await model.revealReadAloud(at: saved.locator)
            let visible = try await model.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(encoded))") as? Bool
            XCTAssertEqual(visible, true)
            reopened.stop()
        }
    }
    func testReadAloudPreservesInlineWordsChineseAndEmojiAcrossChunkBoundariesAndReflow() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "窗外")
            let web = try XCTUnwrap(model.webView)
            let result = try await web.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'),doc=view.renderer.getContents()[0].doc;
                const p=doc.querySelector('p');p.innerHTML='First <em>inline</em> words. <span hidden>NEVER SPEAK</span>'+ '中😀'.repeat(600);
                let locator=view.getCFI(0,(()=>{const r=doc.createRange();r.selectNodeContents(p);return r;})());
                let combined='',chunks=0,splitSurrogate=false;
                for(;chunks<20;++chunks){const c=await window.Leaf.readAloudChunk({locator});
                    if(!c||c.label==='stop')break;
                    combined+=c.text;locator=c.nextLocator;
                    splitSurrogate ||= /[\\uD800-\\uDBFF]$/.test(c.text)||/^[\\uDC00-\\uDFFF]/.test(c.text);
                    if(combined.endsWith('中😀'.repeat(3))&&combined.length>=1820)break;
                }
                return {combined,chunks,splitSurrogate};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            let value = try XCTUnwrap(result), text = try XCTUnwrap(value["combined"] as? String)
            XCTAssertTrue(text.hasPrefix("First inline words. "), "\(text.prefix(60))")
            XCTAssertFalse(text.contains("NEVER SPEAK")); XCTAssertEqual(value["splitSurrogate"] as? Bool, false)
            XCTAssertTrue(text.contains(String(repeating: "中😀", count: 600)), "No characters may disappear between chunks")
        }
    }
    func testDetachedSpeechDocumentUsesTheSameSanitizedCFIPositionsAsRenderedText() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'); await view.goTo(2);
            const content=view.renderer.getContents()[0],doc=content.doc,p=doc.querySelector('p');
            const walker=doc.createTreeWalker(p,NodeFilter.SHOW_TEXT);const node=walker.nextNode();
            const range=doc.createRange();range.setStart(node,5);range.setEnd(node,10);
            const locator=view.getCFI(content.index,range),expected=node.data.slice(5);
            await view.goTo(0);window.Leaf.clearReadAloud();
            const section=view.book.sections[content.index],create=section.createDocument;
            section.createDocument=async()=>{const raw=await create();const script=raw.createElement('script');
                script.textContent='DO NOT READ';raw.body.prepend(script);return raw;};
            const chunk=await window.Leaf.readAloudChunk({locator});
            return {expected,text:chunk.text,index:chunk.index,active:view.renderer.getContents()[0].index};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let value = try XCTUnwrap(result)
        XCTAssertEqual(value["text"] as? String, (value["expected"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(value["index"] as? Int, 2); XCTAssertEqual(value["active"] as? Int, 0)
    }
    func testRapidSpokenPassageFollowingFinishesAtLatestColdChapter() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view');
            const earlier=await window.Leaf.readAloudChunk({locator:'section:2'});
            const latest=await window.Leaf.readAloudChunk({locator:'section:3'});
            const section=view.book.sections[2],load=section.load;
            section.load=async()=>{await new Promise(r=>setTimeout(r,100));return load();};
            const first=window.Leaf.revealReadAloud({locator:earlier.locator});
            await new Promise(r=>setTimeout(r,10));
            await Promise.all([first,window.Leaf.revealReadAloud({locator:latest.locator})]);
            return {active:view.renderer.getContents()[0].index,visible:window.Leaf.isLocationVisible(latest.locator)};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["active"] as? Int, 3); XCTAssertEqual(result?["visible"] as? Bool, true)
    }
    func testReadAloudKeepsHardLineBreaksWithoutChangingInlineWordsOrCFIsInBothFlows() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "窗外")
            let result = try await model.webView?.callAsyncJavaScript("""
                const view=document.querySelector('foliate-view'),doc=view.renderer.getContents()[0].doc,p=doc.querySelector('p');
                p.innerHTML='Before<br>after <em>inline</em> text.';
                const range=doc.createRange();range.selectNodeContents(p);
                const locator=view.getCFI(0,range),chunk=await window.Leaf.readAloudChunk({locator});
                const repeated=await window.Leaf.readAloudChunk({locator:chunk.locator});
                return {spoken:chunk.text,repeated:repeated.text,original:p.textContent,
                    rangeText:view.resolveCFI(chunk.locator).anchor(doc).toString()};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: String]
            XCTAssertEqual(result?["spoken"], "Before\nafter inline text.", "Hard line breaks must not glue neighboring words")
            XCTAssertEqual(result?["repeated"], result?["spoken"])
            XCTAssertEqual(result?["original"], "Beforeafter inline text.")
            XCTAssertEqual(result?["rangeText"], result?["original"], "The original DOM and CFI character offsets must stay intact")
        }
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
                const snapshot=()=>{const contents=r.getContents(),doc=contents[0]?.doc,container=doc?.defaultView?.frameElement?.parentElement?.parentElement;return {active:contents[0]?.index,top:container?.scrollTop,max:container?container.scrollHeight-container.clientHeight:0,endSpace:container?.style.getPropertyValue('--leaf-book-end-space'),frames:contents.map(x=>({index:x.index,y:x.doc?.defaultView?.frameElement?.parentElement?.getBoundingClientRect().top,height:x.doc?.defaultView?.frameElement?.parentElement?.getBoundingClientRect().height}))};};
                await view.goTo(1); r.scrollToAnchor(1); await sleep(100); await r.next(); await sleep(100);
                const forward = r.getContents()[0].index;
                r.scrollToAnchor(0); await sleep(100); await r.prev(); await sleep(100);
                const backward = r.getContents()[0].index;
                await view.goTo(0); r.scrollToAnchor(0); await sleep(100); await r.prev();
                const beginning = r.getContents()[0].index;
                const last = view.book.sections.length - 1;
                await view.goTo(last); r.scrollToAnchor(1); await sleep(100); await r.next();
                const end = r.getContents()[0].index,endState=snapshot();
                await view.goTo(1); r.scrollToAnchor(0.35); await sleep(100);
                return {forward,backward,beginning,end,last,documents:r.getContents().length,endState};
                """, arguments: [:], in: nil, contentWorld: .page)
            let metrics = try XCTUnwrap(result as? [String: Any])
            let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:metrics),uniformTypeIdentifier:"public.json");attachment.name="Boundary trace scrolling=\(scrolling)";attachment.lifetime = .keepAlways;add(attachment)
            XCTAssertEqual(metrics["forward"] as? Int, 2, "scrolling=\(scrolling)")
            XCTAssertEqual(metrics["backward"] as? Int, 1, "scrolling=\(scrolling)")
            XCTAssertEqual(metrics["beginning"] as? Int, 0)
            XCTAssertEqual(metrics["end"] as? Int, metrics["last"] as? Int, "scrolling=\(scrolling), \(metrics)")
            XCTAssertLessThanOrEqual(metrics["documents"] as? Int ?? 99, scrolling ? 3 : 1)
            let locator = model.locator
            model.toggleBookmark(); store?.flush()
            model.webView?.stopLoading(); window?.isHidden = true; window = nil
            let reopened = try show(book, url: url, locator: locator, readerPreferences: prefs)
            try await waitUntil { reopened.isReady || reopened.error != nil }
            XCTAssertNil(reopened.error)
            let encoded = String(decoding: try JSONEncoder().encode(locator), as: UTF8.self)
            let visible = try await reopened.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(encoded))") as? Bool
            if visible != true {
                let diagnostic=try await reopened.webView?.evaluateJavaScript("""
                    (()=>{const view=document.querySelector('foliate-view'),r=view.renderer,target=view.resolveCFI(\(encoded)),content=r.getContents().find(c=>c.index===target.index),doc=content?.doc,range=doc&&target.anchor(doc),current=view.lastLocation?.range;
                    const rects=value=>[...(value?.getClientRects()??[])].slice(0,4).map(({x,y,width,height})=>({x,y,width,height}));
                    const point=range?.cloneRange();point?.collapse(true);
                    if(point?.startContainer.nodeType===3&&point.startOffset<point.startContainer.length)point.setEnd(point.startContainer,point.startOffset+1);
                    const frame=doc?.defaultView.frameElement,container=frame?.parentElement.parentElement;
                    return JSON.stringify({saved:\(encoded),current:view.lastLocation?.cfi,index:r.getContents()[0]?.index,targetIndex:target.index,top:container?.scrollTop,frameY:frame?.getBoundingClientRect().top,
                        margin:r.getAttribute('margin'),font:doc&&doc.defaultView.getComputedStyle(doc.documentElement).fontSize,
                        savedStart:range&&{node:range.startContainer.nodeName,offset:range.startOffset},currentStart:current&&{node:current.startContainer.nodeName,offset:current.startOffset},
                        savedRects:rects(range),pointRects:rects(point),currentRects:rects(current)});})()
                    """) as? String
                let attachment=XCTAttachment(string:diagnostic ?? "No reopened geometry")
                attachment.name="Reopened CFI failure geometry scrolling=\(scrolling)";attachment.lifetime = .keepAlways;add(attachment)
            }
            XCTAssertEqual(visible, true, "scrolling=\(scrolling), locator=\(locator)")
            XCTAssertTrue(store?.book(book.id)?.bookmarks.contains { $0.locator == locator } == true)
            reopened.webView?.stopLoading(); window?.isHidden = true; window = nil
        }
    }
    func testScrollRestoresCFIStartingAtAZeroWidthLineBreak() async throws {
        let (book,url)=try prepare("The Art of Noticing.epub",format:.epub)
        var prefs=preferences;prefs.scrolling=true
        let model=try show(book,url:url,readerPreferences:prefs)
        try await assertOpened(model,contains:"attention")
        let result=try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view');await view.goTo(1);
            const doc=view.renderer.getContents()[0].doc,walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);
            for(let node=walker.nextNode();node;node=walker.nextNode())for(let offset=1;offset<node.length-1;offset++){
                const point=doc.createRange();point.setStart(node,offset);point.setEnd(node,offset+1);
                const rect=point.getClientRects()[0];
                if(!rect||rect.width!==0||rect.height<=0)continue;
                const next=doc.createRange();next.setStart(node,offset+1);next.setEnd(node,offset+2);
                const following=next.getClientRects()[0];
                if(!following||following.width<=0||following.top<rect.top+rect.height/2)continue;
                point.setEnd(node,Math.min(node.length,offset+60));
                return {locator:view.getCFI(1,point),text:point.toString()};
            }
            throw new Error('Fixture has no zero-width line-break CFI');
            """,arguments:[:],in:nil,contentWorld:.page)
        let state=try XCTUnwrap(result as? [String:String]),locator=try XCTUnwrap(state["locator"])
        model.webView?.stopLoading();window?.isHidden=true;window=nil
        let reopened=try show(book,url:url,locator:locator,readerPreferences:prefs)
        try await waitUntil {reopened.isReady||reopened.error != nil}
        XCTAssertNil(reopened.error)
        let encoded=String(decoding:try JSONEncoder().encode(locator),as:UTF8.self)
        let restored=try await reopened.webView?.evaluateJavaScript("""
            (()=>{const view=document.querySelector('foliate-view'),target=view.resolveCFI(\(encoded)),doc=view.renderer.getContents().find(c=>c.index===target.index).doc,range=target.anchor(doc),rect=range.getClientRects()[0];
            return {visible:window.Leaf.isLocationVisible(\(encoded)),text:range.toString(),width:rect.width,top:rect.top+doc.defaultView.frameElement.getBoundingClientRect().top};})()
            """) as? [String:Any]
        XCTAssertEqual(restored?["visible"] as? Bool,true,"\(restored ?? [:])")
        XCTAssertEqual(restored?["text"] as? String,state["text"])
        XCTAssertEqual(restored?["width"] as? Double,0)
        XCTAssertGreaterThanOrEqual(restored?["top"] as? Double ?? -999,0)
    }

    func testHeadingRangeCFIRestoresInBothFlows() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        // The first visible range starts at an element boundary, not a text offset.
        let locator = "epubcfi(/6/2!/4,/2,/8/1:243)"
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, locator: locator, readerPreferences: prefs)
            try await waitUntil { model.isReady || model.error != nil }
            let state = try await model.webView?.evaluateJavaScript("""
                JSON.stringify({ready:document.readyState,leaf:!!window.Leaf,
                  view:!!document.querySelector('foliate-view'),
                  contents:document.querySelector('foliate-view')?.renderer?.getContents()?.map(c=>({index:c.index,text:c.doc.body?.textContent.slice(0,100)})),
                  visible:window.Leaf?.isLocationVisible('epubcfi(/6/2!/4,/2,/8/1:243)')})
                """) as? String
            let attachment = XCTAttachment(string: state ?? "No JavaScript state")
            attachment.name = "Heading CFI restore scrolling=\(scrolling)"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertTrue(model.isReady, state ?? "")
            XCTAssertNil(model.error)
            let visible = try await model.webView?.evaluateJavaScript("window.Leaf.isLocationVisible('epubcfi(/6/2!/4,/2,/8/1:243)')") as? Bool
            XCTAssertEqual(visible, true, state ?? "")
            model.webView?.stopLoading(); window?.isHidden = true; window = nil
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
    func testSelectionCleanupStillClosesBookAfterNativeBridgeIsDetached() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "attention")
        let web = try XCTUnwrap(model.webView)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "leaf")
        let closed = try await web.evaluateJavaScript("window.Leaf.close(); document.querySelector('foliate-view') === null") as? Bool
        XCTAssertEqual(closed, true, "Selection notifications must not interrupt releasing a book after its message handler is removed")
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
        try await waitUntil { model.selectedReadingContext()?.text == selected }
        model.askAboutSelection(.explain, context: try XCTUnwrap(model.selectedReadingContext()))
        _ = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents()[0].doc.getSelection().removeAllRanges()")
        try await waitUntil { model.selectedReadingContext() == nil }
        XCTAssertEqual(model.selectionRequest?.context.text, selected, "The menu action keeps a stable selection snapshot")
        XCTAssertEqual(model.locator, location)
    }
    func testHighlightsKeepExactCFITextAndGeometryAtEverySizeInBothFlows() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        _ = try await waitForLayout(model, preferences: preferences)
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("""
            (() => {
                const {doc} = document.querySelector('foliate-view').renderer.getContents()[0];
                const node = doc.querySelector('p').firstChild, range = doc.createRange();
                range.setStart(node, 3); range.setEnd(node, 24);
                const selected = doc.getSelection(); selected.removeAllRanges(); selected.addRange(range);
            })()
            """)
        try await waitUntil { model.selectedAnnotationSelection() != nil }
        let selection = try XCTUnwrap(model.selectedAnnotationSelection()), before = model.locator
        model.annotateSelection(.highlight, selection: selection)
        let annotation = try XCTUnwrap(store?.book(book.id)?.annotations.first)
        let result = try await web.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view'), sleep = ms => new Promise(r => setTimeout(r, ms));
            const originalText = view.renderer.getContents()[0].doc.body.textContent, rows = [];
            const speech=await window.Leaf.readAloudChunk({locator:anchor});
            await window.Leaf.setSpokenRange({passage:speech,locator:speech.locator,location:0,length:6,follow:false});
            for (const [variant, font] of ['Georgia', 'Palatino', 'System'].entries()) {
              for (const scrolling of [false, true]) {
                for (let size = 12; size <= 32; size++) {
                    window.Leaf.applyPreferences({...base, scrolling, fontSize:size, font,
                        horizontalMargin:[12,20,36][variant], background:['#FFFFFF','#F4EDDD','#17232E'][variant],
                        foreground:['#263440','#493F30','#D7DEE4'][variant], colorScheme:variant === 2 ? 'dark' : 'light'});
                    await sleep(160);
                    const content = view.renderer.getContents().find(c => c.index === view.resolveCFI(anchor).index);
                    const range = view.resolveCFI(anchor).anchor(content.doc);
                    const actual = [...content.overlayer.element.querySelectorAll(`[data-leaf-highlight="${id}"] rect`)];
                    const expected = [...range.getClientRects()];
                    const sameBounds = actual.length === expected.length && actual.every((rect, i) =>
                        ['x','y','width','height'].every((name,j) => Math.abs(Number(rect.getAttribute(name)) - expected[i][['left','top','width','height'][j]]) < 0.75));
                    const spokenRange=view.resolveCFI(speech.segments[0].locator).anchor(content.doc);
                    spokenRange.setEnd(spokenRange.startContainer,spokenRange.startOffset+6);
                    const seed=spokenRange.getClientRects()[0],all=content.doc.createRange();all.selectNodeContents(spokenRange.startContainer);
                    const fragments=[...all.getClientRects()].filter(r=>Math.abs(r.top-seed.top)<1&&r.left<=seed.right&&r.right>=seed.left);
                    const expectedLine=fragments[0],spokenActual=[...content.overlayer.element.querySelectorAll('[data-leaf-spoken-line] rect')];
                    const spokenBounds=!!expectedLine&&spokenActual.length===1&&
                        ['x','y','width','height'].every((name,j)=>Math.abs(Number(spokenActual[0].getAttribute(name))-expectedLine[['left','top','width','height'][j]])<0.75);
                    rows.push({font, scrolling, size, quote:range.toString() === quote,
                        text:content.doc.body.textContent === originalText, sameBounds, spokenBounds, rectangles:actual.length});
                }
              }
            }
            return rows;
            """, arguments: ["base": preferences.payload, "anchor": annotation.locator, "id": annotation.id.uuidString, "quote": selection.text], in: nil, contentWorld: .page)
        let rows = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(rows.count, 126)
        for row in rows {
            XCTAssertEqual(row["quote"] as? Bool, true, "\(row)")
            XCTAssertEqual(row["text"] as? Bool, true, "\(row)")
            XCTAssertEqual(row["sameBounds"] as? Bool, true, "\(row)")
            XCTAssertEqual(row["spokenBounds"] as? Bool, true, "\(row)")
            XCTAssertGreaterThan(row["rectangles"] as? Int ?? 0, 0, "\(row)")
        }
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(store?.book(book.id)?.annotations.first?.locator, selection.locator)
        XCTAssertNil(model.error)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
        attachment.name = "126 exact highlight ranges across fonts sizes themes margins and flows"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testHighlightsAndNotesRestoreAcrossLazyChaptersAndReaderReopenInBothFlows() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        for scrolling in [false, true] {
            var prefs = preferences; prefs.scrolling = scrolling
            let model = try show(book, url: url, readerPreferences: prefs)
            try await assertOpened(model, contains: "attention")
            let web = try XCTUnwrap(model.webView)
            _ = try await web.evaluateJavaScript("""
                (() => { const {doc} = document.querySelector('foliate-view').renderer.getContents()[0];
                    const range = doc.createRange(); range.selectNodeContents(doc.querySelector('p'));
                    const selection = doc.getSelection(); selection.removeAllRanges(); selection.addRange(range); })()
                """)
            try await waitUntil { model.selectedAnnotationSelection() != nil }
            let selection = try XCTUnwrap(model.selectedAnnotationSelection())
            model.annotateSelection(.note, selection: selection)
            var saved = try XCTUnwrap(model.annotationDraft); saved.note = "A note that survives closing the book"; saved.color = .green
            try model.saveAnnotation(saved); model.annotationDraft = nil
            let state = try await web.callAsyncJavaScript("""
                const view = document.querySelector('foliate-view'), sleep = ms => new Promise(r => setTimeout(r, ms));
                const initialDocuments = view.renderer.getContents().length;
                const unloaded = view.getCFI(view.book.sections.length - 1);
                await window.Leaf.setAnnotations({items:[...items, {id:'unloaded-test',value:unloaded,color:'#F2C94C'}]});
                const noExtraLoads = view.renderer.getContents().length === initialDocuments;
                await window.Leaf.setAnnotations({items});
                await view.goTo(1); await sleep(180); await view.goTo(anchor); await sleep(180);
                const content = view.renderer.getContents().find(c => c.index === view.resolveCFI(anchor).index);
                return {noExtraLoads, documents:view.renderer.getContents().length,
                    exact: view.resolveCFI(anchor).anchor(content.doc).toString() === quote,
                    rendered: content.overlayer.element.querySelectorAll('[data-leaf-highlight]').length};
                """, arguments: ["items": [saved.webPayload], "anchor": saved.locator, "quote": saved.text], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(state as? [String: Any])
            XCTAssertEqual(values["noExtraLoads"] as? Bool, true)
            XCTAssertLessThanOrEqual(values["documents"] as? Int ?? 100, 3)
            XCTAssertEqual(values["exact"] as? Bool, true)
            XCTAssertEqual(values["rendered"] as? Int, 1)
            model.webView?.stopLoading(); window?.isHidden = true; window = nil
            let reopened = try show(book, url: url, locator: saved.locator, readerPreferences: prefs)
            try await waitUntil { reopened.isReady || reopened.error != nil }
            let encoded = String(decoding: try JSONEncoder().encode(saved.locator), as: UTF8.self)
            let visible = try await reopened.webView?.evaluateJavaScript("window.Leaf.isLocationVisible(\(encoded))") as? Bool
            XCTAssertEqual(visible, true)
            XCTAssertEqual(store?.book(book.id)?.annotations.first?.note, saved.note)
            try reopened.removeAnnotation(saved.id)
            let removed = try await reopened.webView?.callAsyncJavaScript("await new Promise(r=>setTimeout(r,150)); return document.querySelector('foliate-view').renderer.getContents().every(c=>!c.overlayer?.element.querySelector('[data-leaf-highlight]'));", arguments: [:], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(removed, true)
            reopened.webView?.stopLoading(); window?.isHidden = true; window = nil
        }
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
        XCTAssertEqual(model.selectedReadingContext()?.text, selection.text)
        try await waitUntil { model.liveSelection == selection }
        view.clearSelection()
        XCTAssertNil(model.selectedReadingContext())
        try await waitUntil { model.liveSelection == nil }
    }
    func testClosingPDFChatClearsNativeSelectionButKeepsQuote() async throws {
        let (book, url) = try prepare("Notes from the Coast.pdf", format:.pdf)
        let model = ReaderModel(bookID:book.id,library:try XCTUnwrap(store),initialLocator:nil)
        self.model = model
        let view = PDFView(frame:CGRect(x:0,y:0,width:390,height:700))
        model.configurePDF(view,url:url)
        let page = try XCTUnwrap(view.currentPage)
        view.currentSelection = page.selection(for:page.bounds(for:.cropBox))
        try await waitUntil { model.liveSelection != nil }
        let chat = ReaderChatSession()
        chat.attachLiveSelection(model.liveSelection,chatIsPresented:true)
        let quote = chat.selectedContext
        let tap = CenteredReaderTestTap();view.addGestureRecognizer(tap)
        let coordinator = PDFBookSurface.Coordinator(model)
        model.clearNativeSelection()
        try await waitUntil { model.liveSelection == nil }
        chat.attachLiveSelection(model.liveSelection,chatIsPresented:false)
        XCTAssertNil(view.currentSelection)
        XCTAssertFalse(model.controlsVisible)
        XCTAssertEqual(chat.selectedContext,quote,"Clearing PDF selection keeps the saved chat quote")
        coordinator.tapped(tap)
        XCTAssertTrue(model.controlsVisible,"The first center tap after closing chat must show reader controls")
    }
    func testLiveSelectionTracksWebRangeChangesInBothFlowsWithoutMovingPassage() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        for scrolling in [false, true] {
            var value = preferences; value.scrolling = scrolling
            let model = try show(book,url:url,readerPreferences:value)
            try await assertOpened(model,contains:"窗外")
            let web = try XCTUnwrap(model.webView)
            let flow = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getAttribute('flow')") as? String
            XCTAssertEqual(flow,scrolling ? "scrolled" : "paginated")
            let location = model.locator
            for index in 0..<4 {
                let snapshot = try await web.evaluateJavaScript("""
                    (() => {
                        const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc;
                        const paragraphs = doc.querySelectorAll('p');
                        const range = doc.createRange();
                        if (\(index) === 1) { range.setStart(paragraphs[0].firstChild,5); range.setEnd(paragraphs[0].firstChild,20); }
                        else if (\(index) === 3) { range.setStart(paragraphs[0],0); range.setEnd(paragraphs[1].firstChild,12); }
                        else range.selectNodeContents(paragraphs[\(index) === 2 ? 1 : 0]);
                        const selection = doc.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                        return { selectedText:selection.toString(), rangeText:range.toString() };
                    })()
                    """) as? [String:String]
                let selected = try XCTUnwrap(snapshot?["selectedText"])
                try await waitUntil { model.liveSelection?.text == selected }
                XCTAssertEqual(model.liveSelection?.source, "selection")
                let quoteLocator = try XCTUnwrap(model.liveSelection?.locator)
                let encoded = String(decoding:try JSONEncoder().encode(quoteLocator),as:UTF8.self)
                let anchored = try await web.evaluateJavaScript("""
                    (() => {
                        const view = document.querySelector('foliate-view');
                        const resolved = view.resolveCFI(\(encoded));
                        const doc = view.renderer.getContents().find(item => item.index === resolved.index).doc;
                        return resolved.anchor(doc).toString();
                    })()
                    """) as? String
                // Selection.toString() adds visual paragraph breaks that Range.toString()
                // does not. Validate the exact original DOM range as well as quoted text.
                XCTAssertEqual(anchored,snapshot?["rangeText"],"The quote CFI must identify the selected range, not just the viewport")
                XCTAssertEqual(model.locator, location, "Quoting must not navigate or change the viewport")
            }
            _ = try await web.evaluateJavaScript("window.Leaf.clearSelection()")
            try await waitUntil { model.liveSelection == nil }
            model.webView?.stopLoading();window?.isHidden = true;window = nil
        }
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
    func testScrollWindowCrossesReadyChapterEdgesWithoutReplacingDocuments() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        var prefs = preferences; prefs.scrolling = true
        let model = try show(book, url: url, readerPreferences: prefs)
        try await assertOpened(model, contains: "attention")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view = document.querySelector('foliate-view'), r = view.renderer;
            const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
            const ready = async indices => {
                const until = performance.now()+8000;
                while(performance.now()<until) {
                    if(indices.every(i=>r.getContents().some(x=>x.index===i && x.doc.readyState==='complete' && x.doc.URL!=='about:blank'))) { await sleep(60);return; }
                    await sleep(20);
                }
                throw new Error('Nearby chapter window not ready: '+JSON.stringify(r.getContents().map(x=>x.index)));
            };
            await view.goTo(1); await ready([0,1,2]);
            const first = r.getContents().find(x=>x.index===1).doc;
            const nextContent = r.getContents().find(x=>x.index===2),next = nextContent.doc;
            const {Overlayer}=await import('./foliate/overlayer.js');
            const marker=next.createRange(),node=next.querySelector('p').firstChild;
            marker.setStart(node,2);marker.setEnd(node,12);
            nextContent.overlayer.add('continuous-marker',marker,Overlayer.highlight);
            const container = first.defaultView.frameElement.parentElement.parentElement;
            const offset = doc=>doc.defaultView.frameElement.parentElement.getBoundingClientRect().top-container.getBoundingClientRect().top+container.scrollTop;
            const boundary = offset(next);
            container.scrollTop=boundary-container.clientHeight/2;await sleep(80);
            const overlap = first.defaultView.frameElement.getBoundingClientRect().bottom>container.getBoundingClientRect().top
                && next.defaultView.frameElement.getBoundingClientRect().top<container.getBoundingClientRect().bottom;
            const before = next.defaultView.frameElement.getBoundingClientRect().top;
            container.scrollTop+=container.clientHeight/2+40;
            await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);
            const forward = r.getContents()[0].index;
            const glyph=marker.getClientRects()[0],highlight=nextContent.overlayer.element.querySelector('rect').getBoundingClientRect();
            const overlayOffset=highlight.top-next.defaultView.frameElement.getBoundingClientRect().top-glyph.top;
            const overlayHit=nextContent.overlayer.hitTest({x:glyph.left+1,y:glyph.top+1})[0];
            const markerCFI=view.getCFI(2,marker),sameMarker=view.resolveCFI(markerCFI).anchor(next).toString()===marker.toString();
            const retained = r.getContents()[0].doc===next && first.defaultView.frameElement?.isConnected;
            const movement = before-next.defaultView.frameElement.getBoundingClientRect().top;
            const maxDocuments=r.getContents().length;
            container.scrollTop=offset(first)+40;await sleep(100);
            const backward=r.getContents()[0].index;
            const restoredDocument=r.getContents()[0].doc===first;
            await view.goTo(0);r.scrollToAnchor(0);await sleep(100);await r.prev();
            const beginning=r.getContents()[0].index;
            const last=view.book.sections.length-1;await view.goTo(last);r.scrollToAnchor(1);await sleep(100);await r.next();
            return {overlap,forward,retained,movement,overlayOffset,overlayHit,sameMarker,expected:container.clientHeight/2+40,maxDocuments,backward,restoredDocument,beginning,end:r.getContents()[0].index,last};
            """, arguments: [:], in: nil, contentWorld: .page)
        let metrics = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(metrics["overlap"] as? Bool, true, "Both chapters must share a viewport before crossing")
        XCTAssertEqual(metrics["forward"] as? Int, 2)
        XCTAssertEqual(metrics["retained"] as? Bool, true, "Crossing must reuse the prepared document")
        XCTAssertEqual(metrics["overlayOffset"] as? Double ?? 999,0,accuracy:1,"A prepared chapter’s highlight must align with its text")
        XCTAssertEqual(metrics["overlayHit"] as? String,"continuous-marker")
        XCTAssertEqual(metrics["sameMarker"] as? Bool,true)
        XCTAssertEqual(metrics["movement"] as? Double ?? 0, metrics["expected"] as? Double ?? 999, accuracy: 3)
        XCTAssertLessThanOrEqual(metrics["maxDocuments"] as? Int ?? 99, 3)
        XCTAssertEqual(metrics["backward"] as? Int, 1)
        XCTAssertEqual(metrics["restoredDocument"] as? Bool, true)
        XCTAssertEqual(metrics["beginning"] as? Int, 0)
        XCTAssertEqual(metrics["end"] as? Int, metrics["last"] as? Int)
        XCTAssertNil(model.error)
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:metrics),uniformTypeIdentifier:"public.json")
        attachment.name="Continuous chapter boundary geometry";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testDelayedPreviousChapterKeepsFinalPassageDuringEndNavigation() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        var prefs = preferences; prefs.scrolling = true
        let model = try show(book, url: url, readerPreferences: prefs)
        try await assertOpened(model, contains: "attention")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            const last=view.book.sections.length-1,previous=view.book.sections[last-1],load=previous.load,rows=[];
            const ready=async indices=>{const end=performance.now()+8000;while(performance.now()<end){if(indices.every(i=>r.getContents().some(c=>c.index===i&&c.doc?.body)))return;await sleep(10);}throw new Error('Delayed neighbor not ready');};
            try {
                for(const delay of [40,90,130,210]){
                    previous.load=load;
                    await view.goTo(0);await ready([0,1]);
                    previous.load=async()=>{await sleep(delay);return load();};
                    await view.goTo(last);await r.scrollToAnchor(1);
                    const doc=r.getContents()[0].doc,frame=doc.defaultView.frameElement;
                    const marker=view.lastLocation.range.cloneRange();
                    if(marker.startContainer.nodeType===3)marker.setStart(marker.startContainer,Math.min(marker.startContainer.length,marker.startOffset+40));
                    marker.collapse(true);
                    const saved=view.getCFI(last,marker),before=frame.getBoundingClientRect().top,caretRanges=doc.getSelection().rangeCount;
                    await sleep(80);await r.next();await ready([last-1,last]);await sleep(300);
                    rows.push({delay,caretRanges,active:r.getContents()[0].index,savedVisible:window.Leaf.isLocationVisible(saved),before,after:frame.getBoundingClientRect().top,
                        saved,current:view.lastLocation.cfi});
                }
                const doc=r.getContents()[0].doc,node=doc.querySelector('p').firstChild,range=doc.createRange();
                range.setStart(node,2);range.setEnd(node,12);await r.scrollToAnchor(range,true);
                rows.at(-1).explicitSelection=doc.getSelection().toString()===range.toString();
                return rows;
            } finally {previous.load=load;}
            """,arguments:[:],in:nil,contentWorld:.page)
        let rows=try XCTUnwrap(result as? [[String:Any]])
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:rows),uniformTypeIdentifier:"public.json")
        attachment.name="Delayed previous chapter with final-page navigation";attachment.lifetime = .keepAlways;add(attachment)
        for row in rows {
            XCTAssertEqual(row["active"] as? Int,3,"\(row)")
            XCTAssertEqual(row["caretRanges"] as? Int,0,"Scroll navigation must not create a synthetic caret: \(row)")
            if let selected=row["explicitSelection"] as? Bool { XCTAssertTrue(selected,"Explicit selection still installs its range") }
            XCTAssertEqual(row["savedVisible"] as? Bool,true,"\(row)")
            XCTAssertEqual(row["before"] as? Double ?? 0,row["after"] as? Double ?? 999,accuracy:3,"\(row)")
        }
    }

    func testBackwardWarmUpKeepsPassageWhenOlderChaptersWereNeverLoaded() async throws {
        let (book,url)=try prepare("The Art of Noticing.epub",format:.epub)
        var prefs=preferences;prefs.scrolling=true
        let model=try show(book,url:url,readerPreferences:prefs)
        try await assertOpened(model,contains:"attention")
        let result=try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            await view.goTo(3);
            const section=view.book.sections[1],load=section.load;
            section.load=async()=>{await sleep(150);return load();};
            try {
                await view.goTo(2);
                const frame=r.getContents()[0].doc.defaultView.frameElement,before=frame.getBoundingClientRect().top;
                await sleep(450);
                return {before,after:frame.getBoundingClientRect().top,active:r.getContents()[0].index,indices:r.getContents().map(c=>c.index)};
            } finally {section.load=load;}
            """,arguments:[:],in:nil,contentWorld:.page)
        let state=try XCTUnwrap(result as? [String:Any])
        XCTAssertEqual(state["active"] as? Int,2,"\(state)")
        XCTAssertEqual(state["before"] as? Double ?? 0,state["after"] as? Double ?? 999,accuracy:2,"\(state)")
        XCTAssertEqual(Set(state["indices"] as? [Int] ?? []),Set([1,2,3]))
    }

    func testNavigationReusesAnAdjacentChapterStillBeingPrepared() async throws {
        let (book,url)=try prepare("The Art of Noticing.epub",format:.epub)
        var prefs=preferences;prefs.scrolling=true
        let model=try show(book,url:url,readerPreferences:prefs)
        try await assertOpened(model,contains:"attention")
        let result=try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            const ready=async index=>{const end=performance.now()+8000;while(!r.getContents().some(c=>c.index===index&&c.doc?.body)){if(performance.now()>end)throw new Error('Prepared chapter timed out');await sleep(10);}};
            await view.goTo(3);await ready(2);
            const section=view.book.sections[1],load=section.load;
            let loads=0,preparedDoc;const events=[];
            const state=()=>r.getContents().map(c=>c.index);
            section.load=async()=>{loads++;events.push({type:'read',loads,state:state(),stack:new Error().stack});await sleep(150);return load();};
            const loaded=({detail})=>{events.push({type:'load',index:detail.index,preload:!!detail.preload,state:state()});if(detail.index===1&&detail.preload)preparedDoc=detail.doc;};
            r.addEventListener('load',loaded);
            try {
                await view.goTo(2);events.push({type:'at2',state:state()});await sleep(20);events.push({type:'before1',state:state()});await view.goTo(1);await ready(1);
                return {loads,events,active:r.getContents()[0].index,reused:r.getContents()[0].doc===preparedDoc,documents:r.getContents().length};
            } finally {section.load=load;r.removeEventListener('load',loaded);}
            """,arguments:[:],in:nil,contentWorld:.page)
        let state=try XCTUnwrap(result as? [String:Any])
        XCTAssertEqual(state["loads"] as? Int,1,"An in-flight neighbor must not be cancelled and read again: \(state)")
        XCTAssertEqual(state["active"] as? Int,1)
        XCTAssertEqual(state["reused"] as? Bool,true)
        XCTAssertLessThanOrEqual(state["documents"] as? Int ?? 99,3)
    }

    func testSelectingVisibleNeighborKeepsItsOwnCFIWithoutMovingScrollPassage() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        var prefs=preferences; prefs.scrolling=true
        let model=try show(book,url:url,readerPreferences:prefs)
        try await assertOpened(model,contains:"attention")
        let web=try XCTUnwrap(model.webView)
        let passage=try await web.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            await view.goTo(1);
            const end=performance.now()+8000;
            while(!r.getContents().some(c=>c.index===2&&c.doc?.body)) {if(performance.now()>end)throw new Error('Neighbor not ready');await sleep(10);}
            const next=r.getContents().find(c=>c.index===2).doc,frame=next.defaultView.frameElement,container=frame.parentElement.parentElement;
            const offset=frame.parentElement.getBoundingClientRect().top-container.getBoundingClientRect().top+container.scrollTop;
            container.scrollTop=offset-container.clientHeight*0.45;await sleep(300);
            return view.lastLocation.cfi;
            """,arguments:[:],in:nil,contentWorld:.page) as? String
        let locator=try XCTUnwrap(passage)
        try await waitUntil {model.locator==locator}
        let result=try await web.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,doc=r.getContents().find(c=>c.index===2).doc;
            const container=doc.defaultView.frameElement.parentElement.parentElement,top=container.scrollTop,active=r.getContents()[0].index;
            const range=doc.createRange(),node=doc.querySelector('p').firstChild;
            range.setStart(node,2);range.setEnd(node,12);
            const selection=doc.getSelection();selection.removeAllRanges();selection.addRange(range);
            const expected=view.getCFI(2,range),chapter=view.getProgressOf(2,range).tocItem?.label;
            await new Promise(resolve=>setTimeout(resolve,100));
            return {text:selection.toString(),expected,chapter,active,afterActive:r.getContents()[0].index,top,afterTop:container.scrollTop};
            """,arguments:[:],in:nil,contentWorld:.page)
        let state=try XCTUnwrap(result as? [String:Any]),text=try XCTUnwrap(state["text"] as? String)
        try await waitUntil {model.selectedReadingContext()?.text==text}
        let context=try XCTUnwrap(model.selectedReadingContext())
        XCTAssertEqual(context.locator,state["expected"] as? String,"The quote belongs to the selected neighboring chapter")
        XCTAssertEqual(context.chapter,state["chapter"] as? String)
        XCTAssertEqual(model.locator,locator,"Selecting an already visible neighbor must preserve the reading passage")
        XCTAssertEqual(state["active"] as? Int,1)
        XCTAssertEqual(state["afterActive"] as? Int,1)
        XCTAssertEqual(state["top"] as? Double ?? 0,state["afterTop"] as? Double ?? 999,accuracy:1)
        let snapshot=try await model.readingChatContext()
        XCTAssertEqual(snapshot?.locator,context.locator)
        XCTAssertEqual(snapshot?.text,text)
    }

    func testContinuousScrollEvictsDistantChaptersAndReleasesQueuedResourcesOnClose() async throws {
        let (book, url) = try prepare("MemoryStress.epub", format: .epub, fixtures: true)
        var prefs = preferences; prefs.scrolling = true
        let model = try show(book, url: url, readerPreferences: prefs)
        try await waitUntil { model.isReady || model.error != nil }
        let web = try XCTUnwrap(model.webView)
        let result = try await web.callAsyncJavaScript("""
            const active=new Map(),create=URL.createObjectURL.bind(URL),revoke=URL.revokeObjectURL.bind(URL);
            let peakCount=0,peakBytes=0,maxDocuments=0,maxFrames=0;
            const errors=[],error=console.error;console.error=(...args)=>{errors.push(args.map(String).join(' '));error(...args);};
            URL.createObjectURL=blob=>{const url=create(blob);active.set(url,blob.size);peakCount=Math.max(peakCount,active.size);peakBytes=Math.max(peakBytes,[...active.values()].reduce((a,b)=>a+b,0));return url;};
            URL.revokeObjectURL=url=>{active.delete(url);revoke(url);};
            const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            try {
                await window.Leaf.open(config);
                const view=document.querySelector('foliate-view'),r=view.renderer,count=view.book.sections.length;
                const ready=async()=>{
                    const until=performance.now()+8000;
                    while(performance.now()<until){
                        if(r.getContents().some(x=>!x.doc))throw new Error('Null mounted document: '+JSON.stringify(r.getContents().map(x=>({index:x.index,doc:!!x.doc,connected:x.doc?.defaultView?.frameElement?.isConnected})))+' errors='+JSON.stringify(errors));
                        if(r.getContents().length===3 && r.getContents().every(x=>x.doc.URL!=='about:blank' && x.doc.body.textContent.trim())){await sleep(20);return;}
                        await sleep(10);
                    }
                    throw new Error('Bounded nearby chapters did not finish');
                };
                for(let n=0;n<48;n++){
                    await view.goTo(1+(n*37)%(count-2));await ready();
                    const contents=r.getContents();
                    maxDocuments=Math.max(maxDocuments,contents.length);
                    maxFrames=Math.max(maxFrames,contents[0].doc.defaultView.frameElement.getRootNode().querySelectorAll('iframe').length);
                    const current=contents[0].index;
                    if(contents.some(x=>Math.abs(x.index-current)>1))throw new Error('Distant chapter retained');
                }
                // Close with an adjacent chapter read still queued/in flight.
                await view.goTo(20);window.Leaf.close();await sleep(350);
                return {count,peakCount,peakBytes,maxDocuments,maxFrames,afterClose:active.size};
            } finally { URL.createObjectURL=create;URL.revokeObjectURL=revoke;console.error=error; }
            """, arguments: ["config": ["name":"MemoryStress.epub","format":"epub","locator":"","preferences":prefs.payload]], in:nil,contentWorld:.page)
        let metrics = try XCTUnwrap(result as? [String:Int])
        XCTAssertGreaterThanOrEqual(metrics["count"] ?? 0,128)
        XCTAssertEqual(metrics["maxDocuments"],3)
        XCTAssertLessThanOrEqual(metrics["maxFrames"] ?? 99,5)
        XCTAssertLessThanOrEqual(metrics["peakCount"] ?? 99,24)
        XCTAssertLessThanOrEqual(metrics["peakBytes"] ?? .max,16*1024*1024)
        XCTAssertEqual(metrics["afterClose"],0)
        let attachment = XCTAttachment(data:try JSONEncoder().encode(metrics),uniformTypeIdentifier:"public.json")
        attachment.name="Scroll chapter-window resource bounds and queued-close cleanup";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testContinuousScrollWindowStylesAndSavedCFIAcrossEveryTextSizeAndFlowSwitch() async throws {
        let (book, url) = try prepare("The Art of Noticing.epub", format: .epub)
        var prefs = preferences; prefs.scrolling = true
        let model = try show(book, url: url, readerPreferences: prefs)
        try await assertOpened(model, contains: "attention")
        let result = try await model.webView?.callAsyncJavaScript("""
            const view=document.querySelector('foliate-view'),r=view.renderer,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
            await view.goTo(1);await sleep(250);
            const doc=r.getContents()[0].doc,range=doc.createRange(),p=doc.querySelector('p').firstChild;
            range.setStart(p,8);range.setEnd(p,20);
            const saved=view.getCFI(1,range),text=range.toString(),rows=[],events=[];
            const measure=()=>{const current=r.getContents()[0],frame=current.doc.defaultView.frameElement,container=frame.parentElement.parentElement;return {index:current.index,top:container.scrollTop,frameY:frame.getBoundingClientRect().top,start:r.start,locator:view.lastLocation?.cfi};};
            r.addEventListener('relocate',({detail})=>{events.push({reason:detail.reason,...measure()});if(events.length>16)events.shift();});
            await view.goTo(saved);
            const initial={...measure(),visible:window.Leaf.isLocationVisible(saved)};
            for(const scrolling of [true,false,true])for(let size=12;size<=32;size++){
                const font=['Georgia','Palatino','System'][(size-12)%3],margin=[8,20,48][(size-12)%3],theme=themes[(size-12)%themes.length];
                window.Leaf.applyPreferences({...base,...theme,scrolling,font,fontSize:size,horizontalMargin:margin});
                await sleep(70);
                const contents=r.getContents();
                const valid=contents.every(({doc})=>{
                    const root=doc.defaultView.getComputedStyle(doc.documentElement);
                    return Math.abs(parseFloat(root.fontSize)-size)<0.1 && root.colorScheme===theme.colorScheme
                        && [...doc.querySelector('p').getClientRects()].every(rect=>Math.abs(rect.width-(view.clientWidth-2*margin))<2);
                });
                rows.push({scrolling,size,font,margin,valid,initial,state:measure(),events:[...events],visible:window.Leaf.isLocationVisible(saved),documents:contents.length,
                    sameText:view.resolveNavigation(saved).anchor(doc).toString()===text,
                    actual:contents.map(({index,doc})=>({index,size:doc.defaultView.getComputedStyle(doc.documentElement).fontSize,
                        scheme:doc.defaultView.getComputedStyle(doc.documentElement).colorScheme,
                        widths:[...doc.querySelector('p').getClientRects()].map(rect=>rect.width),expectedWidth:view.clientWidth-2*margin,
                        styles:[...doc.querySelectorAll('style')].map(s=>({namespace:s.namespaceURI,applied:!!s.sheet}))}))});
            }
            return rows;
            """, arguments:["base":prefs.payload,"themes":[ReadingTheme.day,ReadingTheme.paper,ReadingTheme.night].map { ReaderPreferences(fontSize:19,lineHeight:1.65,font:"Georgia",theme:$0,scrolling:true).payload }],in:nil,contentWorld:.page)
        let rows = try XCTUnwrap(result as? [[String:Any]])
        XCTAssertEqual(rows.count,63)
        for row in rows {
            XCTAssertEqual(row["valid"] as? Bool,true,"\(row)")
            XCTAssertEqual(row["visible"] as? Bool,true,"\(row)")
            XCTAssertEqual(row["sameText"] as? Bool,true,"\(row)")
            XCTAssertLessThanOrEqual(row["documents"] as? Int ?? 99,(row["scrolling"] as? Bool) == true ? 3 : 1)
        }
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:rows),uniformTypeIdentifier:"public.json")
        attachment.name="Nearby chapter styles and saved CFI at 12–32 pt in both flows";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testPlainTextRenders() async throws {
        let (book, url) = try prepare("A Field Guide to Slow Days.txt", format: .txt)
        try await assertOpened(show(book, url: url), contains: "morning")
    }
    func testEveryThemeUpdatesRenderedColorsWithoutChangingPassageOrGeometry() async throws {
        let (book, url) = try prepare("Density.html", format: .html, fixtures: true)
        let model = try show(book, url: url)
        try await assertOpened(model, contains: "窗外")
        let web = try XCTUnwrap(model.webView)
        let themes: [[String: Any]] = ReadingTheme.allCases.map { theme in
            var prefs = preferences; prefs.theme = theme
            return ["id": theme.id, "preferences": prefs.payload]
        }
        for size in [CGSize(width: 390, height: 720), CGSize(width: 720, height: 390)] {
            window?.frame.size = size
            try await Task.sleep(for: .milliseconds(300))
            let result = try await web.callAsyncJavaScript("""
                const view = document.querySelector('foliate-view'), renderer = view.renderer;
                const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
                const rows = [];
                for (const scrolling of [false, true]) {
                  for (const [index, font] of ['Georgia','Palatino','System'].entries()) {
                    const fontSize = [12,22,32][index], horizontalMargin = [12,20,36][index];
                    const settings = {...themes[0].preferences, scrolling, font, fontSize, horizontalMargin};
                    window.Leaf.applyPreferences(settings); await sleep(180);
                    await view.goToFraction(0.4); await sleep(120);
                    const doc = renderer.getContents()[0].doc;
                    const originalText = doc.body.textContent;
                    const saved = view.lastLocation.cfi;
                    const before = doc.querySelector('p').getBoundingClientRect().width;
                    for (const theme of themes) {
                      window.Leaf.applyPreferences({...settings, ...theme.preferences, scrolling, font, fontSize, horizontalMargin});
                      await sleep(150);
                      const current = renderer.getContents()[0].doc;
                      const style = current.defaultView.getComputedStyle(current.querySelector('p'));
                      const rootStyle = current.defaultView.getComputedStyle(current.documentElement);
                      const probe = current.createElement('span'); current.body.append(probe);
                      probe.style.color = theme.preferences.foreground;
                      const expectedInk = current.defaultView.getComputedStyle(probe).color;
                      probe.style.color = theme.preferences.background;
                      const expectedPage = current.defaultView.getComputedStyle(probe).color;
                      probe.remove();
                      rows.push({theme:theme.id, scrolling, font, fontSize, horizontalMargin,
                        expectedInk, expectedPage, ink:style.color, page:rootStyle.backgroundColor,
                        scheme:rootStyle.colorScheme, expectedScheme:theme.preferences.colorScheme,
                        sameDocument:current===doc, sameText:originalText===current.body.textContent,
                        width:current.querySelector('p').getBoundingClientRect().width, before,
                        actualSize:parseFloat(style.fontSize), keptPassage:window.Leaf.isLocationVisible(saved),
                        documents:renderer.getContents().length});
                    }
                  }
                }
                return rows;
                """, arguments: ["themes": themes], in: nil, contentWorld: .page)
            let rows = try XCTUnwrap(result as? [[String: Any]])
            XCTAssertEqual(rows.count, ReadingTheme.allCases.count * 6)
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: rows), uniformTypeIdentifier: "public.json")
            attachment.name = "Theme geometry \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
            for row in rows {
                let label = "\(size) \(row)"
                XCTAssertEqual(row["ink"] as? String, row["expectedInk"] as? String, label)
                XCTAssertEqual(row["page"] as? String, row["expectedPage"] as? String, label)
                XCTAssertEqual(row["scheme"] as? String, row["expectedScheme"] as? String, label)
                XCTAssertEqual(row["sameDocument"] as? Bool, true, label)
                XCTAssertEqual(row["sameText"] as? Bool, true, label)
                XCTAssertEqual(row["keptPassage"] as? Bool, true, label)
                XCTAssertEqual(row["documents"] as? Int, 1, label)
                XCTAssertEqual(try XCTUnwrap(row["width"] as? Double), try XCTUnwrap(row["before"] as? Double), accuracy: 1, label)
                XCTAssertEqual(try XCTUnwrap(row["actualSize"] as? Double), try XCTUnwrap(row["fontSize"] as? Double), accuracy: 0.1, label)
            }
        }
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
              const colorScheme = fontIndex === 2 ? 'dark' : 'light';
              for (const scrolling of [true, false]) {
                const sizes = Array.from({length:21}, (_, i) => scrolling ? i + 12 : 32 - i);
                for (const fontSize of sizes) {
                    const saved = view.lastLocation.cfi;
                    window.Leaf.applyPreferences({...base, scrolling, fontSize, font, horizontalMargin, background, foreground, colorScheme});
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

@MainActor private final class CenteredReaderTestTap: UITapGestureRecognizer {
    override func location(in view: UIView?) -> CGPoint {
        CGPoint(x:(view?.bounds.width ?? 0)/2,y:(view?.bounds.height ?? 0)/2)
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
