#if DEBUG
import Foundation

/// Explicit UI-test injection: exercises the production recovery and chat UI
/// with actual books, without making network requests or requiring credentials.
@MainActor
final class UITestRecoveryChatProvider: @MainActor ToolChatProvider {
    private var attempts: [String: Int] = [:]
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let events = streamAgent(system: request.system, items: request.turns.map(AgentItem.turn), tools: [], allowTools: false)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        switch event {
                        case .text(let text): continuation.yield(.text(text))
                        case .finished(let value): continuation.yield(.finished(truncated: value))
                        default: break
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        let key = items.compactMap { item -> String? in
            if case .turn(let turn) = item, turn.role == "user" { return turn.content }; return nil
        }.last ?? ""
        let hasResults = items.contains { if case .toolResults = $0 { return true }; return false }
        // Every chat now offers tools; only the agent recovery case scripts a tool round.
        if UITesting.flag(.chatRecoveryAgent), tools.contains(where: { $0.name == "list_chapters" }), !hasResults {
            return AsyncThrowingStream {
                $0.yield(.toolCall(.init(id: "recovery_chapters", name: "list_chapters", arguments: "{}")))
                $0.yield(.finished(truncated: false)); $0.finish()
            }
        }
        let number = (attempts[key] ?? 0) + 1; attempts[key] = number
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if key.contains("Stop during retry") {
                        let response = HTTPURLResponse(url: URL(string: "https://fixture.example")!, statusCode: 503, httpVersion: nil,
                                                       headerFields: ["Retry-After": "6"])!
                        throw ChatRequestFailure(ChatError.http(503), response: response)
                    }
                    continuation.yield(.text(number == 1 ? "Abandoned partial answer" : "Recovered reply. The original question and passage were kept."))
                    try await Task.sleep(for: .milliseconds(300))
                    if number == 1 { throw URLError(.networkConnectionLost) }
                    continuation.yield(.finished(truncated: false)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
