import XCTest

extension XCTestCase {
    /// Polls `condition` until it holds or `timeout` seconds pass, then asserts it so a
    /// timeout reads as a failure at the call site rather than a hang.
    func eventually(timeout: TimeInterval = 3, interval: TimeInterval = 0.01,
                    file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .seconds(interval)) }
        XCTAssertTrue(condition(), "Timed out after \(timeout) s", file: file, line: line)
    }

    /// A fresh directory under the temporary folder, removed when the test tears down.
    func temporaryFolder(_ prefix: String = "LeafTests", create: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
