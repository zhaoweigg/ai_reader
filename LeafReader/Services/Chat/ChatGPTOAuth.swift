import Foundation
import CryptoKit
import Security

// Public OAuth endpoints from OpenAI's discovery document; never derived from
// user-editable provider URLs. Subscription tokens never reach a custom endpoint.
enum ChatGPTEndpoints {
    static let issuer = "https://auth.openai.com"
    static let authorize = URL(string: issuer + "/api/accounts/authorize")!
    static let token = URL(string: issuer + "/api/accounts/oauth/token")!
    static let revoke = URL(string: issuer + "/api/accounts/oauth/revoke")!
    static let jwks = URL(string: issuer + "/.well-known/jwks.json")!
    static let models = URL(string: "https://api.openai.com/v1/models")!
    static let responses = URL(string: "https://api.openai.com/v1/responses")!
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
}

enum ChatGPTError: LocalizedError {
    case signInRequired, cancelled, timedOut, invalidCallback, invalidIdentity, permissionMissing, invalidRefresh
    case network, unavailable, rejected, unsupported, ineligible, usageLimit, missingModel, storage, browser, invalidResponse
    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Continue with ChatGPT in AI settings to connect your subscription."
        case .cancelled: return "Sign-in cancelled."
        case .timedOut: return "Sign-in timed out. Please try again."
        case .invalidCallback: return "The sign-in callback could not be verified. Start a new sign-in."
        case .invalidIdentity: return "OpenAI’s account identity could not be verified. Your connection was not changed."
        case .permissionMissing: return "Signed in, but permission to use your ChatGPT plan was not granted. Enable plan access in AI settings."
        case .invalidRefresh: return "Your ChatGPT session has expired or was revoked. Sign in again."
        case .invalidResponse: return "OpenAI returned a chat response Leaf could not read. Retry, or choose another available model in AI settings."
        case .network: return "Could not reach OpenAI. Your saved connection has been kept; try again when online."
        case .unavailable: return "ChatGPT plan access is temporarily unavailable. Try again later."
        case .rejected: return "OpenAI did not accept this sign-in or app registration. Check account eligibility and try again."
        case .unsupported: return "This request or model is not supported with ChatGPT plan access. Choose another available model."
        case .ineligible: return "ChatGPT plan access is not available for this account, workspace, or app. Check ChatGPT settings or choose another provider."
        case .usageLimit: return "The ChatGPT usage allowance for this app has been reached. Review ChatGPT Settings → Usage, or try again later."
        case .missingModel: return "Refresh the model list and choose an available ChatGPT model in AI settings."
        case .storage: return "Could not securely save the ChatGPT connection. Unlock your device and try again."
        case .browser: return "Could not open the secure sign-in browser. Try again while Leaf is on screen."
        }
    }
    static func response(status: Int, code: String?) -> Self {
        switch code {
        case "subscription_sharing_user_not_eligible": return .ineligible
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .unavailable
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": return .unsupported
        case "subscription_sharing_invalid_user", "invalid_grant", "invalid_refresh_token", "token_expired",
             "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused": return .invalidRefresh
        default:
            if status == 401 { return .signInRequired }
            if status == 403 { return .ineligible }
            if status == 429 { return .usageLimit }
            if status >= 500 { return .unavailable }
            return .rejected
        }
    }
}

