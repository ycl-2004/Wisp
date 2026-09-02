import Foundation
import Security

/// API Key 存 Keychain，不进 UserDefaults，也不进对话 JSON。
/// 一家服务商一份条目，切换服务商时不会互相顶掉。
enum KeychainStore {
    private static let service = "com.yichenlin.Wisp"
    /// 0.2.x 只有一份 Key，不分家。只在迁移时读它。
    private static let legacyAccount = "api-key"

    // MARK: - 按服务商读写

    @discardableResult
    static func save(_ key: String, for provider: CloudProvider) -> Bool {
        write(key, account: provider.keychainAccount)
    }

    static func load(for provider: CloudProvider) -> String? {
        read(account: provider.keychainAccount)
    }

    @discardableResult
    static func delete(for provider: CloudProvider) -> Bool {
        remove(account: provider.keychainAccount)
    }

    static func hasKey(for provider: CloudProvider) -> Bool { load(for: provider) != nil }

    /// 清除全部数据时用：把每一家的 Key 连同旧条目一起删掉。
    static func deleteAll() {
        for provider in CloudProvider.allCases { remove(account: provider.keychainAccount) }
        remove(account: legacyAccount)
    }

    // MARK: - 迁移

    /// 0.2.x 升上来时，把那份不分家的 Key 记到它当时实际在用的那家名下，然后删掉旧条目。
    /// 只在旧条目还在时做事，重复调用无副作用。
    ///
    /// 认哪一家交给 `resolvingProvider` 现算，并且只在真有旧条目时才调用它：
    /// 那个判断会顺手钉住老的云端配置，全新安装不该被当成升级走这一遭。
    static func migrateLegacyKeyIfNeeded(resolvingProvider: () -> CloudProvider) {
        guard let legacy = read(account: legacyAccount) else { return }
        let provider = resolvingProvider()
        if read(account: provider.keychainAccount) == nil {
            _ = write(legacy, account: provider.keychainAccount)
        }
        remove(account: legacyAccount)
    }

    // MARK: - 底层

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func write(_ key: String, account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)

        var attributes = query(account)
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    private static func remove(account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
