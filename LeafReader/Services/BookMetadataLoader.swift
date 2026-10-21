import Foundation
import WebKit
import PDFKit

struct BookMetadata: Sendable {
    var title: String?
    var author: String?
    var cover: Data?
}

@MainActor
enum BookMetadataLoader {
    static let version = 1

    static func load(_ book: Book, from url: URL) async throws -> BookMetadata {
        if book.format == .pdf {
            return try await Task.detached(priority: .utility) {
                guard let document = PDFDocument(url: url) else { throw LibraryError.invalidPDF }
                return BookMetadata(
                    title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                    author: document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
                    cover: document.isLocked ? nil : document.page(at: 0)?
                        .thumbnail(of: CGSize(width: 400, height: 600), for: .cropBox).pngData())
            }.value
        }
        guard book.format.hasLibraryArtwork else { return BookMetadata() }
        let request = MetadataRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { request.start(book, url: url, continuation: $0) }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }
}

// Parse the package and cover without creating a reader or changing its location.
@MainActor
private final class MetadataRequest: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<BookMetadata, Error>?
    private var deadline: Task<Void, Never>?

    func start(_ book: Book, url: URL, continuation: CheckedContinuation<BookMetadata, Error>) {
        self.continuation = continuation
        guard let assets = Bundle.main.url(forResource: "Reader", withExtension: nil) else {
            finish(.failure(CocoaError(.fileNoSuchFile))); return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "leafMetadata")
        configuration.setURLSchemeHandler(ReaderAssetHandler(bookURL: url, format: book.format, assets: assets), forURLScheme: "leaf-reader")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 440), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        var location = URLComponents()
        location.scheme = "leaf-reader"
        location.host = "reader"
        location.path = "/metadata.html"
        location.queryItems = [URLQueryItem(name: "name", value: book.title + "." + book.format.rawValue),
                               URLQueryItem(name: "format", value: book.format.rawValue)]
        guard let address = location.url else { finish(.failure(URLError(.badURL))); return }
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
                self?.finish(.failure(URLError(.timedOut)))
            } catch { }
        }
        view.load(URLRequest(url: address))
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<BookMetadata, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "leafMetadata")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        continuation.resume(with: result)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let payload = message.body as? [String: Any] else { return }
        if payload["type"] as? String == "metadata" {
            let cover = (payload["cover"] as? String).flatMap { Data(base64Encoded: $0) }
            finish(.success(BookMetadata(title: payload["title"] as? String, author: payload["author"] as? String, cover: cover)))
        } else { finish(.failure(URLError(.cannotDecodeContentData))) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == "leaf-reader" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.cannotLoadFromNetwork))) }
}
