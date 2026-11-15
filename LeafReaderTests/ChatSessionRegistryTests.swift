import XCTest
@testable import LeafReader

@MainActor final class ChatSessionRegistryTests: XCTestCase {
    private final class Session { var reply = "" }
    private func key(_ conversation: String = "general", library: String = "LibraryA") -> ChatSessionKey {
        ChatSessionKey(directory: URL(fileURLWithPath: "/tmp/LeafRegistryTests/\(library)"), conversation: conversation)
    }

    func testActiveReplySurvivesReleasingItsLastViewAndReopensTheSameSession() async {
        let registry = ChatSessionRegistry<Session>(), key = key()
        var view: Session? = registry.session(for: key) { Session() }
        weak var original = view
        view?.reply = "Partial answer"
        registry.setActive(true, session: view!, for: key)
        view = nil
        XCTAssertNotNil(original, "Closing the last view must not discard its ongoing reply")
        var reopened: Session? = registry.session(for: key) { XCTFail("Do not start another conversation owner"); return Session() }
        XCTAssertTrue(reopened === original); XCTAssertEqual(reopened?.reply, "Partial answer")
        reopened?.reply += " completed"
        XCTAssertEqual(original?.reply, "Partial answer completed")
        registry.setActive(false, session: reopened!, for: key)
        reopened = nil
        XCTAssertNil(original, "Completed hidden conversations must be released")
    }
    func testThreeViewsShareOneOwnerWithoutStartingDuplicateSessions() async {
        let registry = ChatSessionRegistry<Session>(), key = key("book")
        var creations = 0
        func open() -> Session { registry.session(for: key) { creations += 1; return Session() } }
        let library = open(), discover = open(), reader = open()
        XCTAssertTrue(library === discover && discover === reader); XCTAssertEqual(creations, 1)
    }
    func testIdleConversationCanBeReleasedAndLoadedAgain() async {
        let registry = ChatSessionRegistry<Session>(), key = key()
        var view: Session? = registry.session(for: key) { Session() }
        weak var original = view; view = nil
        XCTAssertNil(original)
        var loaded = false
        _ = registry.session(for: key) { loaded = true; return Session() }
        XCTAssertTrue(loaded)
    }
    func testConversationAndLibraryBoundariesPreventCrossedReplies() async {
        let registry = ChatSessionRegistry<Session>()
        let general = registry.session(for: key()) { Session() }
        let book = registry.session(for: key("book")) { Session() }
        let otherLibrary = registry.session(for: key(library: "LibraryB")) { Session() }
        XCTAssertFalse(general === book); XCTAssertFalse(general === otherLibrary); XCTAssertFalse(book === otherLibrary)
    }
    func testCompletingOneReplyDoesNotReleaseAnotherActiveConversation() async {
        let registry = ChatSessionRegistry<Session>()
        var first: Session? = registry.session(for: key("first")) { Session() }
        var second: Session? = registry.session(for: key("second")) { Session() }
        weak var firstReply = first, secondReply = second
        registry.setActive(true, session: first!, for: key("first")); registry.setActive(true, session: second!, for: key("second"))
        registry.setActive(false, session: first!, for: key("first")); first = nil; second = nil
        XCTAssertNil(firstReply); XCTAssertNotNil(secondReply)
        if let secondReply { registry.setActive(false, session: secondReply, for: key("second")) }
        XCTAssertNil(secondReply)
    }
    func testUnrelatedSessionCannotChangeAnOwnersLifetime() async {
        let registry = ChatSessionRegistry<Session>(), key = key()
        var owner: Session? = registry.session(for: key) { Session() }
        weak var original = owner
        registry.setActive(true, session: owner!, for: key)
        registry.setActive(false, session: Session(), for: key)
        owner = nil
        XCTAssertNotNil(original)
        if let original { registry.setActive(false, session: original, for: key) }
        XCTAssertNil(original)
    }
    func testEquivalentDirectoryPathsUseTheSameOwner() async {
        let registry = ChatSessionRegistry<Session>(), key = key("book")
        let first = registry.session(for: key) { Session() }
        let alias = ChatSessionKey(directory: key.directory.appendingPathComponent("unused/.."), conversation: "book")
        XCTAssertTrue(registry.session(for: alias) { Session() } === first)
    }
}
