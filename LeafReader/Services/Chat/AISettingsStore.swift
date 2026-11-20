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
    /// The reader's quick prompts for selected text, in the order shown in Ask Leaf.
    @Published private(set) var quickPrompts: [ChatQuickPrompt]
    private let defaults: UserDefaults
    private let credentials: any ChatCredentialStore
    let providerOverride: (any ChatProvider)?
    let chatGPT: ChatGPTAccountStore
    init(defaults: UserDefaults = .standard, credentials: any ChatCredentialStore = KeychainChatCredentials(),
         providerOverride: (any ChatProvider)? = nil, chatGPTOverride: ChatGPTAccountStore? = nil) {
        self.defaults = defaults; self.credentials = credentials; self.providerOverride = providerOverride
        chatGPT = chatGPTOverride ?? ChatGPTAccountStore(defaults: defaults, credentials: credentials)
        let saved = defaults.data(forKey: Self.configurationKey)
        storedConfiguration = saved
        configuration = saved.flatMap { try? JSONDecoder().decode(ChatConfiguration.self, from: $0) } ?? ChatConfiguration()
        let stored = defaults.data(forKey: Self.promptsKey)
        storedPrompts = stored; quickPrompts = Self.prompts(from: stored)
        // Settings and prompts changed on another device arrive through iCloud Drive sync while the app is open.
        syncObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadConfiguration(); self?.reloadQuickPrompts() }
        }
    }
    private static let configurationKey = "ai.configuration", promptsKey = "chat.quickPrompts"
    private var storedConfiguration: Data?
    private var storedPrompts: Data?
    private var syncObserver: NSObjectProtocol?
    /// Runs on every defaults change, so it compares the stored bytes before decoding.
    /// A value this version cannot read leaves the settings in use as they are.
    private func reloadConfiguration() {
        let data = defaults.data(forKey: Self.configurationKey)
        guard data != storedConfiguration else { return }
        storedConfiguration = data
        guard let data, let saved = try? JSONDecoder().decode(ChatConfiguration.self, from: data), saved != configuration else { return }
        configuration = saved
    }
    /// Nothing stored, or the empty value a reset leaves, means the default list.
    private static func prompts(from data: Data?) -> [ChatQuickPrompt] {
        data.flatMap { try? JSONDecoder().decode([ChatQuickPrompt].self, from: $0) } ?? ChatQuickPrompt.defaults
    }
    /// Runs on every defaults change, so it compares the stored bytes before decoding.
    private func reloadQuickPrompts() {
        let data = defaults.data(forKey: Self.promptsKey)
        guard data != storedPrompts else { return }
        storedPrompts = data
        let prompts = Self.prompts(from: data)
        if prompts != quickPrompts { quickPrompts = prompts }
    }
    /// Saves the prompts that can be shown. A list that was never edited stores
    /// nothing; going back to the defaults stores an empty value rather than
    /// removing it, so that the reset reaches the reader's other devices.
    func saveQuickPrompts(_ prompts: [ChatQuickPrompt]) {
        let kept = ChatQuickPrompt.shown(prompts)
        let encoded = kept == ChatQuickPrompt.defaults ? Data() : (try? JSONEncoder().encode(kept))
        guard kept != quickPrompts, let data = encoded else { return }
        quickPrompts = kept; storedPrompts = data
        defaults.set(data, forKey: Self.promptsKey)
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
        storedConfiguration = data
        defaults.set(data, forKey: Self.configurationKey)
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
