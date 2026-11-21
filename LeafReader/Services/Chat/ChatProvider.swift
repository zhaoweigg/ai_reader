import Foundation

// The reader and conversation model depend only on this interface. A local model,
// proxy, or another API can implement it without changing the reading UI.
protocol ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

protocol ChatTransport {
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

final class ChatRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward API credentials to a redirected destination.
    }
}

enum ChatStreamLimits {
    /// One server-sent event. A generated picture arrives as a single base64 event
    /// (and again inside the final response object), so this allows several
    /// megabytes; answer text keeps its own 64,000-character limit.
    static let eventBytes = 16 << 20
}

struct URLSessionChatTransport: ChatTransport {
    var configuration: URLSessionConfiguration = .ephemeral
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: ChatRedirectDelegate(), delegateQueue: nil)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { session.invalidateAndCancel(); throw ChatError.invalidResponse }
            let lines = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    defer { session.invalidateAndCancel() }
                    do {
                        // AsyncBytes.lines omits empty lines on some runtimes,
                        // but SSE needs them to delimit events. Frame raw bytes.
                        var line = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if byte == 10 {
                                continuation.yield(String(decoding: line, as: UTF8.self))
                                line.removeAll(keepingCapacity: true)
                            } else {
                                line.append(byte)
                                guard line.count <= ChatStreamLimits.eventBytes else { throw ChatError.tooLarge }
                            }
                        }
                        if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
            }
            return (http, lines)
        } catch { session.invalidateAndCancel(); throw error }
    }
}

// Handles comments, CRLF, multiline data, and unnamed events. A blank line ends
// an SSE event; EOF alone is never treated as successful model completion.
struct ServerSentEventDecoder {
    private var data: [String] = []
    private var size = 0
    mutating func consume(_ rawLine: String) throws -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { data = []; size = 0 }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        size += value.utf8.count
        guard size <= ChatStreamLimits.eventBytes else { throw ChatError.tooLarge }
        data.append(value)
        return nil
    }
}

struct HTTPChatProvider: ChatProvider {
    let kind: ChatProviderKind
    let profile: ChatProfile
    let apiKey: String
    var transport: any ChatTransport = URLSessionChatTransport()

    func makeRequest(_ conversation: ChatRequest) throws -> URLRequest {
        try makeRequest(system: conversation.system, messages: conversation.turns.map { ["role": $0.role, "content": $0.content] })
    }
    /// The newer search tool (with filtering) needs Claude 4.6 or later; others get the basic one.
    static func anthropicWebSearchType(_ model: String) -> String {
        let id = model.lowercased()
        let newer = ["claude-fable", "claude-mythos", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return newer.contains { id.hasPrefix($0) } ? "web_search_20260209" : "web_search_20250305"
    }
    func makeRequest(system: String, messages input: [[String: Any]], tools: [AgentTool]? = nil, allowTools: Bool = true,
                     webSearch: Bool = true) throws -> URLRequest {
        var request = URLRequest(url: try profile.validatedURL())
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatError.missingKey }
        guard !input.isEmpty else { throw ChatError.configuration("Write a question first.") }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var messages = input
        var body: [String: Any] = ["model": profile.model.trimmingCharacters(in: .whitespacesAndNewlines), "stream": true]
        switch kind {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body["system"] = system
            body["max_tokens"] = profile.maxOutputTokens
            if let tools, !tools.isEmpty {
                // Claude runs web search itself. The tool stays defined in the closing round
                // (with tool_choice none), because earlier searches remain in the messages.
                let searching = webSearch && tools.contains { $0.hosted }
                var definitions: [[String: Any]] = tools.filter { !$0.hosted }
                    .map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
                if searching {
                    definitions.append(["type": Self.anthropicWebSearchType(profile.model), "name": AgentTool.webSearchName, "max_uses": 5])
                    // Same instructions in every round, so the cached prompt prefix still matches.
                    body["system"] = system + "\n\n" + AgentTool.webSearchInstruction
                }
                if !definitions.isEmpty {
                    body["tools"] = definitions
                    body["tool_choice"] = ["type": allowTools ? "auto" : "none"]
                }
            }
            // Haiku 5.5 defaults to adaptive thinking. Keep short reading answers
            // responsive; older Haiku models also support disabled thinking.
            if profile.model.hasPrefix("claude-haiku-5") { body["thinking"] = ["type": "disabled"] }
        case .chatCompletions:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            messages.insert(["role": "system", "content": system], at: 0)
            body[profile.legacyTokenLimit ? "max_tokens" : "max_completion_tokens"] = profile.maxOutputTokens
            // These servers have no hosted web search: offer only the app's own tools.
            if let functions = tools?.filter({ !$0.hosted }), !functions.isEmpty {
                body["tools"] = functions.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
                body["tool_choice"] = allowTools ? "auto" : "none"
            }
            // Ask OpenAI for token usage in traced agent requests; other servers may not know the option.
            if tools != nil, request.url?.host?.hasSuffix("openai.com") == true { body["stream_options"] = ["include_usage": true] }
        case .chatGPT: throw ChatGPTError.signInRequired
        }
        body["messages"] = messages
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    func stream(_ conversation: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(conversation)
                    let (response, lines) = try await transport.open(request)
                    guard (200..<300).contains(response.statusCode) else { throw ChatRequestFailure(ChatError.http(response.statusCode), response: response) }
                    guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                        throw ChatError.invalidResponse
                    }
                    var decoder = ServerSentEventDecoder()
                    var truncated = false
                    var textLength = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        let events = try decode(data, truncated: &truncated)
                        for event in events {
                            if case .text(let text) = event {
                                textLength += text.count
                                guard textLength <= 64000 else { throw ChatError.tooLarge }
                            }
                            if case .finished = event {
                                guard textLength > 0 else { throw ChatError.emptyResponse }
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

    func decode(_ data: String, truncated: inout Bool) throws -> [ChatEvent] {
        if kind == .chatCompletions, data == "[DONE]" { return [.finished(truncated: truncated)] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { throw ChatError.invalidResponse }
        if let error = object["error"] as? [String: Any] {
            // Do not display arbitrary server text, which may echo credentials or book content.
            let raw = error["type"] as? String ?? "provider_error"
            let known = ["overloaded_error", "rate_limit_error", "authentication_error", "permission_error", "invalid_request_error", "api_error"]
            throw ChatError.provider(known.contains(raw) ? raw : "provider_error")
        }
        if kind == .anthropic {
            switch object["type"] as? String {
            case "content_block_start":
                if let block = object["content_block"] as? [String: Any], block["type"] as? String == "text",
                   let text = block["text"] as? String, !text.isEmpty { return [.text(text)] }
            case "content_block_delta":
                if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String { return [.text(text)] }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any] {
                    let reason = delta["stop_reason"] as? String
                    truncated = reason == "max_tokens" || reason == "model_context_window_exceeded"
                }
            case "message_stop": return [.finished(truncated: truncated)]
            default: break // Pings, thinking, usage, and future metadata are not answer text.
            }
        } else if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            if let reason = choice["finish_reason"] as? String {
                truncated = reason == "length"
                if reason == "content_filter" { throw ChatError.provider("content_filter") }
            }
            if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String { return [.text(text)] }
        }
        return []
    }
}
