import Foundation
import Security

enum KeychainService {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SimpleReader", kSecAttrAccount as String: key]
    }
    static func read(_ key: String) throws -> String {
        try storedValue(key) ?? ""
    }
    static func storedValue(_ key: String) throws -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AppFailure("Couldn’t read secure credentials (\(status)).")
        }
        return value
    }
    static func save(_ value: String, key: String) throws {
        let q = query(key)
        let data = Data(value.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppFailure("Couldn’t save secure credentials (\(added)).") }; return
        }
        guard status == errSecSuccess else { throw AppFailure("Couldn’t save secure credentials (\(status)).") }
    }
    static func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppFailure("Couldn’t delete secure credentials (\(status)).")
        }
    }
}
