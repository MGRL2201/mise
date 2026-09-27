import Foundation
import Security

enum Keychain {
    static let stockAPIKey = "stockAPIKey"

    struct Error: Swift.Error {
        let status: OSStatus
    }

    private static let service = Bundle.main.bundleIdentifier ?? "mise"

    private static func query(for key: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        #if os(iOS)
        query[kSecUseDataProtectionKeychain] = true
        #endif
        return query
    }

    static func set(_ value: String, for key: String) throws {
        var attributes = query(for: key)
        attributes[kSecValueData] = Data(value.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw Error(status: status) }
        let updateStatus = SecItemUpdate(
            query(for: key) as CFDictionary, [kSecValueData: Data(value.utf8)] as CFDictionary
        )
        guard updateStatus == errSecSuccess else { throw Error(status: updateStatus) }
    }

    static func get(_ key: String) -> String? {
        var attributes = query(for: key)
        attributes[kSecReturnData] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error(status: status)
        }
    }
}
