import XCTest
@testable import LeafReader

final class ChatScrollFollowingTests: XCTestCase {
    func testGrowingReplyDoesNotDisableFollowingWithoutUserScroll() {
        var state = ChatScrollFollowing()
        state.updateBottomDistance(180)
        XCTAssertTrue(state.followsLatest)
    }
    func testDraggingPausesImmediatelyAndStaysPausedAcrossNewTokens() {
        var state = ChatScrollFollowing()
        state.beginDragging()
        state.updateBottomDistance(0)
        XCTAssertFalse(state.followsLatest, "Do not fight the finger even before the content has moved")
        state.updateBottomDistance(300)
        state.endDragging()
        state.updateBottomDistance(450)
        XCTAssertFalse(state.followsLatest)
    }
    func testReturningToBottomResumesAfterDragOrMomentum() {
        var state = ChatScrollFollowing()
        state.beginDragging(); state.updateBottomDistance(100); state.endDragging()
        XCTAssertFalse(state.followsLatest)
        state.updateBottomDistance(4)
        XCTAssertTrue(state.followsLatest, "Momentum can reach the bottom after the finger lifts")
        state.beginDragging(); state.updateBottomDistance(-8); state.endDragging()
        XCTAssertTrue(state.followsLatest, "Bottom bounce should still follow")
    }
    func testNewRequestExplicitlyResumesAfterReadingEarlier() {
        var state = ChatScrollFollowing()
        state.beginDragging(); state.updateBottomDistance(500); state.endDragging()
        state.resume()
        XCTAssertTrue(state.followsLatest)
    }
}
