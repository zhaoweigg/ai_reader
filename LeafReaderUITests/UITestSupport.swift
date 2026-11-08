import XCTest

extension XCTestCase {
    /// Attaches a full-screen screenshot that survives in the result bundle for review.
    @MainActor func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