extension Data {
    var oauthBase64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(oauthBase64 value: String) {
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
}

struct ChatGPTOAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
    let hostID: String
    let registration: ChatGPTAccount?
    init(redirectURI: URL, hostID: String, registration: ChatGPTAccount?) throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTError.rejected }
            return Data(bytes).oauthBase64
        }
        state = try random(); nonce = try random(); verifier = try random()
        self.redirectURI = redirectURI; self.hostID = hostID; self.registration = registration
    }
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).oauthBase64 }
    func authorizationURL(reconsent: Bool = false) -> URL {
        var parts = URLComponents(url: ChatGPTEndpoints.authorize, resolvingAgainstBaseURL: false)!
        var fields = ["client_id": registration?.clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                      "response_type": "code", "redirect_uri": redirectURI.absoluteString, "scope": ChatGPTEndpoints.scopes,
                      "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
                      "code_challenge_method": "S256", "code_challenge": challenge]
        if let registration {
            if let token = registration.tokens?.idToken { fields["id_token_hint"] = token }
            fields["login_hint"] = registration.email
        } else { fields["agent_name_hint"] = "Leaf" }
        if reconsent { fields["prompt"] = "consent" }
        parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    func callback(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == redirectURI.port, url.path == redirectURI.path,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              Set(parts.queryItems?.map(\.name) ?? []).count == parts.queryItems?.count else { throw ChatGPTError.invalidCallback }
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard fields["state"] == state else { throw ChatGPTError.invalidCallback }
        if fields["error"] != nil { throw ChatGPTError.cancelled }
        guard let code = fields["code"], !code.isEmpty, code.count < 8192 else { throw ChatGPTError.invalidCallback }
        let clientID = fields["client_id"] ?? registration?.clientID ?? ""
        guard !clientID.isEmpty, clientID != "dynamic_agent_client", clientID.count < 512,
              registration == nil || clientID == registration?.clientID else { throw ChatGPTError.invalidCallback }
        return (code, clientID)
    }
}

struct ChatGPTTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var scopes: [String]
    var expiresAt: Date
    var earliestRefreshAt: Date?
}
struct ChatGPTAccount: Codable, Identifiable {
    let clientID: String
    let subject: String
    var email: String
    var tokens: ChatGPTTokens?
    var id: String { clientID + "|" + subject }
    var label: String { (email.isEmpty ? "ChatGPT account" : email) + " · " + String(clientID.suffix(6)) }
    var canUsePlan: Bool { tokens?.scopes.contains("chatgpt.tokens.use.direct") == true }
}
struct ChatGPTModel: Codable, Identifiable, Equatable {
    let slug: String
    let displayName: String
    let visibility: String
    var id: String { slug }
    enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
}

protocol ChatGPTHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
struct ChatGPTURLClient: ChatGPTHTTPClient {
    var configuration: URLSessionConfiguration = .ephemeral
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: ChatRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ChatGPTError.rejected }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation(); data.append(byte)
                guard data.count <= 1048576 else { throw ChatGPTError.rejected }
            }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatGPTError { throw error }
        catch { throw ChatGPTError.network }
    }
}

