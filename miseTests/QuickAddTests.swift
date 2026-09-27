import Testing
import Foundation
import EventKit
@testable import mise

@MainActor
struct QuickAddTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }()
    // Sunday 2026-09-27 10:00
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10))!
    static let lists = ["Inbox", "Home Stuff", "Bills"]

    static func day(_ month: Int, _ day: Int, _ hour: Int? = nil, _ minute: Int? = nil) -> DateComponents {
        DateComponents(year: 2026, month: month, day: day, hour: hour, minute: hour == nil ? nil : minute ?? 0)
    }

    static let fixtures: [(String, QuickAdd)] = [
        ("pay rent every 1st 9am !high", QuickAdd(title: "pay rent", due: day(10, 1, 9), recurrence: .monthly, priority: 1)),
        ("call mom tomorrow 6pm", QuickAdd(title: "call mom", due: day(9, 28, 18))),
        ("dentist next tuesday 3:30pm", QuickAdd(title: "dentist", due: day(9, 29, 15, 30))),
        ("water plants every day", QuickAdd(title: "water plants", due: day(9, 27), recurrence: .daily)),
        ("gym every monday 7am", QuickAdd(title: "gym", due: day(9, 28, 7), recurrence: .weekly)),
        ("buy milk #homestuff !low", QuickAdd(title: "buy milk", priority: 9, listName: "Home Stuff")),
        ("read #unknown tag", QuickAdd(title: "read #unknown tag")),
        ("standup 9am", QuickAdd(title: "standup", due: day(9, 28, 9))),
        ("pay taxes in 2 weeks", QuickAdd(title: "pay taxes", due: day(10, 11))),
        ("plain title", QuickAdd(title: "plain title")),
        ("!!!", QuickAdd(title: "!!!", priority: 1)),
        ("review on Sun at noon !!", QuickAdd(title: "review", due: day(9, 27, 12), priority: 5)),
        ("movie tonight", QuickAdd(title: "movie", due: day(9, 27, 20))),
        ("report every other week 18:00 #bills", QuickAdd(title: "report", due: day(9, 27, 18), recurrence: .biweekly, listName: "Bills")),
        ("pay card every 27th", QuickAdd(title: "pay card", due: day(9, 27), recurrence: .monthly)),
        ("pay card every 27th 9am", QuickAdd(title: "pay card", due: day(10, 27, 9), recurrence: .monthly)),
        ("bill every 31st", QuickAdd(title: "bill", due: day(10, 31), recurrence: .monthly)),
        ("party 5 October 2026 7pm", QuickAdd(title: "party", due: day(10, 5, 19))),
        ("x in 2000000000000000000 weeks", QuickAdd(title: "x in 2000000000000000000 weeks")),
        ("gym sun 7am", QuickAdd(title: "gym", due: day(10, 4, 7))),
        ("gym every sunday 7am", QuickAdd(title: "gym", due: day(10, 4, 7), recurrence: .weekly)),
        ("call mom tomorrow,", QuickAdd(title: "call mom", due: day(9, 28))),
        ("stretch every weekday", QuickAdd(title: "stretch", due: day(9, 28), recurrence: .weekdays)),
    ]

    @Test func parsesFixtures() {
        for (input, expected) in Self.fixtures {
            let parsed = QuickAdd.parse(input, lists: Self.lists, now: Self.now, calendar: Self.calendar)
            #expect(parsed == expected, "\(input)")
        }
    }

    @Test func applyWritesFieldsOntoReminder() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        let bills = EKCalendar(for: .reminder, eventStore: store)
        bills.title = "Bills"
        let quick = QuickAdd(title: "pay rent", due: Self.day(10, 1, 9), recurrence: .monthly, priority: 1, listName: "Bills")
        quick.apply(to: reminder, lists: [bills])
        #expect(reminder.title == "pay rent")
        #expect(reminder.priority == 1)
        let due = reminder.dueDateComponents  // EventKit adds calendar/timeZone on readback
        #expect([due?.year, due?.month, due?.day, due?.hour, due?.minute] == [2026, 10, 1, 9, 0])
        #expect(RecurrencePreset(reminder.recurrenceRules?.first) == .monthly)
        #expect(reminder.calendar?.title == "Bills")
    }
}
