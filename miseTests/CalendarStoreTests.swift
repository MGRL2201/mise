import Testing
import Foundation
import EventKit
@testable import mise

@MainActor
struct CalendarStoreTests {
    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .event) == .fullAccess))
    func recurringCrudAndSpansRoundTripThroughEventKit() async throws {
        let store = CalendarStore()
        await store.refresh()

        let source = try #require(
            store.eventStore.defaultCalendarForNewEvents?.source
                ?? store.eventStore.sources.first { $0.sourceType == .local }
        )
        let calendar = EKCalendar(for: .event, eventStore: store.eventStore)
        calendar.title = "mise-test-\(UUID().uuidString)"
        calendar.source = source
        try store.eventStore.saveCalendar(calendar, commit: true)
        defer { try? store.eventStore.removeCalendar(calendar, commit: true) }

        // Weekly, 3 occurrences, starting next week at 10:00, 1h long.
        let today = Calendar.current.startOfDay(for: .now)
        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: today)!
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: nextWeek)!
        let event = store.newEvent(in: calendar)
        event.title = "mise test event"
        event.startDate = start
        event.endDate = start.addingTimeInterval(60 * 60)
        event.recurrenceRules = [
            EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))
        ]
        try store.save(event)

        store.range = DateInterval(start: today, duration: 5 * 7 * 24 * 60 * 60)
        await store.refresh()
        #expect(store.calendars.contains { $0.calendarIdentifier == calendar.calendarIdentifier })
        func occurrences() -> [EKEvent] {
            store.events.filter { $0.calendar.calendarIdentifier == calendar.calendarIdentifier }
        }
        #expect(occurrences().count == 3)

        // .futureEvents edit from the 2nd occurrence splits the series.
        let second = try #require(occurrences().dropFirst().first)
        second.title = "mise test event renamed"
        try store.save(second, span: .futureEvents)
        #expect(occurrences().map(\.title) == ["mise test event", "mise test event renamed", "mise test event renamed"])

        // .thisEvent delete of the 3rd occurrence. (Not the 1st: after the
        // split above it is a COUNT=1 series, and EventKit silently ignores a
        // .thisEvent removal of a series' only occurrence.)
        let third = try #require(occurrences().last)
        try store.delete(third, span: .thisEvent)
        #expect(occurrences().count == 2)

        // External path: a second EKEventStore stands in for another app
        // (e.g. Calendar.app); only the EKEventStoreChanged loop may update
        // `store.events` — no manual refresh.
        let otherStore = EKEventStore()
        let firstStart: Date = try #require(occurrences().first).startDate
        func externalFirst() -> EKEvent? {
            let predicate = otherStore.predicateForEvents(
                withStart: firstStart, end: firstStart.addingTimeInterval(60 * 60), calendars: nil)
            return otherStore.events(matching: predicate).first {
                $0.calendar.calendarIdentifier == calendar.calendarIdentifier
            }
        }
        let editedTitle = "mise test event edited externally"
        try await pollUntil(timeout: 5) {
            guard let external = externalFirst() else { return false }
            external.title = editedTitle
            try otherStore.save(external, span: .futureEvents, commit: true)
            return true
        }
        try await pollUntil(timeout: 5) { occurrences().first?.title == editedTitle }

        // .futureEvents from the first occurrence also takes the split-off
        // series with it, so nothing is left.
        let externalToRemove = try #require(externalFirst())
        try otherStore.remove(externalToRemove, span: .futureEvents, commit: true)
        try await pollUntil(timeout: 5) { occurrences().isEmpty }
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
