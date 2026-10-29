import UIKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import Combine

/// Decoded covers are expendable; small disk thumbnails survive cell recycling and app launches.
@MainActor final class ZLibraryImages: ObservableObject {
    static let shared: ZLibraryImages = {
        #if DEBUG
        if let id = UITesting.testID, UITesting.flag("LEAF_UI_ZLIB_THUMBNAILS") {
            return ZLibraryImages(transport: UITestZLibraryImageTransport(), directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("LeafUITests/\(id.uuidString)/Thumbnails", isDirectory: true))
        }
        #endif
        return ZLibraryImages()
    }()
    private let cache = NSCache<NSURL, UIImage>()
    private let disk: ZLibraryThumbnailDiskCache
    private let transport: any ZLibraryTransport
    private let slots = ZLibraryImageSlots()
    private struct Request {
        let id: UUID
        let task: Task<UIImage?, Never>
        var readers: Set<UUID>
    }
    private var requests: [URL: Request] = [:]
    #if DEBUG
    @Published private(set) var transferCounts: [URL: Int] = [:]
    @Published private(set) var activeTransfers = 0
    #endif

    init(transport: any ZLibraryTransport = ZLibraryHTTPTransport(), directory: URL? = nil) {
        self.transport = transport
        disk = ZLibraryThumbnailDiskCache(directory: directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZLibraryThumbnails-v1", isDirectory: true))
        cache.countLimit = 120
        cache.totalCostLimit = 24 * 1024 * 1024
    }
    /// Synchronous lookup prevents a placeholder frame when SwiftUI recreates a warm cell.
    func cachedImage(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func discardDecodedImages() { cache.removeAllObjects() }

    func image(_ url: URL) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cachedImage(url) { return image }
        let reader = UUID()
        if requests[url] == nil {
            let id = UUID()
            let task = Task { [self] () -> UIImage? in
                let cg: CGImage?
                if let saved = await disk.image(url) { cg = saved }
                else {
                    await slots.acquire()
                    #if DEBUG
                    var countedTransfer = false
                    #endif
                    do {
                        try Task.checkCancellation()
                        #if DEBUG
                        if UITesting.flag("LEAF_UI_ZLIB_THUMBNAILS") {
                            transferCounts[url, default: 0] += 1; activeTransfers += 1; countedTransfer = true
                        }
                        #endif
                        let payload = try await transport.send(URLRequest(url: url), toFile: false, progress: { _ in })
                        try Task.checkCancellation()
                        cg = (200...299).contains(payload.response.statusCode) ? await disk.store(payload.data, for: url) : nil
                    } catch { cg = nil }
                    #if DEBUG
                    if countedTransfer { activeTransfers -= 1 }
                    #endif
                    await slots.release()
                }
                let image = cg.map { UIImage(cgImage: $0) }
                if !Task.isCancelled, let image, let cg {
                    cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
                }
                if requests[url]?.id == id { requests[url] = nil }
                return Task.isCancelled ? nil : image
            }
            requests[url] = Request(id: id, task: task, readers: [])
        }
        requests[url]?.readers.insert(reader)
        guard let request = requests[url] else { return nil }
        return await withTaskCancellationHandler {
            let result = await request.task.value
            return Task.isCancelled ? nil : result
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(reader, url: url, request: request.id) }
        }
    }
    private func cancel(_ reader: UUID, url: URL, request id: UUID) {
        guard var request = requests[url], request.id == id else { return }
        request.readers.remove(reader)
        if request.readers.isEmpty { requests[url] = nil; request.task.cancel() }
        else { requests[url] = request }
    }
}

/// Limit active transfers even when a fast fling creates many cells at once.
private actor ZLibraryImageSlots {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}

actor ZLibraryThumbnailDiskCache {
    private let directory: URL
    private let byteLimit: Int
    private let countLimit: Int
    private let maximumAge: TimeInterval
    init(directory: URL, byteLimit: Int = 64 * 1024 * 1024, countLimit: Int = 512, maximumAge: TimeInterval = 30 * 24 * 60 * 60) {
        self.directory = directory; self.byteLimit = byteLimit; self.countLimit = countLimit; self.maximumAge = maximumAge
    }
    private func file(_ url: URL) -> URL {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("png")
    }
    func image(_ url: URL) -> CGImage? {
        let path = file(url)
        guard let modified = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              Date().timeIntervalSince(modified) < maximumAge,
              let data = try? Data(contentsOf: path), let image = Self.decode(data) else {
            try? FileManager.default.removeItem(at: path); return nil
        }
        return image
    }
    func store(_ data: Data, for url: URL) -> CGImage? {
        guard let image = Self.decode(data) else { return nil }
        let thumbnail = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(thumbnail, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try (thumbnail as Data).write(to: file(url), options: .atomic)
                    trim()
                } catch { /* A full or unavailable cache must not hide a downloaded cover. */ }
            }
        }
        return image
    }
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 360, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.filter { $0.pathExtension == "png" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }, count = entries.count
        for entry in entries {
            guard bytes > byteLimit || count > countLimit || Date().timeIntervalSince(entry.2) >= maximumAge else { continue }
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { bytes -= entry.1; count -= 1 }
        }
    }
}

#if DEBUG
/// Explicit offline fixture; normal launches always use the production HTTP transport.
@MainActor private struct UITestZLibraryImageTransport: ZLibraryTransport {
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
