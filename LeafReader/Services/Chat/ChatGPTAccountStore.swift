import Foundation

private struct ChatGPTVault: Codable {
    var accounts: [ChatGPTAccount] = []
    var selectedID: String?
}

@MainActor
final class ChatGPTAccountStore: ObservableObject {
    @Published private(set) var accounts: [ChatGPTAccount] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isLoadingModels = false
    @Published var error: String?
    @Published var notice: String?
    private let credentials: any ChatCredentialStore
    private let defaults: UserDefaults
    private let client: ChatGPTOAuthClient
    private let browser: any ChatGPTAuthorizing
    private let vaultAccount = "chatgpt.oauth.v1"
    private var refreshes: [String: Task<ChatGPTAccount, Error>] = [:]
    private var requests: [UUID: (String, () -> Void)] = [:]
    private var blocked = Set<String>()
    private var revisions: [String: UUID] = [:]
    private var catalogTasks: [String: Task<[ChatGPTModel], Error>] = [:]
    private var signInTask: Task<Void, Never>?
    var selected: ChatGPTAccount? { accounts.first { $0.id == selectedID } }
    var hostID: String {
        if let id = defaults.string(forKey: "chatgpt.hostID") { return id }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: "chatgpt.hostID"); return id
    }
    init(defaults: UserDefaults, credentials: any ChatCredentialStore, client: ChatGPTOAuthClient = ChatGPTOAuthClient(), browser: (any ChatGPTAuthorizing)? = nil) {
        self.defaults = defaults; self.credentials = credentials; self.client = client
        self.browser = browser ?? ChatGPTBrowserSignIn()
        do {
            if let text = try credentials.read(account: vaultAccount) {
                let saved = try JSONDecoder().decode(ChatGPTVault.self, from: Data(text.utf8))
                accounts = saved.accounts; selectedID = saved.selectedID
            }
        } catch { self.error = ChatGPTError.storage.localizedDescription }
    }
    func select(_ id: String) throws {
        guard accounts.contains(where: { $0.id == id }), !isBusy else { return }
        try persist(accounts, selected: id)
        cancelRequests(); selectedID = id; models = []; error = nil; notice = nil
    }
    func signIn(existing: ChatGPTAccount? = nil, reconsent: Bool = false) {
        guard !isBusy else { return }
        isBusy = true; error = nil; notice = nil
        signInTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.signInTask = nil }
            do {
                let (attempt, callback) = try await self.browser.authorize(hostID: self.hostID, registration: existing, reconsent: reconsent)
                let account = try await self.client.exchange(attempt, callback: callback)
                try Task.checkCancellation()
                try self.accept(account)
                if !account.canUsePlan { self.notice = ChatGPTError.permissionMissing.localizedDescription }
                else { await self.loadModels() }
            } catch ChatGPTError.cancelled {
                // Cancelling an optional login leaves the current connection intact.
            } catch is CancellationError {
            } catch let failure as URLError where failure.code == .cancelled {
            } catch {
                if !Task.isCancelled { self.error = Self.message(error) }
            }
        }
    }
    func cancelSignIn() { signInTask?.cancel(); browser.cancel() }
    func accept(_ account: ChatGPTAccount) throws {
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account }
        else { updated.append(account) }
        try persist(updated, selected: account.id)
        revisions[account.id] = UUID()
        catalogTasks[account.id]?.cancel(); catalogTasks[account.id] = nil
        cancelRequests(); accounts = updated; selectedID = account.id; models = []
    }
    func signOut() async {
        guard let selected, !isBusy else { return }
        isBusy = true; error = nil; notice = nil; blocked.insert(selected.id)
        cancelRequests()
        defer { blocked.remove(selected.id); isBusy = false }
        var account = selected
        if let refresh = refreshes[selected.id], let updated = try? await refresh.value { account = updated }
        var confirmed = true
        do { try await client.revoke(account) } catch { confirmed = false }
        account.tokens = nil
        do {
            var updated = accounts
            if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account }
            try persist(updated, selected: account.id)
            revisions[account.id] = UUID()
            accounts = updated; models = []
            notice = confirmed ? "Signed out of ChatGPT." : "Signed out on this device. Remote revocation could not be confirmed; disconnect Leaf in ChatGPT Settings → Usage."
        } catch { self.error = ChatGPTError.storage.localizedDescription }
    }
    func accessToken(accountID: String) async throws -> String {
        guard selectedID == accountID, !blocked.contains(accountID), let account = accounts.first(where: { $0.id == accountID }),
              let tokens = account.tokens else { throw ChatGPTError.signInRequired }
        guard account.canUsePlan else { throw ChatGPTError.permissionMissing }
        let now = Date()
        let refreshAfter = max(tokens.expiresAt.addingTimeInterval(-120), tokens.earliestRefreshAt ?? .distantPast)
        if now < refreshAfter && now < tokens.expiresAt { return tokens.accessToken }
        let refresh = refreshes[accountID] ?? Task { try await client.refresh(account) }
        let revision = revisions[accountID]
        refreshes[accountID] = refresh
        defer { refreshes[accountID] = nil }
        do {
            let updated = try await refresh.value
            guard !blocked.contains(accountID) else { throw ChatGPTError.signInRequired }
            if revisions[accountID] != revision { return try currentAccessToken(accountID) }
            var values = accounts
            guard let index = values.firstIndex(where: { $0.id == accountID }), values[index].tokens != nil else { throw ChatGPTError.signInRequired }
            values[index] = updated
            try persist(values, selected: selectedID); accounts = values
            guard selectedID == accountID, let token = updated.tokens?.accessToken else { throw ChatGPTError.signInRequired }
            guard updated.canUsePlan else { throw ChatGPTError.permissionMissing }
            return token
        } catch ChatGPTError.invalidRefresh {
            if revisions[accountID] != revision { return try currentAccessToken(accountID) }
            var values = accounts
            if let index = values.firstIndex(where: { $0.id == accountID }) { values[index].tokens = nil }
            try persist(values, selected: selectedID); accounts = values; cancelRequests(accountID)
            throw ChatGPTError.invalidRefresh
        }
    }
    /// The stored token after a sign-in or sign-out replaced the account mid-refresh;
    /// the refreshed token belongs to a session that no longer exists.
    private func currentAccessToken(_ accountID: String) throws -> String {
        guard let current = accounts.first(where: { $0.id == accountID }), let tokens = current.tokens else { throw ChatGPTError.signInRequired }
        guard current.canUsePlan else { throw ChatGPTError.permissionMissing }
        return tokens.accessToken
    }
    func loadModels() async {
        guard let id = selectedID, !isLoadingModels else { return }
        isLoadingModels = true; error = nil
        defer { isLoadingModels = false }
        do {
            let models = try await catalog(accountID: id)
            guard selectedID == id, selected?.tokens != nil else { return }
            self.models = models
            if models.isEmpty { notice = "No models are currently available to this ChatGPT account." }
        } catch { if selectedID == id { self.error = Self.message(error) } }
    }
    private func catalog(accountID: String) async throws -> [ChatGPTModel] {
        let revision = revisions[accountID]
        let task = catalogTasks[accountID] ?? Task { @MainActor in
            let token = try await self.accessToken(accountID: accountID)
            return try await self.client.models(accessToken: token)
        }
        catalogTasks[accountID] = task
        defer { catalogTasks[accountID] = nil }
        let models = try await task.value
        guard selectedID == accountID, selected?.tokens != nil, revisions[accountID] == revision else { throw ChatGPTError.signInRequired }
        return models
    }
    func validateModel(_ model: String, accountID: String) async throws {
        guard selectedID == accountID else { throw ChatGPTError.signInRequired }
        if models.isEmpty { models = try await catalog(accountID: accountID) }
        guard models.contains(where: { $0.slug == model }) else { throw ChatGPTError.missingModel }
    }
    func registerRequest(_ id: UUID, accountID: String, cancel: @escaping () -> Void) throws {
        guard selectedID == accountID, selected?.tokens != nil, !blocked.contains(accountID) else { throw ChatGPTError.signInRequired }
        requests[id] = (accountID, cancel)
    }
    func unregisterRequest(_ id: UUID) { requests[id] = nil }
    private func cancelRequests(_ accountID: String? = nil) {
        let matches = requests.filter { accountID == nil || $0.value.0 == accountID }
        for (id, value) in matches { requests[id] = nil; value.1() }
    }
    private func persist(_ accounts: [ChatGPTAccount], selected: String?) throws {
        do {
            let data = try JSONEncoder().encode(ChatGPTVault(accounts: accounts, selectedID: selected))
            try credentials.write(String(decoding: data, as: UTF8.self), account: vaultAccount)
        } catch { throw ChatGPTError.storage }
    }
    static func message(_ error: Error) -> String {
        if let error = error as? ChatGPTError { return error.localizedDescription }
        if error is CancellationError { return ChatGPTError.cancelled.localizedDescription }
        return ChatGPTError.network.localizedDescription
    }
    #if DEBUG
    static func uiTestConnected(defaults: UserDefaults, credentials: any ChatCredentialStore) -> ChatGPTAccountStore {
        let store = ChatGPTAccountStore(defaults: defaults, credentials: credentials,
            client: ChatGPTOAuthClient(http: UITestChatGPTCatalog()), browser: UITestChatGPTSignIn())
        let account = ChatGPTAccount(clientID: "ui-test-client", subject: "ui-test-reader", email: "reader@example.test",
            tokens: ChatGPTTokens(accessToken: "ui-test-only", refreshToken: "ui-test-only", idToken: "ui-test-only",
                scopes: ["chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(3600)))
        try? store.accept(account)
        var configuration = ChatConfiguration(); configuration.provider = .chatGPT; configuration.profile.model = "ui-test-model"
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: "ai.configuration") }
        return store
    }
    func testBrowserLoopback() async {
        guard !isBusy, let browser = browser as? ChatGPTBrowserSignIn else { return }; isBusy = true; error = nil; notice = nil
        defer { isBusy = false }
        do { _ = try await browser.testLoopback(); notice = "Native browser callback verified." }
        catch { self.error = Self.message(error) }
    }
    #endif
}
