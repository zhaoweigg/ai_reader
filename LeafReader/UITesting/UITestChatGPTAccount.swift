import Foundation

#if DEBUG
// Used only by explicit UI-test launches with isolated defaults and Keychain.
struct UITestChatGPTCatalog: ChatGPTHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url == ChatGPTEndpoints.models else { throw ChatGPTError.network }
        let data = Data(#"{"models":[{"slug":"ui-test-model","display_name":"Sample Reader","visibility":"list"}]}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor final class UITestChatGPTSignIn: ChatGPTAuthorizing {
    func authorize(hostID: String, registration: ChatGPTAccount?, reconsent: Bool) async throws -> (ChatGPTOAuthAttempt, URL) {
        try await Task.sleep(for: .seconds(30))
        throw ChatGPTError.cancelled
    }
    func cancel() {}
}
#endif
