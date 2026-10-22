import Foundation
import WebKit
import UIKit

// Only the current book and bundled reader assets are reachable through this scheme.
// Deliver bounded chunks; a ZIP reader can request individual entries without a
// native Data allocation or WebKit Blob containing the entire archive.
@MainActor
final class ReaderAssetHandler: NSObject, WKURLSchemeHandler {
    private let bookURL: URL
    private let format: BookFormat
    private let assets: URL
    private var transfers: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(bookURL: URL, format: BookFormat, assets: URL) { self.bookURL = bookURL; self.format = format; self.assets = assets }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        transfers[key] = Task { [weak self] in
            guard let self else { return }
            defer { self.transfers[key] = nil }
            do { try await self.deliver(urlSchemeTask) }
            catch { if !Task.isCancelled { urlSchemeTask.didFailWithError(error) } }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        transfers.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    private func deliver(_ task: WKURLSchemeTask) async throws {
        guard let url = task.request.url, url.host == "reader" else { throw LibraryError.unsafePath }
        let file: URL
        let mime: String
        if url.path == "/book" {
            file = bookURL
            mime = "application/octet-stream"
            if format == .rtf {
                let attributed = try NSAttributedString(url: bookURL, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                let data = Data(attributed.string.utf8)
                task.didReceive(response(url, length: data.count, mime: "text/plain; charset=utf-8"))
                if task.request.httpMethod != "HEAD" { task.didReceive(data) }
                task.didFinish()
                return
            }
        } else {
            let path = url.path == "/" ? "index.html" : String(url.path.dropFirst())
            file = assets.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            let base = assets.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard file.path.hasPrefix(base) else { throw LibraryError.unsafePath }
            switch file.pathExtension {
            case "js", "mjs": mime = "text/javascript; charset=utf-8"
            case "html": mime = "text/html; charset=utf-8"
            case "css": mime = "text/css; charset=utf-8"
            case "wasm": mime = "application/wasm"
            default: mime = "application/octet-stream"
            }
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let range: Range<Int>
        if let header = task.request.value(forHTTPHeaderField: "Range") {
            guard let requested = Self.byteRange(header, size: size) else {
                task.didReceive(HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes */\(size)", "Content-Length": "0"])!)
                task.didFinish(); return
            }
            range = requested
        } else { range = 0..<size }
        task.didReceive(response(url, length: range.count, mime: mime, range: task.request.value(forHTTPHeaderField: "Range") == nil ? nil : range, total: size))
        if task.request.httpMethod != "HEAD" {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            var remaining = range.count
            while remaining > 0 {
                try Task.checkCancellation()
                let data = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                task.didReceive(data)
                remaining -= data.count
                await Task.yield() // Allow WebKit to cancel a closing reader's transfer.
            }
        }
        try Task.checkCancellation()
        task.didFinish()
    }
    private func response(_ url: URL, length: Int, mime: String, range: Range<Int>? = nil, total: Int = 0) -> HTTPURLResponse {
        var headers = ["Content-Type": mime, "Content-Length": String(length), "Accept-Ranges": "bytes",
                       "Access-Control-Allow-Origin": "*", "Access-Control-Expose-Headers": "Content-Length, Content-Range", "Cache-Control": "no-store"]
        if let range { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)" }
        return HTTPURLResponse(url: url, statusCode: range == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
    static func byteRange(_ header: String, size: Int) -> Range<Int>? {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        func number(_ text: Substring) -> Int? {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(text)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]), suffix > 0 else { return nil }
            return max(0, size - suffix)..<size
        }
        guard let first = number(parts[0]), first < size else { return nil }
        if parts[1].isEmpty { return first..<size }
        guard let last = number(parts[1]), last >= first else { return nil }
        return first..<(min(last, size - 1) + 1)
    }
}
