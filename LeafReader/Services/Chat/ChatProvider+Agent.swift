import Foundation

// Tool calling for the book search agent in Anthropic Messages and Chat
// Completions formats. Plain chat requests are unchanged.
extension HTTPChatProvider: ToolChatProvider {
    func makeAgentRequest(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) throws -> URLRequest {
        try makeRequest(system: system, messages: kind == .anthropic ? Self.anthropicMessages(items) : Self.completionMessages(items),
                        tools: tools, allowTools: allowTools)
    }
    static func completionMessages(_ items: [AgentItem]) -> [[String: Any]] {
        items.flatMap { item -> [[String: Any]] in
            switch item {
            case .turn(let turn): return [["role": turn.role, "content": turn.content]]
            case .toolCalls(let text, let calls):
                return [["role": "assistant", "content": text.isEmpty ? NSNull() : text as Any,
                         "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }]]
            case .toolResults(let results): return results.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.output] }
            }
        }
    }
    static func anthropicMessages(_ items: [AgentItem]) -> [[String: Any]] {
        items.map { item -> [String: Any] in
            switch item {
            case .turn(let turn): return ["role": turn.role, "content": turn.content]
            case .toolCalls(let text, let calls):
                let uses: [[String: Any]] = calls.map {
                    ["type": "tool_use", "id": $0.id, "name": $0.name,
                     "input": (try? JSONSerialization.jsonObject(with: Data($0.arguments.utf8))) as? [String: Any] ?? [:]]
                }
                return ["role": "assistant", "content": (text.isEmpty ? [] : [["type": "text", "text": text]]) + uses]
            case .toolResults(let results):
                return ["role": "user", "content": results.map { ["type": "tool_result", "tool_use_id": $0.id, "content": $0.output] }]
            }
        }
    }

    func streamAgent(system: String, items: [AgentItem], tools: [AgentTool], allowTools: Bool) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeAgentRequest(system: system, items: items, tools: tools, allowTools: allowTools)
                    let (response, lines) = try await transport.open(request)
                    guard (200..<300).contains(response.statusCode) else { throw ChatError.http(response.statusCode) }
                    guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                        throw ChatError.invalidResponse
                    }
                    var decoder = ServerSentEventDecoder()
                    var state = AgentStreamState()
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        for event in try decodeAgent(data, state: &state) {
                            switch event {
                            case .text(let text):
                                state.textLength += text.count
                                guard state.textLength <= 64000 else { throw ChatError.tooLarge }
                            case .toolCall: state.calls += 1
                            case .finished:
                                guard state.textLength > 0 || state.calls > 0 else { throw ChatError.emptyResponse }
                                continuation.yield(event); continuation.finish(); return
                            }
                            continuation.yield(event)
                        }
                    }
                    throw ChatError.interrupted
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct AgentStreamState {
        var truncated = false
        var textLength = 0
        var calls = 0
        // Tool calls arrive in fragments, keyed by index, until they are complete.
        var pending: [Int: (id: String, name: String, arguments: String)] = [:]
        mutating func flush() -> [AgentEvent] {
            defer { pending = [:] }
            return pending.keys.sorted().compactMap { key in
                guard let call = pending[key], !call.name.isEmpty else { return nil }
                return .toolCall(AgentToolCall(id: call.id.isEmpty ? "call_\(key)" : call.id, name: call.name,
                                               arguments: call.arguments.isEmpty ? "{}" : call.arguments))
            }
        }
    }

    func decodeAgent(_ data: String, state: inout AgentStreamState) throws -> [AgentEvent] {
        if kind == .chatCompletions, data == "[DONE]" { return state.flush() + [.finished(truncated: state.truncated)] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { throw ChatError.invalidResponse }
        if kind == .anthropic {
            let index = (object["index"] as? NSNumber)?.intValue ?? 0
            switch object["type"] as? String {
            case "content_block_start":
                if let block = object["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    state.pending[index] = (block["id"] as? String ?? "", block["name"] as? String ?? "", "")
                    return []
                }
            case "content_block_delta":
                if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta" {
                    state.pending[index]?.arguments += delta["partial_json"] as? String ?? ""
                    return []
                }
            case "content_block_stop":
                guard let call = state.pending.removeValue(forKey: index), !call.name.isEmpty else { return [] }
                return [.toolCall(AgentToolCall(id: call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments))]
            case "message_stop": return state.flush() + [.finished(truncated: state.truncated)]
            default: break
            }
        } else if let choice = (object["choices"] as? [[String: Any]])?.first {
            for fragment in (choice["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? [] {
                let index = (fragment["index"] as? NSNumber)?.intValue ?? 0
                var call = state.pending[index] ?? ("", "", "")
                if let id = fragment["id"] as? String { call.id = id }
                if let function = fragment["function"] as? [String: Any] {
                    call.name += function["name"] as? String ?? ""
                    call.arguments += function["arguments"] as? String ?? ""
                }
                state.pending[index] = call
            }
        }
        // Text, errors, finish reasons and message_delta use the plain chat decoder.
        var truncated = state.truncated
        var events = try decode(data, truncated: &truncated).map { event -> AgentEvent in
            switch event {
            case .text(let text): return .text(text)
            case .finished(let value): return .finished(truncated: value)
            }
        }
        state.truncated = truncated
        // Completions end tool calls with a finish reason before [DONE].
        if kind == .chatCompletions, (object["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "tool_calls" {
            events += state.flush()
        }
        return events
    }
}
