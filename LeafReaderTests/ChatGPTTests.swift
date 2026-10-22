import XCTest
import Security
import CryptoKit
@testable import LeafReader

private final class ChatGPTTestCredentials: ChatCredentialStore {
    var values: [String: String] = [:]
    var failing = false
    func read(account: String) throws -> String? { values[account] }
    func write(_ key: String?, account: String) throws {
        if failing { throw ChatGPTError.storage }
        values[account] = key
    }
}
private final class ChatGPTTestHTTP: ChatGPTHTTPClient {
    var requests: [URLRequest] = []
    var handler: ((URLRequest) async throws -> (Int, Data))!
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data) = try await handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
private struct ChatGPTTestStream: ChatTransport {
    let status: Int
    let lines: [String]
    func open(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!,
         AsyncThrowingStream { continuation in lines.forEach { continuation.yield($0) }; continuation.finish() })
    }
}

private final class ChatGPTTestSigner {
    let key: SecKey
    let jwks: [String: Any]
    init() throws {
        key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let bytes = [UInt8](try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data)
        var index = 0
        func read() throws -> [UInt8] {
            index += 1 // tag
            var length = Int(bytes[index]); index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f; length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
            }
            let value = Array(bytes[index..<index + length]); index += length
            return value
        }
        // Skip the outer SEQUENCE header, keeping its contents for INTEGER reads.
        index = 1
        let outer = Int(bytes[index]); index += 1
        if outer & 0x80 != 0 { index += outer & 0x7f }
        var n = try read(); while n.count > 1 && n.first == 0 { n.removeFirst() }
        let e = try read()
        jwks = ["keys": [["kid": "test-key", "kty": "RSA", "alg": "RS256", "use": "sig", "n": Data(n).oauthBase64, "e": Data(e).oauthBase64]]]
    }
    func token(clientID: String = "test-client", nonce: String? = "test-nonce", subject: String = "subject-a", changes: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
        var claims: [String: Any] = ["iss": ChatGPTEndpoints.issuer, "aud": clientID, "sub": subject, "email": "reader@example.test",
                                     "exp": Date().addingTimeInterval(3600).timeIntervalSince1970, "iat": Date().timeIntervalSince1970]
        if let nonce { claims["nonce"] = nonce }
        changes.forEach { claims[$0.key] = $0.value }
        let header = try JSONSerialization.data(withJSONObject: ["kid": "test-key", "alg": algorithm]).oauthBase64
        let body = try JSONSerialization.data(withJSONObject: claims).oauthBase64
        let signed = header + "." + body
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, nil)) as Data
        return signed + "." + signature.oauthBase64
    }
}

