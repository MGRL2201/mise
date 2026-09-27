#if os(iOS)
import Testing
import Foundation
@testable import mise

/// Spike #10: runs inside the app process, so it proves the app's App Group
/// and shared keychain-access-group entitlements were provisioned.
@MainActor
struct SharedStoreTests {
    @Test func appGroupContainerExists() {
        #expect(SharedStore.containerURL != nil)
    }

    @Test func groupDefaultsRoundTrip() throws {
        let defaults = try #require(SharedStore.defaults)
        let key = "test.\(UUID().uuidString)"
        defer { defaults.removeObject(forKey: key) }

        defaults.set("group-value", forKey: key)
        #expect(defaults.string(forKey: key) == "group-value")
    }

    @Test func sharedKeychainRoundTrip() {
        let key = "test.\(UUID().uuidString)"
        defer { SharedStore.deleteSecret(key) }

        #expect(SharedStore.setSecret("shared-value", for: key) == errSecSuccess)
        #expect(SharedStore.secret(key).value == "shared-value")

        #expect(SharedStore.deleteSecret(key) == errSecSuccess)
        #expect(SharedStore.secret(key).status == errSecItemNotFound)
    }
}
#endif
