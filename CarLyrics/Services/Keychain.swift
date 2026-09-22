import Foundation
import Security

struct KeychainError: Error {
    let status: OSStatus
}

/// 簡單的 Keychain 包裝（generic password）
enum Keychain {
    static let service = "com.willsonhsu.CarLyrics"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ data: Data, account: String) throws {
        SecItemDelete(baseQuery(account) as CFDictionary)
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = data
        // 鎖定畫面後背景執行也要能讀取
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
