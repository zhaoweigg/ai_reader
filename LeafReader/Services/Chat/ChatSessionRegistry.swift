import Foundation

struct ChatSessionKey: Hashable {
    let directory: URL
    let conversation: String
    init(directory: URL, conversation: String) {
        self.directory = URL(fileURLWithPath: directory.standardizedFileURL.resolvingSymlinksInPath().path, isDirectory: true)
        self.conversation = conversation
    }
}

/// Views share one writer for a conversation. A reply outlives its panel; idle
/// sessions are weakly held so closing many conversations does not keep them all.
@MainActor final class ChatSessionRegistry<Session: AnyObject> {
    private final class Entry {
        weak var session: Session?
        var active: Session?
        init(_ session: Session) { self.session = session }
    }
    private var entries: [ChatSessionKey: Entry] = [:]

    func session(for key: ChatSessionKey, create: () -> Session) -> Session {
        if let session = entries[key]?.session { return session }
        entries = entries.filter { $0.value.session != nil }
        let session = create()
        entries[key] = Entry(session)
        return session
    }

    func setActive(_ active: Bool, session: Session, for key: ChatSessionKey) {
        guard let entry = entries[key], entry.session === session else { return }
        entry.active = active ? session : nil
    }
}