struct ChatGPTOAuthClient {
    let http: any ChatGPTHTTPClient
    init(http: any ChatGPTHTTPClient = ChatGPTURLClient()) { self.http = http }
    static func form(_ fields: [String: String], url: URL = ChatGPTEndpoints.token) -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        return request
    }
    func exchange(_ attempt: ChatGPTOAuthAttempt, callback: URL) async throws -> ChatGPTAccount {
        let result = try attempt.callback(callback)
        let request = Self.form(["grant_type": "authorization_code", "client_id": result.clientID, "code": result.code,
                                 "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI.absoluteString,
                                 "resource": "https://api.openai.com/v1"])
        let payload = try await json(request)
        let tokens = try tokenSet(payload)
        let identity = try await identity(tokens.idToken, clientID: result.clientID, nonce: attempt.nonce)
        if let previous = attempt.registration, previous.subject != identity.subject { throw ChatGPTError.invalidIdentity }
        return ChatGPTAccount(clientID: result.clientID, subject: identity.subject, email: identity.email, tokens: tokens)
    }
    func refresh(_ account: ChatGPTAccount) async throws -> ChatGPTAccount {
        guard let old = account.tokens else { throw ChatGPTError.signInRequired }
        let payload = try await json(Self.form(["grant_type": "refresh_token", "client_id": account.clientID,
                                               "refresh_token": old.refreshToken, "resource": "https://api.openai.com/v1"]))
        let tokens = try tokenSet(payload, previous: old)
        var account = account
        if payload["id_token"] != nil {
            let identity = try await identity(tokens.idToken, clientID: account.clientID, nonce: nil)
            guard identity.subject == account.subject else { throw ChatGPTError.invalidIdentity }
            account.email = identity.email
        }
        account.tokens = tokens
        return account
    }
    func revoke(_ account: ChatGPTAccount) async throws {
        guard let token = account.tokens?.refreshToken else { return }
        let (data, response) = try await http.data(for: Self.form(["token": token, "token_type_hint": "refresh_token", "client_id": account.clientID], url: ChatGPTEndpoints.revoke))
        guard response.statusCode == 200 else { throw Self.error(data, status: response.statusCode) }
    }
    func models(accessToken: String) async throws -> [ChatGPTModel] {
        var request = URLRequest(url: ChatGPTEndpoints.models)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let result = try await json(request)
        guard let rows = result["models"] as? [[String: Any]], rows.count <= 2000,
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let models = try? JSONDecoder().decode([ChatGPTModel].self, from: data) else { throw ChatGPTError.rejected }
        var seen = Set<String>()
        return models.filter { $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted }
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw Self.error(data, status: response.statusCode) }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTError.rejected }
        return result
    }
    static func error(_ data: Data, status: Int) -> ChatGPTError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = body?["error"]
        let code = (error as? String) ?? (error as? [String: Any])?["code"] as? String
        return .response(status: status, code: code)
    }
    private func tokenSet(_ payload: [String: Any], previous: ChatGPTTokens? = nil) throws -> ChatGPTTokens {
        guard let access = payload["access_token"] as? String, !access.isEmpty,
              let refresh = payload["refresh_token"] as? String, !refresh.isEmpty,
              let id = payload["id_token"] as? String ?? previous?.idToken, !id.isEmpty,
              let type = payload["token_type"] as? String, type.lowercased() == "bearer",
              let expires = payload["expires_in"] as? Double, expires > 0, expires <= 86400 else { throw ChatGPTError.rejected }
        let scopes = (payload["scope"] as? String)?.split(separator: " ").map(String.init) ?? previous?.scopes ?? []
        return ChatGPTTokens(accessToken: access, refreshToken: refresh, idToken: id, scopes: scopes,
                             expiresAt: Date().addingTimeInterval(expires), earliestRefreshAt: (payload["earliest_refresh_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
    private func identity(_ token: String, clientID: String, nonce: String?) async throws -> (subject: String, email: String) {
        let keys = try await json(URLRequest(url: ChatGPTEndpoints.jwks))
        return try ChatGPTIdentityValidator.validate(token, jwks: keys, clientID: clientID, nonce: nonce)
    }
}

// Verify RS256 before trusting any identity, including email, subject, nonce, or
// audience. The public key is fetched only from OpenAI's pinned HTTPS JWKS URL.
enum ChatGPTIdentityValidator {
    static func validate(_ token: String, jwks: [String: Any], clientID: String, nonce: String?, now: Date = Date()) throws -> (subject: String, email: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard token.utf8.count < 65536, parts.count == 3,
              let headerData = Data(oauthBase64: parts[0]), let claimsData = Data(oauthBase64: parts[1]), let signature = Data(oauthBase64: parts[2]),
              let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any],
              let claims = (try? JSONSerialization.jsonObject(with: claimsData)) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" }),
              (jwk["alg"] as? String ?? "RS256") == "RS256",
              let n = jwk["n"] as? String, let modulus = Data(oauthBase64: n), (256...1024).contains(modulus.count),
              let e = jwk["e"] as? String, let exponent = Data(oauthBase64: e), !exponent.isEmpty, exponent.count <= 8 else { throw ChatGPTError.invalidIdentity }
        func der(_ tag: UInt8, _ data: Data) -> Data {
            let count = data.count
            let length: [UInt8] = count < 128 ? [UInt8(count)] : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
            return Data([tag] + length) + data
        }
        func integer(_ data: Data) -> Data {
            var bytes = data
            while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
            if (bytes.first ?? 0) & 0x80 != 0 { bytes.insert(0, at: 0) }
            return der(0x02, bytes)
        }
        let keyData = der(0x30, integer(modulus) + integer(exponent))
        guard let key = SecKeyCreateWithData(keyData as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else { throw ChatGPTError.invalidIdentity }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == ChatGPTEndpoints.issuer, audiences.contains(clientID),
              audiences.count <= 1 || claims["azp"] as? String == clientID,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              (claims["iat"] as? Double ?? now.timeIntervalSince1970) <= now.timeIntervalSince1970 + 60,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60,
              nonce == nil || claims["nonce"] as? String == nonce else { throw ChatGPTError.invalidIdentity }
        return (subject, String((claims["email"] as? String ?? "").prefix(320)))
    }
}
