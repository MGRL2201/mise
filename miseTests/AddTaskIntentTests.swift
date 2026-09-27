import Testing
import Foundation
@testable import mise

/// Spike #12: the Siri / Shortcuts add-task intent stores the spoken title.
@MainActor
struct AddTaskIntentTests {
    @Test func performAppendsTitle() async throws {
        let key = AddTaskIntent.storeKey
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        var intent = AddTaskIntent()
        intent.title = "buy milk"
        _ = try await intent.perform()
        intent.title = "call mom"
        _ = try await intent.perform()

        #expect(UserDefaults.standard.stringArray(forKey: key) == ["buy milk", "call mom"])
    }
}
