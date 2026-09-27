import Testing
import Foundation
@testable import mise

@MainActor
struct AppLockTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func freshLaunchRelocks() {
        #expect(AppLock.shouldRelock(backgroundedAt: nil, now: now, grace: 300))
    }

    @Test func withinGraceStaysUnlocked() {
        #expect(!AppLock.shouldRelock(backgroundedAt: now.addingTimeInterval(-59), now: now, grace: 60))
    }

    @Test func pastGraceRelocks() {
        #expect(AppLock.shouldRelock(backgroundedAt: now.addingTimeInterval(-61), now: now, grace: 60))
    }

    @Test func zeroGraceRelocksImmediately() {
        #expect(AppLock.shouldRelock(backgroundedAt: now, now: now, grace: 0))
    }

    @Test func settingsPersistAndLaunchLockedWhenOn() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let lock = AppLock(defaults: defaults)
        #expect(lock.mode == .off && lock.graceSeconds == 0 && lock.isUnlocked)
        lock.mode = .wholeApp
        lock.graceSeconds = 300
        let reloaded = AppLock(defaults: defaults)
        #expect(reloaded.mode == .wholeApp && reloaded.graceSeconds == 300 && !reloaded.isUnlocked)
    }
}
