import Testing
import Foundation
import EventKit
@testable import mise

@MainActor
struct TaskEditorTests {
    @Test func presetsRoundTripThroughRules() {
        for preset in RecurrencePreset.allCases where preset != .custom {
            #expect(RecurrencePreset(preset.rule) == preset)
        }
        #expect(RecurrencePreset(nil) == RecurrencePreset.none)
    }

    @Test func unusualRulesMapToCustom() {
        let ended = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5))
        let everyThreeMonths = EKRecurrenceRule(recurrenceWith: .monthly, interval: 3, end: nil)
        let monWed = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.wednesday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil
        )
        #expect(RecurrencePreset(ended) == .custom)
        #expect(RecurrencePreset(everyThreeMonths) == .custom)
        #expect(RecurrencePreset(monWed) == .custom)
    }

    private func dueDate() -> Date {
        Calendar.current.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 9, minute: 30))!
    }

    @Test func draftRoundTripsThroughReminder() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.title = "Pay rent"
        draft.notes = "by transfer"
        draft.hasDueDate = true
        draft.includesTime = true
        draft.dueDate = dueDate()
        draft.priorityBucket = .high
        draft.recurrence = .weekdays
        draft.alarms = [dueDate().addingTimeInterval(-3600)]
        draft.apply(to: reminder, lists: [])

        #expect(reminder.dueDateComponents?.hour == 9)
        #expect(reminder.priority == 1)
        #expect(TaskDraft(reminder) == draft)
    }

    @Test func customRecurrenceRoundTrips() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.dueDate = dueDate()
        draft.recurrence = .custom
        draft.customFrequency = .monthly
        draft.customInterval = 3
        draft.apply(to: reminder, lists: [])

        let reread = TaskDraft(reminder)
        #expect(reread.recurrence == .custom)
        #expect(reread.customFrequency == .monthly)
        #expect(reread.customInterval == 3)
    }

    @Test func clearingDueDateClearsRecurrence() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2)
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        var draft = TaskDraft(reminder)
        #expect(draft.hasDueDate && !draft.includesTime && draft.recurrence == .daily)
        draft.hasDueDate = false
        draft.apply(to: reminder, lists: [])
        #expect(reminder.dueDateComponents == nil)
        #expect((reminder.recurrenceRules ?? []).isEmpty)
    }

    @Test func untouchedFieldsSurviveApply() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.priority = 3
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2)
        let complex = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 5))
        reminder.recurrenceRules = [complex]
        reminder.alarms = [EKAlarm(relativeOffset: -600), EKAlarm(absoluteDate: dueDate())]

        var draft = TaskDraft(reminder)
        draft.priorityBucket = .high  // same bucket as 3: raw value kept
        draft.alarms = []
        draft.apply(to: reminder, lists: [])

        #expect(reminder.priority == 3)
        #expect(reminder.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount == 5)
        #expect(reminder.alarms?.count == 1)
        #expect(reminder.alarms?.first?.relativeOffset == -600)
    }

    @Test func unchangedDueKeepsTimeZone() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.title = "Call"
        let tokyo = TimeZone(identifier: "Asia/Tokyo")
        reminder.dueDateComponents = DateComponents(timeZone: tokyo, year: 2030, month: 1, day: 2, hour: 9, minute: 30)

        var draft = TaskDraft(reminder)
        draft.title = "Call mom"
        draft.apply(to: reminder, lists: [])

        #expect(reminder.dueDateComponents?.timeZone == tokyo)
        // EventKit keeps the old timeZone on rewrite but adds second/era; untouched components have none.
        #expect(reminder.dueDateComponents?.second == nil)
        #expect(reminder.dueDateComponents?.hour == 9)
    }
}