@MainActor
final class ChatGPTTests: XCTestCase {
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func fields(_ request: URLRequest) -> [String: String] {
        let parts = URLComponents(string: "https://test.invalid/?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))!
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func account(_ client: String = "test-client", expiry: Date = Date().addingTimeInterval(3600), scopes: [String] = ["chatgpt.tokens.use.direct"]) -> ChatGPTAccount {
        ChatGPTAccount(clientID: client, subject: "subject-a", email: "reader@example.test",
                       tokens: ChatGPTTokens(accessToken: "access-\(client)", refreshToken: "refresh-\(client)", idToken: "test-id",
                                             scopes: scopes, expiresAt: expiry))
    }
    private func store(http: ChatGPTTestHTTP = ChatGPTTestHTTP(), credentials: ChatGPTTestCredentials = ChatGPTTestCredentials()) -> (ChatGPTAccountStore, UserDefaults) {
        let suite = "ChatGPTOAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (ChatGPTAccountStore(defaults: defaults, credentials: credentials, client: ChatGPTOAuthClient(http: http)), defaults)
    }
    private func callback(_ attempt: ChatGPTOAuthAttempt, state: String? = nil, client: String = "test-client", error: String? = nil) -> URL {
        var parts = URLComponents(url: attempt.redirectURI, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "state", value: state ?? attempt.state), URLQueryItem(name: "code", value: "one-time-code"), URLQueryItem(name: "client_id", value: client)]
        if let error { parts.queryItems?.append(URLQueryItem(name: "error", value: error)) }
        return parts.url!
    }
    private func attempt(registration: ChatGPTAccount? = nil) throws -> ChatGPTOAuthAttempt {
        try ChatGPTOAuthAttempt(redirectURI: URL(string: "http://127.0.0.1:1455/auth/callback")!, hostID: "urn:uuid:\(UUID())", registration: registration)
    }

    func testAuthorizationUsesFreshPKCEStateAndNonceWithoutClientSecret() throws {
        let first = try attempt(), second = try attempt()
        XCTAssertNotEqual(first.state, second.state); XCTAssertNotEqual(first.nonce, second.nonce); XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertEqual(first.verifier.count, 43)
        XCTAssertEqual(first.challenge, Data(SHA256.hash(data: Data(first.verifier.utf8))).oauthBase64)
        let items = URLComponents(url: first.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(fields["client_id"], "dynamic_agent_client"); XCTAssertEqual(fields["agent_name_hint"], "Leaf")
        XCTAssertEqual(fields["code_challenge_method"], "S256"); XCTAssertEqual(fields["resource"], "https://api.openai.com/v1")
        XCTAssertTrue(fields["scope"]!.contains("chatgpt.tokens.use.direct")); XCTAssertNil(fields["client_secret"])
        XCTAssertNil(fields["prompt"])
    }
    func testReturningSignInReusesRegistrationAndExplicitReconsent() throws {
        let attempt = try attempt(registration: account())
        let items = URLComponents(url: attempt.authorizationURL(reconsent: true), resolvingAgainstBaseURL: false)!.queryItems!
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(fields["client_id"], "test-client"); XCTAssertNil(fields["agent_name_hint"])
        XCTAssertEqual(fields["id_token_hint"], "test-id"); XCTAssertEqual(fields["prompt"], "consent")
    }
    func testCallbackRejectsWrongStateDestinationDuplicateParametersAndClient() throws {
        let attempt = try attempt(registration: account())
        XCTAssertEqual(try attempt.callback(callback(attempt)).clientID, "test-client")
        XCTAssertThrowsError(try attempt.callback(callback(attempt, state: "wrong")))
        XCTAssertThrowsError(try attempt.callback(callback(attempt, client: "another-client")))
        XCTAssertThrowsError(try attempt.callback(callback(attempt, client: "dynamic_agent_client")))
        XCTAssertThrowsError(try attempt.callback(callback(attempt, error: "access_denied")))
        let valid = callback(attempt).absoluteString
        for invalid in [valid.replacingOccurrences(of: "127.0.0.1", with: "localhost"), valid.replacingOccurrences(of: ":1455", with: ":1456"), valid + "&state=duplicate", valid.replacingOccurrences(of: "/auth/callback", with: "/other")] {
            XCTAssertThrowsError(try attempt.callback(URL(string: invalid)!))
        }
    }
    func testSignedIdentityValidatesIssuerAudienceNonceAndSignature() throws {
        let signer = try ChatGPTTestSigner()
        let token = try signer.token()
        let identity = try ChatGPTIdentityValidator.validate(token, jwks: signer.jwks, clientID: "test-client", nonce: "test-nonce")
        XCTAssertEqual(identity.subject, "subject-a"); XCTAssertEqual(identity.email, "reader@example.test")
        let payload = token.split(separator: ".").map(String.init)
        let tampered = payload[0] + "." + (try json(["iss": ChatGPTEndpoints.issuer, "sub": "attacker"])).oauthBase64 + "." + payload[2]
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(tampered, jwks: signer.jwks, clientID: "test-client", nonce: "test-nonce"))
        let badClaims: [[String: Any]] = [["iss": "https://evil.example"], ["aud": "another-client"], ["nonce": "wrong"], ["exp": 1], ["nbf": Date().addingTimeInterval(600).timeIntervalSince1970], ["aud": ["test-client", "other"], "azp": "other"]]
        for changes in badClaims {
            let token = try signer.token(changes: changes)
            XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(token, jwks: signer.jwks, clientID: "test-client", nonce: "test-nonce"))
        }
        XCTAssertThrowsError(try ChatGPTIdentityValidator.validate(signer.token(algorithm: "none"), jwks: signer.jwks, clientID: "test-client", nonce: "test-nonce"))
    }
    func testAuthorizationCodeExchangeVerifiesIdentityAndScopes() async throws {
        let signer = try ChatGPTTestSigner(), http = ChatGPTTestHTTP(), attempt = try attempt()
        http.handler = { request in
            if request.url == ChatGPTEndpoints.jwks { return (200, try self.json(signer.jwks)) }
            XCTAssertEqual(request.url, ChatGPTEndpoints.token)
            let fields = self.fields(request)
            XCTAssertEqual(fields["client_id"], "test-client"); XCTAssertEqual(fields["code_verifier"], attempt.verifier)
            XCTAssertEqual(fields["redirect_uri"], attempt.redirectURI.absoluteString)
            XCTAssertEqual(fields["grant_type"], "authorization_code"); XCTAssertNil(fields["client_secret"])
            return (200, try self.json(["access_token": "access", "refresh_token": "refresh", "id_token": signer.token(nonce: attempt.nonce),
                                       "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTEndpoints.scopes]))
        }
        let result = try await ChatGPTOAuthClient(http: http).exchange(attempt, callback: callback(attempt))
        XCTAssertTrue(result.canUsePlan); XCTAssertEqual(result.clientID, "test-client")
        XCTAssertEqual(result.tokens?.refreshToken, "refresh"); XCTAssertEqual(http.requests.count, 2)
    }
    func testWrongAccountDuringReauthorizationCannotReplaceIdentity() async throws {
        let signer = try ChatGPTTestSigner(), http = ChatGPTTestHTTP(), attempt = try attempt(registration: account())
        http.handler = { request in
            if request.url == ChatGPTEndpoints.jwks { return (200, try self.json(signer.jwks)) }
            return (200, try self.json(["access_token": "access", "refresh_token": "refresh", "id_token": signer.token(nonce: attempt.nonce, subject: "different-subject"),
                                       "token_type": "Bearer", "expires_in": 3600, "scope": ChatGPTEndpoints.scopes]))
        }
        do { _ = try await ChatGPTOAuthClient(http: http).exchange(attempt, callback: callback(attempt)); XCTFail("Must reject account substitution") }
        catch { XCTAssertTrue(error is ChatGPTError) }
    }
    func testRefreshRotatesCredentialsAndIsCoalesced() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account(expiry: Date().addingTimeInterval(-1)))
        http.handler = { request in
            XCTAssertEqual(self.fields(request)["client_id"], "test-client")
            XCTAssertEqual(self.fields(request)["refresh_token"], "refresh-test-client")
            XCTAssertNil(self.fields(request)["scope"])
            try await Task.sleep(for: .milliseconds(30))
            return (200, try self.json(["access_token": "rotated-access", "refresh_token": "rotated-refresh", "token_type": "Bearer", "expires_in": 3600]))
        }
        async let first = store.accessToken(accountID: "test-client|subject-a")
        async let second = store.accessToken(accountID: "test-client|subject-a")
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["rotated-access", "rotated-access"])
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(store.selected?.tokens?.refreshToken, "rotated-refresh")
    }
    func testTemporaryRefreshFailureKeepsTokensAndTerminalFailureClearsThem() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account(expiry: Date().addingTimeInterval(-1)))
        http.handler = { _ in throw ChatGPTError.network }
        do { _ = try await store.accessToken(accountID: "test-client|subject-a"); XCTFail() } catch { }
        XCTAssertNotNil(store.selected?.tokens)
        http.handler = { _ in (400, try self.json(["error": "invalid_grant", "error_description": "never display secrets"])) }
        do { _ = try await store.accessToken(accountID: "test-client|subject-a"); XCTFail() } catch { }
        XCTAssertNil(store.selected?.tokens)
        XCTAssertEqual(store.selected?.clientID, "test-client")
    }
    func testCredentialsStayOutOfDefaultsAndAccountsRemainSeparate() throws {
        let credentials = ChatGPTTestCredentials(); let (store, defaults) = store(credentials: credentials)
        let host = store.hostID
        try store.accept(account("client-a")); try store.accept(account("client-b"))
        XCTAssertEqual(store.accounts.count, 2)
        try store.select("client-a|subject-a")
        XCTAssertEqual(store.selected?.tokens?.accessToken, "access-client-a")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("access-client-a"))
        let restored = ChatGPTAccountStore(defaults: defaults, credentials: credentials)
        XCTAssertEqual(restored.hostID, host); XCTAssertEqual(restored.selectedID, "client-a|subject-a")
        XCTAssertEqual(restored.accounts.count, 2)
        credentials.failing = true
        XCTAssertThrowsError(try restored.accept(account("must-not-persist")))
        XCTAssertEqual(restored.selectedID, "client-a|subject-a")
    }
    func testMissingPlanPermissionPreventsRefreshAndInference() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account(scopes: ["openid", "email"]))
        do { _ = try await store.accessToken(accountID: "test-client|subject-a"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("permission")) }
        XCTAssertTrue(http.requests.isEmpty)
    }
    func testSignOutRevokesRefreshAndRetainsRegistration() async throws {
        let http = ChatGPTTestHTTP(), credentials = ChatGPTTestCredentials(); let (store, _) = store(http: http, credentials: credentials)
        try store.accept(account())
        http.handler = { request in
            XCTAssertEqual(request.url, ChatGPTEndpoints.revoke)
            XCTAssertEqual(self.fields(request)["token_type_hint"], "refresh_token")
            XCTAssertEqual(self.fields(request)["client_id"], "test-client")
            return (200, Data())
        }
        await store.signOut()
        XCTAssertNil(store.selected?.tokens); XCTAssertEqual(store.selected?.clientID, "test-client")
        XCTAssertFalse(credentials.values.values.joined().contains("access-test-client"))
    }
    func testFailedRemoteRevocationStillSignsOutLocallyWithNotice() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account())
        http.handler = { _ in throw ChatGPTError.network }
        await store.signOut()
        XCTAssertNil(store.selected?.tokens)
        XCTAssertTrue(store.notice?.contains("could not be confirmed") == true)
    }
    func testCatalogIsAccountSpecificAndHidesUnlistedModels() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account("a"))
        http.handler = { request in
            XCTAssertEqual(request.url, ChatGPTEndpoints.models)
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let slug = token.contains("access-a") ? "model-a" : "model-b"
            return (200, try self.json(["models": [["slug": slug, "display_name": "Visible model", "visibility": "list"], ["slug": "hidden", "display_name": "Hidden", "visibility": "hide"]]]))
        }
        await store.loadModels(); XCTAssertEqual(store.models.map(\.slug), ["model-a"])
        try store.accept(account("b")); XCTAssertTrue(store.models.isEmpty)
        await store.loadModels(); XCTAssertEqual(store.models.map(\.slug), ["model-b"])
        do { try await store.validateModel("model-a", accountID: "b|subject-a"); XCTFail() } catch { }
    }
    func testResponsesRequestPinsEndpointAndOmitsUnsupportedFields() throws {
        let (store, _) = store()
        let client = ChatGPTSubscriptionProvider(accounts: store, accountID: "test", model: "available-model")
        let request = try client.makeRequest(ChatRequest(system: "Be helpful", turns: [ChatTurn(role: "user", content: "Why?"), ChatTurn(role: "assistant", content: "Because.")]), accessToken: "test-only-token")
        XCTAssertEqual(request.url, ChatGPTEndpoints.responses)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["model", "instructions", "store", "stream", "input"]))
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["input"] as? [[String: String]])?.count, 2)
    }
    func testResponsesEventsRequireCompletionAndTranslateSubscriptionFailures() throws {
        XCTAssertEqual(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.output_text.delta","delta":"中文"}"#), [.text("中文")])
        XCTAssertEqual(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.reasoning_text.delta","delta":"private"}"#), [])
        XCTAssertEqual(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.completed"}"#), [.finished(truncated: false)])
        XCTAssertEqual(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.incomplete"}"#), [.finished(truncated: true)])
        XCTAssertThrowsError(try ChatGPTSubscriptionProvider.decode(#"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"secret"}}}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("allowance")); XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
        for code in ["subscription_sharing_user_not_eligible", "subscription_sharing_usage_unavailable", "subscription_sharing_invalid_user", "subscription_sharing_unsupported_capability"] {
            XCTAssertThrowsError(try ChatGPTSubscriptionProvider.decode(String(decoding: json(["type": "error", "code": code]), as: UTF8.self)))
        }
    }
    func testSwitchingAccountsCancelsBoundRequests() throws {
        let (store, _) = store(); try store.accept(account("a")); try store.accept(account("b"))
        try store.select("a|subject-a")
        var cancelled = false
        try store.registerRequest(UUID(), accountID: "a|subject-a") { cancelled = true }
        try store.select("b|subject-a")
        XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try store.registerRequest(UUID(), accountID: "a|subject-a") {})
    }
    func testSubscriptionStreamRequiresTerminalCompletionAndKeepsPartialErrors() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account())
        http.handler = { _ in (200, try self.json(["models": [["slug": "test-model", "display_name": "Test", "visibility": "list"]]])) }
        func stream(_ events: [String]) -> ChatGPTSubscriptionProvider {
            ChatGPTSubscriptionProvider(accounts: store, accountID: "test-client|subject-a", model: "test-model",
                transport: ChatGPTTestStream(status: 200, lines: events.flatMap { ["data: " + $0, ""] }))
        }
        let question = ChatRequest(system: "Explain", turns: [ChatTurn(role: "user", content: "A question")])
        let text = #"{"type":"response.output_text.delta","delta":"中文 reply"}"#
        var received: [ChatEvent] = []
        for try await event in stream([text, #"{"type":"response.completed"}"#]).stream(question) { received.append(event) }
        XCTAssertEqual(received, [.text("中文 reply"), .finished(truncated: false)])
        received = []
        do {
            for try await event in stream([text]).stream(question) { received.append(event) }
            XCTFail("EOF must not complete the answer")
        } catch { XCTAssertTrue(error is ChatError) }
        XCTAssertEqual(received, [.text("中文 reply")])
        do {
            for try await _ in stream([text, #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#]).stream(question) { }
            XCTFail("Must report plan limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("allowance")) }
    }
    func testHTTPSubscriptionEligibilityErrorDoesNotUseAnotherBillingPath() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account())
        http.handler = { _ in (200, try self.json(["models": [["slug": "test-model", "display_name": "Test", "visibility": "list"]]])) }
        let provider = ChatGPTSubscriptionProvider(accounts: store, accountID: "test-client|subject-a", model: "test-model",
            transport: ChatGPTTestStream(status: 403, lines: [#"{"error":{"code":"subscription_sharing_user_not_eligible","message":"do not echo"}}"#]))
        do {
            for try await _ in provider.stream(ChatRequest(system: "", turns: [ChatTurn(role: "user", content: "Why?")])) { }
            XCTFail("Must reject ineligible account")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not available")); XCTAssertFalse(error.localizedDescription.contains("do not echo"))
        }
        XCTAssertNotNil(store.selected?.tokens, "Eligibility does not mean the credentials were revoked")
    }
    func testOldRefreshFailureCannotEraseANewerValidatedSignIn() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account(expiry: Date().addingTimeInterval(-1)))
        http.handler = { _ in
            try await Task.sleep(for: .milliseconds(50))
            return (400, try self.json(["error": "invalid_grant"]))
        }
        let refresh = Task { try await store.accessToken(accountID: "test-client|subject-a") }
        while http.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        var newer = account(); newer.tokens?.accessToken = "newly-validated-token"
        try store.accept(newer)
        let token = try await refresh.value
        XCTAssertEqual(token, "newly-validated-token")
        XCTAssertEqual(store.selected?.tokens?.accessToken, "newly-validated-token")
    }
    func testSigningOutDuringRefreshRevokesTheRotatedToken() async throws {
        let http = ChatGPTTestHTTP(); let (store, _) = store(http: http)
        try store.accept(account(expiry: Date().addingTimeInterval(-1)))
        var revoked: String?
        http.handler = { request in
            if request.url == ChatGPTEndpoints.revoke {
                revoked = self.fields(request)["token"]; return (200, Data())
            }
            try await Task.sleep(for: .milliseconds(50))
            return (200, try self.json(["access_token": "rotated-access", "refresh_token": "rotated-refresh", "token_type": "Bearer", "expires_in": 3600]))
        }
        let refresh = Task { try await store.accessToken(accountID: "test-client|subject-a") }
        while http.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await store.signOut()
        _ = await refresh.result
        XCTAssertEqual(revoked, "rotated-refresh"); XCTAssertNil(store.selected?.tokens)
    }
    func testSubscriptionFactoryRequiresSignInEvenIfAnAPIKeyExists() throws {
        let credentials = ChatGPTTestCredentials(); let (_, defaults) = store(credentials: credentials)
        let settings = AISettingsStore(defaults: defaults, credentials: credentials)
        var config = settings.configuration; config.provider = .chatGPT
        config.profile.model = "test-model"
        credentials.values[config.credentialAccount] = "an-api-key-must-not-be-used"
        try settings.save(config, replacementKey: nil)
        XCTAssertThrowsError(try settings.provider()) { error in XCTAssertTrue(error is ChatGPTError) }
        XCTAssertTrue(credentials.values.values.contains("an-api-key-must-not-be-used"))
    }

    func testLoopbackListenerBindsIPv4AndRejectsWrongHostAndPath() async throws {
        let listener = ChatGPTLoopbackListener()
        let url = try await listener.start()
        defer { listener.stop() }
        XCTAssertEqual(url.host, "127.0.0.1"); XCTAssertEqual(url.path, "/auth/callback")
        listener.onCallback { callback in callback.query == "state=valid" }
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let accepted = try XCTUnwrap(URL(string: url.absoluteString + "?state=valid"))
        let (_, success) = try await session.data(from: accepted)
        XCTAssertEqual((success as? HTTPURLResponse)?.statusCode, 200)
        let (_, failure) = try await session.data(from: URL(string: url.absoluteString + "?state=wrong")!)
        XCTAssertEqual((failure as? HTTPURLResponse)?.statusCode, 400)
        let (_, wrongPath) = try await session.data(from: URL(string: "http://127.0.0.1:\(url.port!)/other")!)
        XCTAssertEqual((wrongPath as? HTTPURLResponse)?.statusCode, 404)
    }
}
