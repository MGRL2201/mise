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
}
