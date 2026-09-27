import Testing
import Foundation
import EventKit
@testable import mise

@MainActor
struct RemindersStoreTests {
    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func crudAndCompletionRoundTripThroughEventKit() async throws {
        let store = RemindersStore()
        await store.refresh()

        let list = try store.newList(title: "mise-test-\(UUID().uuidString)")
        defer { try? store.deleteList(list) }

        let reminder = store.newReminder(in: list)
        reminder.title = "mise test reminder"
        reminder.priority = 1
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 1)
        let rule = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        reminder.recurrenceRules = [rule]
        reminder.alarms = [EKAlarm(relativeOffset: -600)]
        try store.save(reminder)
        defer { try? store.delete(reminder) }

        await store.refresh()
        let identifier = reminder.calendarItemIdentifier
        let fetched = try #require(store.reminders.first { $0.calendarItemIdentifier == identifier })
        #expect(fetched.title == "mise test reminder")
        #expect(fetched.priority == 1)
        #expect(fetched.dueDateComponents.flatMap { Calendar.current.date(from: $0) } != nil)
        #expect(fetched.recurrenceRules?.first?.frequency == .weekly)
        #expect(fetched.alarms?.first?.relativeOffset == -600)

        // Prove the external path: a second EKEventStore stands in for another
        // app (e.g. Reminders.app) editing/removing behind our back, and
        // `store.reminders` must update via the EKEventStoreChanged
        // notification loop alone — no manual refresh.
        let otherStore = EKEventStore()
        let editedTitle = "mise test reminder edited externally"
        // Our own saves above post EKEventStoreChanged too; wait for those
        // refreshes to drain so only the external edit can fire the flag.
        // Bounded so a steady notification stream can't hang the test.
        var changed: Flag
        var quietChecks = 0
        repeat {
            changed = Flag()
            withObservationTracking { _ = store.reminders } onChange: { [changed] in changed.fired = true }
            try await Task.sleep(nanoseconds: 500_000_000)
            quietChecks += 1
        } while changed.fired && quietChecks < 20
        try await pollUntil(timeout: 5) {
            guard let external = otherStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
                return false
            }
            external.title = editedTitle
            try otherStore.save(external, commit: true)
            return true
        }

        try await pollUntil(timeout: 5) {
            store.reminders.first { $0.calendarItemIdentifier == identifier }?.title == editedTitle
        }
        // #126: SwiftUI only re-renders if observers are notified.
        try await pollUntil(timeout: 5) { changed.fired }

        guard let externalToRemove = otherStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            Issue.record("could not re-fetch reminder from second store")
            return
        }
        try otherStore.remove(externalToRemove, commit: true)

        try await pollUntil(timeout: 5) {
            !store.reminders.contains { $0.calendarItemIdentifier == identifier }
        }

        // Completion: use a separate, non-recurring reminder in the same temp
        // list. (A recurring reminder rolls forward to its next occurrence on
        // completion instead of staying marked complete.)
        let completable = store.newReminder(in: list)
        completable.title = "mise test completable"
        try store.save(completable)
        defer { try? store.delete(completable) }

        try store.setCompleted(completable, true)
        let completedIdentifier = completable.calendarItemIdentifier
        let reread = try #require(store.eventStore.calendarItem(withIdentifier: completedIdentifier) as? EKReminder)
        #expect(reread.isCompleted)

        try store.deleteList(list)
        await store.refresh()
        #expect(!store.lists.contains { $0.calendarIdentifier == list.calendarIdentifier })
    }

    /// Polls `condition` until it returns true or `timeout` elapses.
    private func pollUntil(timeout: TimeInterval, condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("condition did not become true within \(timeout)s")
    }
}
