import Foundation

#if DEBUG
/// A long saved conversation for the scroll-back tests: numbered exchanges, written once
/// into each conversation a test opens. Shipping builds never create messages.
@MainActor enum UITestChatHistory {
    static func seed(_ store: ChatHistoryStore) {
        guard let exchanges = UITesting.value(.chatHistory).flatMap({ Int($0) }), exchanges > 0,
              let latest = try? store.page(before: nil, after: nil, limit: 1), latest.messages.isEmpty else { return }
        var messages: [ReaderChatMessage] = []
        for index in 1...min(exchanges, 400) {
            messages.append(ReaderChatMessage(isUser: true, text: "Question \(index)"))
            messages.append(ReaderChatMessage(isUser: false, text: "Answer \(index): what the reader asked in question \(index), explained over a few lines so that a screen holds only a handful of exchanges."))
        }
        try? store.save(messages, draft: nil)
    }
}
#endif
