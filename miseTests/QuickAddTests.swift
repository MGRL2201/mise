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
        ("read #unknown tag", QuickAdd(title: "read tag", unknownList: "unknown")),
        ("buy milk #Grocries,", QuickAdd(title: "buy milk", unknownList: "Grocries")),
        ("fix issue #1", QuickAdd(title: "fix issue #1")),
        ("#homestuff", QuickAdd(title: "", listName: "Home Stuff")),
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

    @Test func closeMatchFindsTyposPrefixesAndCase() {
        let lists = ["Inbox", "Home Stuff", "Bills", "Groceries"]
        let cases: [(String, String?)] = [
            ("grocries", "Groceries"), ("groc", "Groceries"), ("HOMESTUFF", "Home Stuff"), ("bils", "Bills"),
            ("xyz", nil), ("gr", nil), ("work", nil),
        ]
        for (name, expected) in cases {
            #expect(QuickAdd.closeMatch(name, in: lists) == expected, "\(name)")
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
        #expect(reminder.alarms?.count == 1 && reminder.alarms?.first?.relativeOffset == 0)
        #expect(reminder.alarms?.first?.absoluteDate == nil)
    }

    @Test func dateOnlyQuickAddGetsNoAlarm() {
        let reminder = EKReminder(eventStore: EKEventStore())
        QuickAdd(title: "pay card", due: Self.day(9, 27)).apply(to: reminder, lists: [])
        #expect((reminder.alarms ?? []).isEmpty)
    }

    @Test func mergingKeepsDeterministicFields() {
        let today = Self.day(9, 27)
        let marked = QuickAdd(title: "pay rent", priority: 1)
            .merging(QuickTaskFields(title: " NIL ", priority: .low, recurrence: .monthly), text: "pay rent every month !high", today: today)
        #expect(marked == QuickAdd(title: "pay rent", due: today, recurrence: .monthly, priority: 1))

        let parsed = QuickAdd(title: "gym", due: Self.day(10, 1, 7), recurrence: .weekly)
            .merging(QuickTaskFields(title: "Gym", priority: .high, recurrence: .daily), text: "urgent gym every wed 7am", today: today)
        #expect(parsed == QuickAdd(title: "Gym", due: Self.day(10, 1, 7), recurrence: .weekly, priority: 1))
    }

    @Test func mergingIgnoresUncuedModelFields() {
        let today = Self.day(9, 27)
        let fields = QuickTaskFields(title: "", priority: .high, recurrence: .daily)
        #expect(QuickAdd(title: "buy milk").merging(fields, text: "buy milk #nosuchlist", today: today)
            == QuickAdd(title: "buy milk"))
        #expect(QuickAdd(title: "call mom").merging(fields, text: "urgent: call mom each morning", today: today)
            == QuickAdd(title: "call mom", due: today, recurrence: .daily, priority: 1))
        #expect(QuickAdd(title: "read everything").merging(fields, text: "read everything", today: today).recurrence == .none)
    }

    // Simulator can report available yet throw on every call; parseSmart must fall back either way.
    @Test
    func parseSmartKeepsDeterministicFields() async {
        let input = "pay rent every 1st 9am !high"
        let smart = await QuickAdd.parseSmart(input, lists: [], now: Self.now)
        let plain = QuickAdd.parse(input, lists: [], now: Self.now)
        #expect(smart.due == plain.due)
        #expect(smart.recurrence == plain.recurrence)
        #expect(smart.priority == plain.priority)
        #expect(!smart.title.isEmpty)
    }
}
