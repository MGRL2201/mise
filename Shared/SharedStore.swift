import Foundation
import Security

/// Spike #10: App Group container and shared keychain group, used by the app
/// and the widget. Ids come from the MiseAppGroup / MiseKeychainGroup
/// Info.plist keys (expanded from build settings, so no team id in source).
nonisolated enum SharedStore {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "MiseAppGroup") as? String ?? ""
    static let keychainGroup = Bundle.main.object(forInfoDictionaryKey: "MiseKeychainGroup") as? String ?? ""

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// nil when the App Group isn't provisioned (no container).
    static var defaults: UserDefaults? {
        containerURL == nil ? nil : UserDefaults(suiteName: appGroup)
    }

    private static func query(_ key: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "mise.shared",
            kSecAttrAccount: key,
            kSecAttrAccessGroup: keychainGroup,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    @discardableResult
    static func setSecret(_ value: String, for key: String) -> OSStatus {
        deleteSecret(key)
        var attributes = query(key)
        attributes[kSecValueData] = Data(value.utf8)
        // Widget may render before the user unlocks again.
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func secret(_ key: String) -> (value: String?, status: OSStatus) {
        var attributes = query(key)
        attributes[kSecReturnData] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return ((result as? Data).flatMap { String(data: $0, encoding: .utf8) }, status)
    }

    @discardableResult
    static func deleteSecret(_ key: String) -> OSStatus {
        SecItemDelete(query(key) as CFDictionary)
    }
}
