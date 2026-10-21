import Foundation
import WebKit
import UIKit

// Only the current book and bundled reader assets are reachable through this scheme.
final class ReaderAssetHandler: NSObject, WKURLSchemeHandler {
    private let bookURL: URL
    private let format: BookFormat
    private let assets: URL
    init(bookURL: URL, format: BookFormat, assets: URL) { self.bookURL = bookURL; self.format = format; self.assets = assets }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "reader" else {
            urlSchemeTask.didFailWithError(LibraryError.unsafePath); return
        }
        do {
            let data: Data
            let mime: String
            if url.path == "/book" {
                if format == .rtf {
                    let attributed = try NSAttributedString(url: bookURL, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                    data = Data(attributed.string.utf8)
                    mime = "text/plain; charset=utf-8"
                } else { data = try Data(contentsOf: bookURL); mime = "application/octet-stream" }
            } else {
                let path = url.path == "/" ? "index.html" : String(url.path.dropFirst())
                let file = assets.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                let base = assets.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                guard file.path.hasPrefix(base) else { throw LibraryError.unsafePath }
                data = try Data(contentsOf: file)
                switch file.pathExtension {
                case "js", "mjs": mime = "text/javascript; charset=utf-8"
                case "html": mime = "text/html; charset=utf-8"
                case "css": mime = "text/css; charset=utf-8"
                case "wasm": mime = "application/wasm"
                default: mime = "application/octet-stream"
                }
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
