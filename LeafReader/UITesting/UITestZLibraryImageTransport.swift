import UIKit

#if DEBUG
/// Explicit offline fixture; normal launches always use the production HTTP transport.
@MainActor struct UITestZLibraryImageTransport: ZLibraryTransport {
    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        try await Task.sleep(for: .milliseconds(60))
        let index = Int(request.url!.deletingPathExtension().lastPathComponent) ?? 0
        let data = UIGraphicsImageRenderer(size: CGSize(width: 244, height: 360)).pngData { context in
            let colors: [UIColor] = [.systemTeal, .systemIndigo, .systemBrown, .systemOrange, .systemPink]
            colors[index % colors.count].setFill(); context.fill(CGRect(x: 0, y: 0, width: 244, height: 360))
            let title = "LEAF\n\nCOVER \(index + 1)"
            (title as NSString).draw(in: CGRect(x: 24, y: 28, width: 196, height: 260), withAttributes: [
                .font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor.white])
        }
        return ZLibraryPayload(data: data, file: nil, response: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "image/png"])!)
    }
}
#endif
