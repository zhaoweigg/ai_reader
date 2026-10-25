import XCTest
@testable import LeafReader

final class ChatScrollFollowingTests: XCTestCase {
    func testOffsetsWithinTheSameRegionDoNotChangeViewState() {
        var state = ChatScrollFollowing()
        state.beginDragging(); state.updateBottomDistance(100)
        let earlier = state
        for distance in stride(from: 101, through: 800, by: 1) {
            state.updateBottomDistance(CGFloat(distance))
            XCTAssertEqual(state, earlier, "Scrolling within history must not publish every pixel into panel state")
        }
        state.updateBottomDistance(0); state.endDragging()
        let latest = state
        for distance in [-20.0, -5, 0, 2, 4] {
            state.updateBottomDistance(distance)
            XCTAssertEqual(state, latest)
        }
    }
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
        state.beginDragging(); state.updateBottomDistance(12); state.endDragging()
        XCTAssertFalse(state.followsLatest, "A small scroll in a compact keyboard viewport still pauses following")
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
