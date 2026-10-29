import Testing
import Foundation
import SwiftUI
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

    @Test func coverState() {
        #if os(macOS)
        let snapshotCover = false  // no app-switcher snapshot on macOS
        #else
        let snapshotCover = true
        #endif
        let locked = AppLock.cover(mode: .wholeApp, isUnlocked: false, phase: .active, returning: false)
        #expect(locked.locked && !locked.privacy)
        let unlocked = AppLock.cover(mode: .wholeApp, isUnlocked: true, phase: .active, returning: false)
        #expect(!unlocked.locked && !unlocked.privacy)
        let finance = AppLock.cover(mode: .financeAndNotes, isUnlocked: false, phase: .inactive, returning: false)
        #expect(!finance.locked && finance.privacy == snapshotCover)
        // Back to active but the relock check hasn't run yet: stay covered.
        let returning = AppLock.cover(mode: .wholeApp, isUnlocked: true, phase: .active, returning: true)
        #expect(!returning.locked && returning.privacy == snapshotCover)
        let off = AppLock.cover(mode: .off, isUnlocked: true, phase: .background, returning: true)
        #expect(!off.locked && !off.privacy)
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
