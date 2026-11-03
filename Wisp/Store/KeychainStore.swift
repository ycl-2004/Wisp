import Foundation
import Security

extension Notification.Name {
    /// 钥匙串里的 Key 真的变了（写入成功、或删掉了一条实际存在的条目）时发。
    /// Key 的写路径全是纯 KeychainStore 调用，不经过 AppSettings，所以
    /// readiness 缓存订不到设置变更那条线，只能靠这个通知补上
    /// （UX 改造第 2 项检查发现）。
    static let wispKeychainDidChange = Notification.Name("wispKeychainDidChange")
}

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
    /// 返回是否全部删干净 — 以前不返回结果，擦除失败时用户以为 Key
    /// 已经没了，其实还躺在钥匙串里（#43）。
    @discardableResult
    static func deleteAll() -> Bool {
        var allRemoved = true
        for provider in CloudProvider.allCases {
            if !remove(account: provider.keychainAccount) { allRemoved = false }
        }
        if !remove(account: legacyAccount) { allRemoved = false }
        return allRemoved
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
        // 副本确认存在了才删原件：写入失败时删掉原件，这份 Key 就找不回来了（#43）。
        if read(account: provider.keychainAccount) != nil {
            remove(account: legacyAccount)
        }
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
        let saved = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        // save 与旧钥迁移写入都走这里，写成功才算「变了」。
        if saved { NotificationCenter.default.post(name: .wispKeychainDidChange, object: nil) }
        return saved
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
        // delete/deleteAll 与迁移删原件都走这里。只有真的删掉了一条存在的
        // 条目才算「变了」；本来就没有（errSecItemNotFound）不发通知，
        // 免得 deleteAll 遍历一圈空条目刷出一串无意义的刷新。
        if status == errSecSuccess {
            NotificationCenter.default.post(name: .wispKeychainDidChange, object: nil)
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
