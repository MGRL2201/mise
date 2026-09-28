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
        draft.url = "https://example.com/rent"
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
        draft.apply(to: reminder, lists: [])

        #expect(reminder.priority == 3)
        #expect(reminder.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount == 5)
        #expect(reminder.alarms?.count == 2)
        #expect(reminder.alarms?.contains { $0.absoluteDate == nil && $0.relativeOffset == -600 } == true)
        #expect(reminder.alarms?.contains { $0.absoluteDate == dueDate() } == true)
    }

    @Test func dateOnlyDueAddsNoAlarm() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.dueDate = dueDate()
        draft.apply(to: reminder, lists: [])
        #expect(reminder.dueDateComponents?.hour == nil)
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func timedDueAddsOneDueAlarm() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.includesTime = true
        draft.dueDate = dueDate()
        draft.apply(to: reminder, lists: [])
        #expect(reminder.alarms?.count == 1)
        #expect(reminder.alarms?.first?.absoluteDate == nil && reminder.alarms?.first?.relativeOffset == 0)
    }

    @Test func movingTimedDueReplacesOldDueAlarmOnly() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2, hour: 9, minute: 30)
        let unrelated = dueDate().addingTimeInterval(-86400)
        reminder.alarms = [EKAlarm(absoluteDate: dueDate()), EKAlarm(absoluteDate: unrelated), EKAlarm(relativeOffset: -900)]

        var draft = TaskDraft(reminder)
        draft.location = LocationReminder(title: "Home", latitude: 1.3, longitude: 103.8, radius: 150, leaving: false)
        draft.apply(to: reminder, lists: [])
        draft = TaskDraft(reminder)
        draft.dueDate = dueDate().addingTimeInterval(3600)
        draft.apply(to: reminder, lists: [])

        let alarms = reminder.alarms ?? []
        #expect(alarms.count == 4)
        #expect(alarms.compactMap(\.absoluteDate) == [unrelated])
        #expect(alarms.filter { $0.absoluteDate == nil && $0.proximity == .none && $0.relativeOffset == 0 }.count == 1)
        #expect(TaskDraft(reminder).earlyReminder == 900)
        #expect(TaskDraft(reminder).location?.title == "Home")
    }

    @Test func timedToDateOnlyDropsDueAlarm() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.includesTime = true
        draft.dueDate = dueDate()
        draft.apply(to: reminder, lists: [])
        draft = TaskDraft(reminder)
        draft.includesTime = false
        draft.apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func clearingDueDropsDueAndEarlyAlarms() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.includesTime = true
        draft.dueDate = dueDate()
        draft.earlyReminder = 3600
        draft.apply(to: reminder, lists: [])
        #expect(reminder.alarms?.count == 2)

        draft = TaskDraft(reminder)
        draft.hasDueDate = false
        draft.apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func timedToDateOnlyDropsEarlyAlarm() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.includesTime = true
        draft.dueDate = dueDate()
        draft.earlyReminder = 3600
        draft.apply(to: reminder, lists: [])
        draft = TaskDraft(reminder)
        draft.includesTime = false
        draft.apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func earlyReminderNeedsTimedDue() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.dueDate = dueDate()
        draft.earlyReminder = 3600
        draft.apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func earlyReminderNeedsDueDate() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.earlyReminder = 3600
        draft.apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func endRepeatOnlyChangeKeepsCustomWeekdays() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2)
        reminder.recurrenceRules = [EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.wednesday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil
        )]
        let end = dueDate().addingTimeInterval(30 * 86400)
        var draft = TaskDraft(reminder)
        draft.repeatEnd = end
        draft.apply(to: reminder, lists: [])

        let rule = reminder.recurrenceRules?.first
        #expect(rule?.daysOfTheWeek?.map(\.dayOfTheWeek) == [.monday, .wednesday])
        #expect(rule?.recurrenceEnd?.endDate == end)
    }

    @Test func editingLeavingKeepsOriginalPlace() {
        let reminder = EKReminder(eventStore: EKEventStore())
        let alarm = EKAlarm()
        alarm.structuredLocation = EKStructuredLocation(title: "Somewhere")  // no geoLocation
        alarm.proximity = .enter
        reminder.alarms = [alarm]

        var draft = TaskDraft(reminder)
        draft.location?.leaving = true
        draft.location?.radius = 300
        draft.apply(to: reminder, lists: [])

        let place = reminder.alarms?.first?.structuredLocation
        #expect(reminder.alarms?.first?.proximity == .leave)
        #expect(place?.radius == 300)
        #expect(place?.geoLocation == nil)
        #expect(place?.title == "Somewhere")
    }

    @Test func earlyReminderRoundTrips() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.includesTime = true
        draft.dueDate = dueDate()
        draft.earlyReminder = 3600
        draft.apply(to: reminder, lists: [])
        #expect(reminder.alarms?.contains { $0.relativeOffset == -3600 } == true)
        #expect(TaskDraft(reminder).earlyReminder == 3600)

        draft = TaskDraft(reminder)
        draft.earlyReminder = nil
        draft.apply(to: reminder, lists: [])
        #expect(reminder.alarms?.contains { $0.relativeOffset < 0 } == false)
        #expect(reminder.alarms?.count == 1)  // due alarm stays
    }

    @Test func untouchedEarlyReminderAndLocationSurviveTitleEdit() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2)
        reminder.alarms = [EKAlarm(relativeOffset: -900)]  // date-only early alarm set elsewhere
        var draft = TaskDraft(reminder)
        draft.location = LocationReminder(title: "Home", latitude: 1.3, longitude: 103.8, radius: 150, leaving: false)
        draft.apply(to: reminder, lists: [])

        draft = TaskDraft(reminder)
        draft.title = "Renamed"
        draft.apply(to: reminder, lists: [])
        let reread = TaskDraft(reminder)
        #expect(reread.earlyReminder == 900)
        #expect(reread.location?.title == "Home")
        #expect(reminder.alarms?.count == 2)
    }

    @Test func endRepeatRoundTrips() {
        let reminder = EKReminder(eventStore: EKEventStore())
        let end = dueDate().addingTimeInterval(30 * 86400)
        var draft = TaskDraft(reminder)
        draft.hasDueDate = true
        draft.dueDate = dueDate()
        draft.recurrence = .weekly
        draft.repeatEnd = end
        draft.apply(to: reminder, lists: [])

        #expect(reminder.recurrenceRules?.first?.recurrenceEnd?.endDate == end)
        let reread = TaskDraft(reminder)
        #expect(reread.recurrence == .weekly)
        #expect(reread.repeatEnd == end)

        draft = reread
        draft.repeatEnd = nil
        draft.apply(to: reminder, lists: [])
        #expect(reminder.recurrenceRules?.first?.recurrenceEnd == nil)
        #expect(TaskDraft(reminder).recurrence == .weekly)
    }

    @Test func countEndedRuleStaysCustomAndSurvives() {
        let reminder = EKReminder(eventStore: EKEventStore())
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 2)
        reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
        var draft = TaskDraft(reminder)
        #expect(draft.recurrence == .custom && draft.repeatEnd == nil)
        draft.notes = "edited"
        draft.apply(to: reminder, lists: [])
        #expect(reminder.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount == 3)
    }

    @Test func locationReminderRoundTrips() {
        let reminder = EKReminder(eventStore: EKEventStore())
        var draft = TaskDraft(reminder)
        let office = LocationReminder(title: "Office", latitude: 1.28, longitude: 103.85, radius: 200, leaving: true)
        draft.location = office
        draft.apply(to: reminder, lists: [])

        let alarm = reminder.alarms?.first
        #expect(alarm?.proximity == .leave)
        #expect(alarm?.structuredLocation?.radius == 200)
        #expect(alarm?.structuredLocation?.title == "Office")
        #expect(TaskDraft(reminder).location == office)

        draft = TaskDraft(reminder)
        draft.location = nil
        draft.apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
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
