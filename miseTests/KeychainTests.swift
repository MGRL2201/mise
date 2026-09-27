import Testing
import Foundation
@testable import mise

@MainActor
struct KeychainTests {
    @Test func setGetDeleteRoundTrip() throws {
        let key = "test.\(UUID().uuidString)"
        defer { try? Keychain.delete(key) }

        #expect(Keychain.get(key) == nil)

        try Keychain.set("secret-value", for: key)
        #expect(Keychain.get(key) == "secret-value")

        try Keychain.delete(key)
        #expect(Keychain.get(key) == nil)
    }

    @Test func setOverwritesExistingKey() throws {
        let key = "test.\(UUID().uuidString)"
        defer { try? Keychain.delete(key) }

        try Keychain.set("first-value", for: key)
        try Keychain.set("second-value", for: key)
        #expect(Keychain.get(key) == "second-value")
    }

    #if os(iOS)
    /// The first keychain-access-groups entitlement is the default group for new
    /// items; the stock API key must not land in the widget-readable shared group.
    @Test func setUsesAppPrivateGroupNotSharedGroup() throws {
        let key = "test.\(UUID().uuidString)"
        defer { try? Keychain.delete(key) }

        try Keychain.set("secret-value", for: key)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Bundle.main.bundleIdentifier ?? "mise",
            kSecAttrAccount: key,
            kSecUseDataProtectionKeychain: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let group = (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
        #expect(group != nil)
        #expect(group != SharedStore.keychainGroup)
    }
    #endif
}
