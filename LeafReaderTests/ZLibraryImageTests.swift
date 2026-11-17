import XCTest
import SwiftUI
import ImageIO
@testable import LeafReader

@MainActor private final class CoverTransport: ZLibraryTransport {
    var calls: [URL: Int] = [:]
    var active = 0
    var maximumActive = 0
    var handler: (URLRequest) async throws -> ZLibraryPayload
    init(_ handler: @escaping (URLRequest) async throws -> ZLibraryPayload) { self.handler = handler }
    func send(_ request: URLRequest, toFile: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> ZLibraryPayload {
        XCTAssertFalse(toFile)
        calls[request.url!, default: 0] += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await handler(request)
    }
}

@MainActor final class ZLibraryImageTests: XCTestCase {
    private let url = URL(string: "https://covers.example/book.png")!
    private func assertPresent<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNotNil(value, file: file, line: line) }
    private func assertMissing<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertNil(value, file: file, line: line) }
    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }
    private func pixels(_ color: UIColor = .red, size: CGSize = CGSize(width: 240, height: 360)) -> Data {
        UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).pngData { context in color.setFill(); context.fill(CGRect(origin: .zero, size: size)) }
    }
    private func response(_ request: URLRequest, data: Data, status: Int = 200) -> ZLibraryPayload {
        ZLibraryPayload(data: data, file: nil, response: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func files(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
    }
    func testWarmThumbnailIsAvailableSynchronouslyAndDoesNotDownloadAgain() async throws {
        let data = pixels(), directory = try temporaryFolder("CoverTests")
        let transport = CoverTransport { [self] in response($0, data: data) }
        let images = ZLibraryImages(transport: transport, directory: directory)
        let first = try unwrap(await images.image(url))
        XCTAssertTrue(images.cachedImage(url) === first)
        let second = await images.image(url)
        XCTAssertTrue(second === first); XCTAssertEqual(transport.calls[url], 1)
    }
    func testMemoryEvictionAndNewLoaderRestoreThumbnailWithoutNetwork() async throws {
        let data = pixels(), directory = try temporaryFolder("CoverTests")
        let transport = CoverTransport { [self] in response($0, data: data) }
        let images = ZLibraryImages(transport: transport, directory: directory)
        assertPresent(await images.image(url))
        images.discardDecodedImages(); XCTAssertNil(images.cachedImage(url))
        assertPresent(await images.image(url))
        let relaunched = ZLibraryImages(transport: transport, directory: directory)
        assertPresent(await relaunched.image(url))
        XCTAssertEqual(transport.calls[url], 1)
    }
    func testConcurrentGridAndDetailRequestsShareOneTransfer() async throws {
        let data = pixels()
        let transport = CoverTransport { [self] request in
            try await Task.sleep(for: .milliseconds(80)); return response(request, data: data)
        }
        let images = ZLibraryImages(transport: transport, directory: try temporaryFolder("CoverTests"))
        async let first = images.image(url)
        async let second = images.image(url)
        let result = await (first, second)
        XCTAssertNotNil(result.0); XCTAssertTrue(result.0 === result.1)
        XCTAssertEqual(transport.calls[url], 1)
    }
    func testRecyclingOneCellDoesNotCancelAnotherCellUsingTheSameCover() async throws {
        let data = pixels()
        let transport = CoverTransport { [self] request in
            try await Task.sleep(for: .milliseconds(150)); return response(request, data: data)
        }
        let images = ZLibraryImages(transport: transport, directory: try temporaryFolder("CoverTests"))
        let first = Task { await images.image(url) }, second = Task { await images.image(url) }
        try await eventually(timeout: 1) { transport.active == 1 }
        first.cancel()
        let kept = await second.value, discarded = await first.value
        XCTAssertNotNil(kept); XCTAssertNil(discarded); XCTAssertEqual(transport.calls[url], 1)
    }
    func testCancelledCellDoesNotClearANewerRequestForTheSameURL() async throws {
        let data = pixels()
        let transport = CoverTransport { [self] request in
            try await Task.sleep(for: .milliseconds(120)); return response(request, data: data)
        }
        let images = ZLibraryImages(transport: transport, directory: try temporaryFolder("CoverTests"))
        let first = Task { await images.image(url) }
        try await eventually(timeout: 1) { transport.active == 1 }; first.cancel()
        try await eventually(timeout: 1) { transport.active == 0 }
        let next = await images.image(url), discarded = await first.value
        XCTAssertNotNil(next); XCTAssertNil(discarded)
        XCTAssertTrue(images.cachedImage(url) === next); XCTAssertEqual(transport.calls[url], 2)
    }
    func testRapidScrollingLimitsConcurrentTransfers() async throws {
        let data = pixels()
        let transport = CoverTransport { [self] request in
            try await Task.sleep(for: .milliseconds(40)); return response(request, data: data)
        }
        let images = ZLibraryImages(transport: transport, directory: try temporaryFolder("CoverTests"))
        var loaded = 0
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<24 { group.addTask { await images.image(URL(string: "https://covers.example/\(i).png")!) != nil } }
            for await success in group where success { loaded += 1 }
        }
        XCTAssertEqual(loaded, 24); XCTAssertLessThanOrEqual(transport.maximumActive, 4)
    }
    func testInvalidResponsesAreNotCachedAndCanRecover() async throws {
        let data = pixels()
        var responseNumber = 0
        let transport = CoverTransport { [self] request in
            responseNumber += 1
            if responseNumber == 1 { return response(request, data: Data("<html>Access check</html>".utf8)) }
            if responseNumber == 2 { return response(request, data: data, status: 404) }
            return response(request, data: data)
        }
        let directory = try temporaryFolder("CoverTests"), images = ZLibraryImages(transport: transport, directory: directory)
        assertMissing(await images.image(url)); assertMissing(await images.image(url))
        XCTAssertTrue(try files(directory).isEmpty)
        assertPresent(await images.image(url)); XCTAssertEqual(transport.calls[url], 3)
    }
    func testCorruptDiskThumbnailIsReplacedWithoutPoisoningMemory() async throws {
        let data = pixels(), directory = try temporaryFolder("CoverTests")
        let transport = CoverTransport { [self] in response($0, data: data) }
        let images = ZLibraryImages(transport: transport, directory: directory)
        assertPresent(await images.image(url)); images.discardDecodedImages()
        try Data("corrupt".utf8).write(to: XCTUnwrap(files(directory).first))
        assertPresent(await images.image(url)); XCTAssertEqual(transport.calls[url], 2)
    }
    func testDiskCacheBoundsCountAndBytesAndExpiresOldThumbnails() async throws {
        let directory = try temporaryFolder("CoverTests"), data = pixels()
        let disk = ZLibraryThumbnailDiskCache(directory: directory, countLimit: 3)
        for i in 0..<8 { assertPresent(await disk.store(data, for: URL(string: "https://covers.example/\(i)")!)) }
        XCTAssertEqual(try files(directory).count, 3)
        for file in try files(directory) {
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        }
        assertMissing(await disk.image(URL(string: "https://covers.example/7")!))
        let small = ZLibraryThumbnailDiskCache(directory: try temporaryFolder("CoverTests"), byteLimit: 1)
        assertPresent(await small.store(data, for: url)); assertMissing(await small.image(url))
    }
    func testOnlyDownsampledPixelsArePersistedAndURLQueriesRemainDistinct() async throws {
        let directory = try temporaryFolder("CoverTests"), disk = ZLibraryThumbnailDiskCache(directory: directory)
        let first = URL(string: "https://covers.example/book?edition=1")!, second = URL(string: "https://covers.example/book?edition=2")!
        let large = try unwrap(await disk.store(pixels(size: CGSize(width: 1200, height: 1800)), for: first))
        XCTAssertEqual(max(large.width, large.height), 360)
        assertPresent(await disk.store(pixels(.blue), for: second))
        XCTAssertEqual(try files(directory).count, 2)
        for file in try files(directory) {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 360)
            XCTAssertFalse(file.lastPathComponent.contains("edition"))
        }
    }
    func testWarmRecreatedCoverRendersImmediatelyAndURLChangesNeverShowTheOldCover() async throws {
        let data = pixels(), blue = pixels(.blue)
        let transport = CoverTransport { [self] request in response(request, data: request.url == url ? data : blue) }
        let images = ZLibraryImages(transport: transport, directory: try temporaryFolder("CoverTests")), second = URL(string: "https://covers.example/other.png")!
        assertPresent(await images.image(url)); assertPresent(await images.image(second))
        func book(_ cover: URL?) -> ZLibraryBook {
            ZLibraryBook(remoteID: "12", hash: "aabbcc", title: "Test", author: "Leaf", fileExtension: "epub", size: "1 MB", language: "English", year: "2026", coverURL: cover)
        }
        let host = UIHostingController(rootView: ZLibraryCover(book: book(url), images: images))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 360))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func color() throws -> [UInt8] {
            host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Cover first frame \(transport.calls.count)"; attachment.lifetime = .keepAlways; add(attachment)
            let pixel = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: CGFloat(image.cgImage!.width / 2), y: CGFloat(image.cgImage!.height / 2), width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return rgba
        }
        let first = try color(); XCTAssertGreaterThan(first[0], 230); XCTAssertLessThan(first[2], 20)
        host.rootView = ZLibraryCover(book: book(second), images: images)
        let changed = try color(); XCTAssertGreaterThan(changed[2], 230); XCTAssertLessThan(changed[0], 20)
        host.rootView = ZLibraryCover(book: book(nil), images: images)
        let missing = try color(); XCTAssertFalse(missing[2] > 230 && missing[0] < 20)
        XCTAssertEqual(transport.calls.values.reduce(0, +), 2)
    }
    func testCoverTileKeepsOneSizeAndShowsTheWholeCoverWhateverItsShape() async throws {
        // A grey cover with a different colour in each corner: all four must stay in view.
        func artwork(_ size: CGSize) -> Data {
            UIGraphicsImageRenderer(size: size, format: {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
            }()).pngData { context in
                UIColor(white: 0.5, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                let mark = CGSize(width: size.width * 0.3, height: size.height * 0.3)
                for (color, x, y) in [(.red, 0, 0), (.green, 1, 0), (.blue, 0, 1), (.yellow, 1, 1)] as [(UIColor, CGFloat, CGFloat)] {
                    color.setFill(); context.fill(CGRect(x: (size.width - mark.width) * x, y: (size.height - mark.height) * y, width: mark.width, height: mark.height))
                }
            }
        }
        let slim = URL(string: "https://covers.example/slim.png")!, squat = URL(string: "https://covers.example/squat.png")!
        let transport = CoverTransport { [self] request in
            response(request, data: artwork(request.url == slim ? CGSize(width: 120, height: 240) : CGSize(width: 240, height: 160)))
        }
        let images = ZLibraryImages(transport: transport, directory: try temporaryFolder("CoverTests"))
        assertPresent(await images.image(slim)); assertPresent(await images.image(squat))
        func book(_ cover: URL?) -> ZLibraryBook {
            ZLibraryBook(remoteID: "12", hash: "aabbcc", title: "Test", author: "Leaf", fileExtension: "epub", size: "1 MB", language: "English", year: "2026", coverURL: cover)
        }
        let tile = CGSize(width: 204, height: 300)
        XCTAssertEqual(tile.width / tile.height, ZLibraryCover.shape, accuracy: 0.001)
        let host = UIHostingController(rootView: ZLibraryCover(book: book(nil), images: images))
        host.safeAreaRegions = []; host.view.backgroundColor = .white
        let window = UIWindow(frame: CGRect(origin: .zero, size: tile))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func render(_ cover: URL?, _ name: String) throws -> (CGPoint) throws -> [UInt8] {
            host.rootView = ZLibraryCover(book: book(cover), images: images)
            // The tile takes the full width offered and the one height that goes with it.
            let fitted = host.sizeThatFits(in: CGSize(width: tile.width, height: 2_000))
            XCTAssertEqual(fitted.width, tile.width, accuracy: 0.5, name); XCTAssertEqual(fitted.height, tile.height, accuracy: 0.5, name)
            host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Cover tile " + name; attachment.lifetime = .keepAlways; add(attachment)
            let bitmap = try XCTUnwrap(image.cgImage), scale = CGFloat(bitmap.width) / tile.width
            return { point in
                let pixel = try XCTUnwrap(bitmap.cropping(to: CGRect(x: (point.x * scale).rounded(.down), y: (point.y * scale).rounded(.down), width: 1, height: 1)))
                var rgba = [UInt8](repeating: 0, count: 4)
                let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return rgba
            }
        }
        // Each corner of `cover`, the rectangle the whole artwork occupies, shows its own colour;
        // `gap`, a point in the tile beside the artwork, is painted rather than left empty.
        func assertWhole(_ pixel: (CGPoint) throws -> [UInt8], cover: CGRect, gap: CGPoint, _ name: String) throws {
            let inset = cover.insetBy(dx: 7, dy: 7)
            let corners: [(CGPoint, [Bool])] = [
                (CGPoint(x: inset.minX, y: inset.minY), [true, false, false]), (CGPoint(x: inset.maxX, y: inset.minY), [false, true, false]),
                (CGPoint(x: inset.minX, y: inset.maxY), [false, false, true]), (CGPoint(x: inset.maxX, y: inset.maxY), [true, true, false])]
            for (point, bright) in corners {
                let color = try pixel(point)
                for channel in 0..<3 {
                    if bright[channel] { XCTAssertGreaterThan(color[channel], 200, "\(name) \(point) \(color)") }
                    else { XCTAssertLessThan(color[channel], 70, "\(name) \(point) \(color)") }
                }
            }
            let fill = try pixel(gap)
            XCTAssertFalse(fill[0] > 235 && fill[1] > 235 && fill[2] > 235, "\(name) gap is empty: \(fill)")
        }
        _ = try render(nil, "without a cover")
        // 120 x 240 fits the 204 x 300 tile as 150 x 300, leaving 27 pt on each side.
        try assertWhole(try render(slim, "slim"), cover: CGRect(x: 27, y: 0, width: 150, height: 300), gap: CGPoint(x: 10, y: 150), "slim")
        // 240 x 160 fits it as 204 x 136, leaving 82 pt above and below.
        try assertWhole(try render(squat, "squat"), cover: CGRect(x: 0, y: 82, width: 204, height: 136), gap: CGPoint(x: 102, y: 30), "squat")
    }
}
