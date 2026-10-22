import Foundation
import Network
import AuthenticationServices
import UIKit

// The callback is an ephemeral IPv4 loopback listener, not a web service exposed
// on Wi-Fi. The browser stays in an ASWebAuthenticationSession while it runs.
@MainActor
final class ChatGPTLoopbackListener {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var receive: ((URL) -> Bool)?
    private var deadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var callbackURL: URL?

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { self.stop(); return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.callbackURL = url
                    self.ready?.resume(returning: url); self.ready = nil
                case .failed:
                    self.ready?.resume(throwing: ChatGPTError.browser); self.ready = nil; self.stop()
                default: break
                }
            } }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
                guard let self, self.connections.count < 8 else { connection.cancel(); return }
                self.connections[ObjectIdentifier(connection)] = connection
                self.deadlines[ObjectIdentifier(connection)] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)); self?.close(connection) }
                    catch { }
                }
                connection.start(queue: .main)
                self.read(connection, data: Data())
            } }
            listener.start(queue: .main)
        }
    }
    func onCallback(_ receive: @escaping (URL) -> Bool) { self.receive = receive }
    private func read(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let bytes = data + (chunk ?? Data())
                guard bytes.count <= 16384 else { self.respond(connection, status: "413 Content Too Large", accepted: false); return }
                if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                    let lines = head.components(separatedBy: "\r\n")
                    let start = lines.first?.split(separator: " ").map(String.init) ?? []
                    let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
                    guard let base = self.callbackURL, start.count == 3, start[0] == "GET",
                          start[1].hasPrefix("/auth/callback?"), hosts.count == 1,
                          hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() == "127.0.0.1:\(base.port!)",
                          let url = URL(string: "http://127.0.0.1:\(base.port!)" + start[1]), url.path == base.path else {
                        self.respond(connection, status: "404 Not Found", accepted: false); return
                    }
                    let accepted = self.receive?(url) ?? false
                    self.respond(connection, status: accepted ? "200 OK" : "400 Bad Request", accepted: accepted)
                } else if complete || error != nil { self.close(connection) }
                else { self.read(connection, data: bytes) }
            }
        }
    }
    private func respond(_ connection: NWConnection, status: String, accepted: Bool) {
        let message = accepted ? "Return to Leaf. Your sign-in is being verified." : "This callback was not accepted. Return to Leaf and try signing in again."
        let body = "<!doctype html><meta name=viewport content='width=device-width'><title>Leaf</title><p>\(message)</p>"
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((header + body).utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }
    private func close(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        deadlines[id]?.cancel(); deadlines[id] = nil
        connection.cancel(); connections[id] = nil
    }
    func stop() {
        ready?.resume(throwing: ChatGPTError.cancelled); ready = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections = [:]
        for deadline in deadlines.values { deadline.cancel() }; deadlines = [:]
        receive = nil
    }
}

@MainActor
protocol ChatGPTAuthorizing {
    func authorize(hostID: String, registration: ChatGPTAccount?, reconsent: Bool) async throws -> (ChatGPTOAuthAttempt, URL)
    func cancel()
}

@MainActor
final class ChatGPTBrowserSignIn: NSObject, ChatGPTAuthorizing, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private var listener: ChatGPTLoopbackListener?
    private var pending: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var busy = false

    func authorize(hostID: String, registration: ChatGPTAccount?, reconsent: Bool = false) async throws -> (ChatGPTOAuthAttempt, URL) {
        guard !busy else { throw ChatGPTError.browser }
        busy = true
        defer { busy = false; cleanup() }
        let listener = ChatGPTLoopbackListener(); self.listener = listener
        let redirect = try await listener.start()
        let attempt = try ChatGPTOAuthAttempt(redirectURI: redirect, hostID: hostID, registration: registration)
        let result = try await callback(attempt, url: attempt.authorizationURL(reconsent: reconsent))
        return (attempt, result)
    }
    // Used by the native-browser integration test: exercise the same browser and
    // listener with a local callback, without contacting a provider or signing in.
    #if DEBUG
    func testLoopback() async throws -> URL {
        guard !busy else { throw ChatGPTError.browser }
        busy = true
        defer { busy = false; cleanup() }
        let listener = ChatGPTLoopbackListener(); self.listener = listener
        let redirect = try await listener.start()
        let attempt = try ChatGPTOAuthAttempt(redirectURI: redirect, hostID: "urn:uuid:\(UUID())", registration: nil)
        var parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "state", value: attempt.state), URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "client_id", value: "test-client")]
        return try await callback(attempt, url: parts.url!)
    }
    #endif
    private func callback(_ attempt: ChatGPTOAuthAttempt, url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                listener?.onCallback { [weak self] url in
                    // A mismatched state must not terminate a genuine pending login.
                    let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" }
                    guard states?.count == 1, states?.first?.value == attempt.state else { return false }
                    do { _ = try attempt.callback(url); self?.finish(.success(url)) }
                    catch { self?.finish(.failure(error)) }
                    return true
                }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, _ in
                    Task { @MainActor in self?.finish(.failure(ChatGPTError.cancelled)) }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                self.browser = browser
                guard browser.start() else { finish(.failure(ChatGPTError.browser)); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)); self?.finish(.failure(ChatGPTError.timedOut)) }
                    catch { }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(with: result)
        // Allow the loopback HTTP response to be queued before closing the browser.
        browser?.cancel(); browser = nil
        timeout?.cancel(); timeout = nil
    }
    func cancel() { finish(.failure(ChatGPTError.cancelled)); cleanup() }
    private func cleanup() { listener?.stop(); listener = nil; browser?.cancel(); browser = nil; timeout?.cancel(); timeout = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
