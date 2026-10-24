import SwiftUI
import WebKit
import PDFKit

extension ReaderModel {
    /// The selection palette's view of this model. Every closure holds the model
    /// weakly; a surface drops the hooks when it is dismantled.
    var selectionHooks: ReaderSelectionHooks {
        ReaderSelectionHooks(
            theme: { [weak self] in self?.preferences?.theme ?? .day },
            context: { [weak self] in self?.selectedReadingContext() },
            action: { [weak self] intent, snapshot in self?.askAboutSelection(intent, context: snapshot) },
            annotation: { [weak self] in self?.selectedAnnotationSelection() },
            annotate: { [weak self] intent, snapshot in self?.annotateSelection(intent, selection: snapshot) },
            listeningPosition: { [weak self] in self?.listeningSelectionPosition() },
            listen: { [weak self] locator in self?.listeningRequest = ReaderListeningRequest(locator: locator) })
    }
}

@MainActor private func installReaderGestures(on view: UIView, target: NSObject, delegate: UIGestureRecognizerDelegate, tap action: Selector, pan panAction: Selector) {
    let tap = UITapGestureRecognizer(target: target, action: action)
    let doubleTap = UITapGestureRecognizer()
    doubleTap.numberOfTapsRequired = 2
    tap.require(toFail: doubleTap)
    let pan = UIPanGestureRecognizer(target: target, action: panAction)
    for gesture: UIGestureRecognizer in [tap, doubleTap, pan] {
        gesture.cancelsTouchesInView = false
        gesture.delegate = delegate
        view.addGestureRecognizer(gesture)
    }
}

struct WebBookSurface: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    let url: URL
    let preferences: ReaderPreferences
    var onReaderTap: (() -> Bool)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.onReaderTap = onReaderTap
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "leaf")
        guard let assets = Bundle.main.url(forResource: "Reader", withExtension: nil), let format = model.book?.format else { return WKWebView() }
        configuration.setURLSchemeHandler(ReaderAssetHandler(bookURL: url, format: format, assets: assets), forURLScheme: "leaf-reader")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = ReaderWebView(frame: .zero, configuration: configuration)
        view.selectionHooks = model.selectionHooks
        view.prepareSelection = { [weak model] in await model?.refreshSelectedWebContext() }
        view.isOpaque = false
        view.backgroundColor = UIColor(preferences.theme.background)
        view.clipsToBounds = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.isScrollEnabled = false
        view.scrollView.delegate = context.coordinator
        view.navigationDelegate = context.coordinator
        installReaderGestures(on: view, target: context.coordinator, delegate: context.coordinator, tap: #selector(Coordinator.tapped(_:)), pan: #selector(Coordinator.panned(_:)))
        view.accessibilityIdentifier = "bookWebView"
        view.isInspectable = true
        model.webView = view
        model.preferences = preferences
        view.load(URLRequest(url: URL(string: "leaf-reader://reader/index.html")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onReaderTap = onReaderTap
        view.backgroundColor = UIColor(preferences.theme.background)
        // Deferring avoids publishing into SwiftUI while it is rendering the representable.
        if model.preferences != preferences { Task { @MainActor in model.applyPreferences(preferences) } }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leaf")
        view.navigationDelegate = nil
        view.scrollView.delegate = nil
        coordinator.onReaderTap = nil
        (view as? ReaderWebView)?.selectionHooks = ReaderSelectionHooks()
        (view as? ReaderWebView)?.prepareSelection = nil
        if coordinator.model.webView === view { coordinator.model.webView = nil }
        view.stopLoading()
        view.evaluateJavaScript("window.Leaf?.close()") { [weak view] _, _ in
            view?.loadHTMLString("", baseURL: nil)
        }
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let model: ReaderModel
        var onReaderTap: (() -> Bool)?
        init(_ model: ReaderModel) { self.model = model }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view, model.isReady else { return }
            if onReaderTap?() == true { return }
            let point = gesture.location(in: view)
            model.evaluate("tap", ["x": point.x / max(1, view.bounds.width), "y": point.y / max(1, view.bounds.height)])
        }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { model.hideControls() }
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // Foliate scrolls its own document. WebKit's focus restoration after
            // dismissing a sheet must not scroll the outer reader surface.
            if scrollView.contentOffset != .zero { scrollView.setContentOffset(.zero, animated: false) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === model.webView, message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            let previousSelection = model.selectedReadingContext()
            model.receive(body)
            if body["type"] as? String == "selection", previousSelection != model.selectedReadingContext() {
                (message.webView as? ReaderWebView)?.selectionDidChange()
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let allowed = url?.scheme == "leaf-reader" || url?.scheme == "blob" || url?.absoluteString == "about:blank"
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if model.webView === webView { model.error = error.localizedDescription }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { model.webProcessTerminated(webView) }
    }
}

struct PDFBookSurface: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    let url: URL
    let theme: ReadingTheme
    var onReaderTap: (() -> Bool)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIView(context: Context) -> PDFView {
        context.coordinator.onReaderTap = onReaderTap
        let view = ReaderPDFView()
        view.selectionHooks = model.selectionHooks
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = UIColor(theme.background)
        view.accessibilityIdentifier = "bookPDFView"
        model.configurePDF(view, url: url)
        context.coordinator.observe(view)
        installReaderGestures(on: view, target: context.coordinator, delegate: context.coordinator, tap: #selector(Coordinator.tapped(_:)), pan: #selector(Coordinator.panned(_:)))
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.onReaderTap = onReaderTap
        view.backgroundColor = UIColor(theme.background)
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.onReaderTap = nil
        (view as? ReaderPDFView)?.selectionHooks = ReaderSelectionHooks()
        view.document = nil
        if coordinator.model.pdfView === view { coordinator.model.pdfView = nil }
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: ReaderModel
        var onReaderTap: (() -> Bool)?
        var token: NSObjectProtocol?
        private var annotationTokens: [NSObjectProtocol] = []
        init(_ model: ReaderModel) { self.model = model; super.init() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            // PDFKit can briefly clear currentSelection as its native long press
            // finishes. That interaction must never become an edge-page tap.
            if let view = gesture.view as? ReaderPDFView, view.isHandlingNativeSelectionGesture {
                #if DEBUG
                readerSelectionMenuTrace("pdfReaderTapSuppressed", source: view)
                #endif
                return
            }
            if onReaderTap?() == true { return }
            guard let view = gesture.view as? PDFView, view.currentSelection?.string?.isEmpty != false else { return }
            #if DEBUG
            readerSelectionMenuTrace("pdfReaderTap", source: view)
            #endif
            let point = gesture.location(in: view)
            if let page = view.page(for: point, nearest: false), let annotation = page.annotation(at: view.convert(point, to: page)) {
                model.openPDFAnnotation(annotation)
                return
            }
            let fraction = point.x / max(1, view.bounds.width)
            if fraction < 0.3 { model.send("previous") }
            else if fraction > 0.7 { model.send("next") }
            else { model.toggleControls() }
        }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { model.hideControls() }
        }
        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model.pdfPageChanged() }
            }
            for name: Notification.Name in [.PDFViewVisiblePagesChanged, .PDFViewScaleChanged] {
                annotationTokens.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self, weak view] _ in
                    Task { @MainActor [weak self, weak view] in
                        guard let self, let view, self.model.pdfView === view else { return }
                        self.model.synchronizeAnnotations()
                    }
                })
            }
        }
        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
            for observer in annotationTokens { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
