import Foundation
import Security

protocol ChatCredentialStore {
    func read(account: String) throws -> String?
    func write(_ key: String?, account: String) throws
}

struct KeychainChatCredentials: ChatCredentialStore {
    var service = "com.weizhao.leafreader.ai"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ChatError.configuration("Could not read the API key from Keychain. Unlock the device and try again.")
        }
        return key
    }
    func write(_ key: String?, account: String) throws {
        let query = query(account)
        if let key, !key.isEmpty {
            let values: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                var item = query; values.forEach { item[$0.key] = $0.value }
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw keychainError }
            } else if status != errSecSuccess { throw keychainError }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError }
        }
    }
    private var keychainError: ChatError { .configuration("Could not update the API key in Keychain. Your settings were not saved.") }
}

@MainActor
final class AISettingsStore: ObservableObject {
    @Published private(set) var configuration: ChatConfiguration
    private let defaults: UserDefaults
    private let credentials: any ChatCredentialStore
    let providerOverride: (any ChatProvider)?
    let chatGPT: ChatGPTAccountStore
    init(defaults: UserDefaults = .standard, credentials: any ChatCredentialStore = KeychainChatCredentials(),
         providerOverride: (any ChatProvider)? = nil) {
        self.defaults = defaults; self.credentials = credentials; self.providerOverride = providerOverride
        chatGPT = ChatGPTAccountStore(defaults: defaults, credentials: credentials)
        configuration = defaults.data(forKey: "ai.configuration").flatMap { try? JSONDecoder().decode(ChatConfiguration.self, from: $0) } ?? ChatConfiguration()
    }
    func key(for configuration: ChatConfiguration) throws -> String? { try credentials.read(account: configuration.credentialAccount) }
    func save(_ configuration: ChatConfiguration, replacementKey: String?) throws {
        if configuration.provider != .chatGPT { _ = try configuration.profile.validatedURL() }
        let data = try JSONEncoder().encode(configuration)
        if let replacementKey {
            let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.contains(where: { $0.isWhitespace }) else { throw ChatError.configuration("The API key contains spaces or line breaks. Paste the key again.") }
            try credentials.write(key, account: configuration.credentialAccount)
        }
        defaults.set(data, forKey: "ai.configuration")
        self.configuration = configuration
    }
    func removeKey(for configuration: ChatConfiguration) throws { try credentials.write(nil, account: configuration.credentialAccount); objectWillChange.send() }
    func provider() throws -> any ChatProvider {
        if let providerOverride { return providerOverride }
        if configuration.provider == .chatGPT {
            guard let account = chatGPT.selected, account.tokens != nil else { throw ChatGPTError.signInRequired }
            guard account.canUsePlan else { throw ChatGPTError.permissionMissing }
            guard !configuration.profile.model.isEmpty else { throw ChatGPTError.missingModel }
            return ChatGPTSubscriptionProvider(accounts: chatGPT, accountID: account.id, model: configuration.profile.model)
        }
        _ = try configuration.profile.validatedURL()
        guard let key = try key(for: configuration), !key.isEmpty else { throw ChatError.missingKey }
        return HTTPChatProvider(kind: configuration.provider, profile: configuration.profile, apiKey: key)
    }
}
