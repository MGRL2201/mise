import Testing
import SwiftData
import Foundation
import EventKit
@testable import mise

@MainActor
struct TimeBlockTests {
    @Test func titleAddsAndStripsDoneMarkOnce() {
        #expect(TimeBlock.title("Write", done: true) == "✓ Write")
        #expect(TimeBlock.title("✓ Write", done: true) == "✓ Write")
        #expect(TimeBlock.title("✓ Write", done: false) == "Write")
        #expect(TimeBlock.title("Write", done: false) == "Write")
    }

    @Test(.enabled(if: EKEventStore.authorizationStatus(for: .event) == .fullAccess
                   && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess))
    func timeBlockLinksCompletesAndDeletesThroughEventKit() throws {
        let container = try ModelContainer(for: Schema(Storage.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let eventStore = EKEventStore()
        let reminders = RemindersStore(eventStore: eventStore, context: container.mainContext)
        let calendars = CalendarStore(eventStore: eventStore)

        let source = try #require(
            eventStore.defaultCalendarForNewEvents?.source ?? eventStore.sources.first { $0.sourceType == .local }
        )
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "mise-test-\(UUID().uuidString)"
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        defer { try? eventStore.removeCalendar(calendar, commit: true) }

        let list = try reminders.newList(title: "mise-test-\(UUID().uuidString)")
        defer { try? reminders.deleteList(list) }
        let reminder = reminders.newReminder(in: list)
        reminder.title = "mise time block test"
        try reminders.save(reminder)
        defer { try? reminders.delete(reminder) }

        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0,
                                          of: Date().addingTimeInterval(7 * 86400))!
        try createTimeBlock(for: reminder, start: start, duration: 45 * 60, calendar: calendar,
                            calendarStore: calendars, context: container.mainContext)

        let linked = try #require(reminders.linkedEvent(for: reminder))
        #expect(linked.startDate == start)
        #expect(linked.endDate == start.addingTimeInterval(45 * 60))
        #expect(linked.title == "mise time block test")
        #expect(linked.calendar.calendarIdentifier == calendar.calendarIdentifier)

        try reminders.setCompleted(reminder, true)
        #expect(reminders.linkedEvent(for: reminder)?.title == "✓ mise time block test")
        try reminders.setCompleted(reminder, false)
        #expect(reminders.linkedEvent(for: reminder)?.title == "mise time block test")

        // Re-blocking moves the linked event instead of orphaning it.
        let moved = start.addingTimeInterval(86400)
        try createTimeBlock(for: reminder, start: moved, duration: 30 * 60, calendar: calendar,
                            calendarStore: calendars, context: container.mainContext)
        let window = eventStore.predicateForEvents(withStart: start.addingTimeInterval(-86400),
                                                   end: moved.addingTimeInterval(86400), calendars: [calendar])
        let inCalendar = eventStore.events(matching: window)
        #expect(inCalendar.count == 1)
        #expect(inCalendar.first?.startDate == moved)
        #expect(inCalendar.first?.endDate == moved.addingTimeInterval(30 * 60))
        #expect(reminders.linkedEvent(for: reminder)?.startDate == moved)

        let firstID = try #require(reminders.linkedEvent(for: reminder)?.eventIdentifier)
        try reminders.removeTimeBlock(for: reminder)
        #expect(eventStore.event(withIdentifier: firstID) == nil)
        #expect(reminders.linkedEvent(for: reminder) == nil)

        let relinked = try createTimeBlock(for: reminder, start: start, duration: 45 * 60, calendar: calendar,
                                           calendarStore: calendars, context: container.mainContext)
        let eventID = try #require(relinked.eventIdentifier)
        try reminders.delete(reminder, deletingEvent: true)
        #expect(eventStore.event(withIdentifier: eventID) == nil)
    }
}
