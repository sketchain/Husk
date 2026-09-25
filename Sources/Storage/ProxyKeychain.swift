import Foundation
import Security

/// 代理密码存 Keychain，按 profile 名一条。配置 JSON 里只有用户名。
///
/// 选 `AfterFirstUnlockThisDeviceOnly`：
/// - `AfterFirstUnlock`：锁屏后台时 app 被唤醒（比如快捷指令冷启动）也要能读到密码去建连接；
/// - `ThisDeviceOnly`：不进 iCloud 钥匙串、不跟着加密备份迁到别的设备。代理密码跟着配置走的
///   唯一途径是用户自己重填——和导出不带密码是同一个取舍，见 README。
enum ProxyKeychain {
    private static let service = "Husk.proxy"

    static func password(forProfile profile: String) -> String? {
        var query = baseQuery(profile)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasPassword(forProfile profile: String) -> Bool {
        password(forProfile: profile) != nil
    }

    /// 写入或覆盖。返回是否成功（失败时调用方要提示，不能当成已保存）。
    @discardableResult
    static func setPassword(_ password: String, forProfile profile: String) -> Bool {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(profile) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var add = baseQuery(profile)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func removePassword(forProfile profile: String) {
        SecItemDelete(baseQuery(profile) as CFDictionary)
    }

    private static func baseQuery(_ profile: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile,
        ]
    }
}
