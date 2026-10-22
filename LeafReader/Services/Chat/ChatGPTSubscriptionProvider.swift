import Foundation

struct ChatGPTSubscriptionProvider: ChatProvider {
    let accounts: ChatGPTAccountStore
    let accountID: String
    let model: String
    var transport: any ChatTransport = URLSessionChatTransport()

    func makeRequest(_ conversation: ChatRequest, accessToken: String) throws -> URLRequest {
        guard !model.isEmpty else { throw ChatGPTError.missingModel }
        guard !conversation.turns.isEmpty else { throw ChatError.configuration("Write a question first.") }
        var request = URLRequest(url: ChatGPTEndpoints.responses)
        request.httpMethod = "POST"; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Subscription permission has its own Responses contract. In particular,
        // max_output_tokens, temperature, and persistent conversation IDs are omitted.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "instructions": conversation.system, "store": false, "stream": true,
            "input": conversation.turns.map { ["role": $0.role, "content": $0.content] }
        ])
        return request
    }
    func stream(_ conversation: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let requestID = UUID()
                defer { accounts.unregisterRequest(requestID) }
                do {
                    try accounts.registerRequest(requestID, accountID: accountID) {
                        continuation.finish(throwing: ChatGPTError.signInRequired)
                    }
                    try await accounts.validateModel(model, accountID: accountID)
                    let token = try await accounts.accessToken(accountID: accountID)
                    try Task.checkCancellation()
                    let request = try makeRequest(conversation, accessToken: token)
                    let (response, lines) = try await transport.open(request)
                    guard (200..<300).contains(response.statusCode) else {
                        var errorData = Data()
                        for try await line in lines {
                            errorData.append(Data(line.utf8))
                            if errorData.count > 16384 { break }
                        }
                        throw ChatGPTOAuthClient.error(errorData, status: response.statusCode)
                    }
                    guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else { throw ChatError.invalidResponse }
                    var decoder = ServerSentEventDecoder()
                    var textLength = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let data = try decoder.consume(line) else { continue }
                        for event in try Self.decode(data) {
                            switch event {
                            case .text(let text):
                                textLength += text.count
                                guard textLength <= 64000 else { throw ChatError.tooLarge }
                            case .finished:
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
    static func decode(_ data: String) throws -> [ChatEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else { throw ChatError.invalidResponse }
        switch object["type"] as? String {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = object["delta"] as? String else { throw ChatError.invalidResponse }
            return [.text(delta)]
        case "response.completed": return [.finished(truncated: false)]
        case "response.incomplete": return [.finished(truncated: true)]
        case "response.failed":
            let response = object["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw ChatGPTError.response(status: 400, code: error?["code"] as? String)
        case "error": throw ChatGPTError.response(status: 400, code: object["code"] as? String)
        default: return [] // Never render reasoning, tool arguments, or usage as text.
        }
    }
}
