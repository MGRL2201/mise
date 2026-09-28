import Testing
import Foundation
import EventKit
import UserNotifications
@testable import mise

@MainActor
struct PlanningTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    @Test func componentsSplitMinutesIntoHourAndMinute() {
        #expect(DailyPlanning.components(minutes: 480) == DateComponents(hour: 8, minute: 0))
        #expect(DailyPlanning.components(minutes: 21 * 60 + 45) == DateComponents(hour: 21, minute: 45))
        let next = UNCalendarNotificationTrigger(dateMatching: DailyPlanning.components(minutes: 21 * 60 + 45), repeats: true)
            .nextTriggerDate()
        let parts = Calendar.current.dateComponents([.hour, .minute], from: next!)
        #expect(parts.hour == 21 && parts.minute == 45)
    }

    @Test func tasksKeepsOverdueThenTodayOnly() {
        let store = EKEventStore()
        func reminder(_ title: String, due: Date? = nil, done: Bool = false) -> EKReminder {
            let r = EKReminder(eventStore: store)
            r.title = title
            r.dueDateComponents = due.map { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
            r.isCompleted = done
            return r
        }
        let now = at(10, 12)
        let all = [reminder("today", due: at(10, 17)), reminder("tomorrow", due: at(11, 9)), reminder("undated"),
                   reminder("overdue", due: at(9, 9)), reminder("done", due: at(10, 15), done: true),
                   reminder("linked", due: at(10, 16))]
        let kept = DailyPlanning.tasks(all, now: now, calendar: calendar) { $0.title == "linked" }
        #expect(kept.map(\.title) == ["overdue", "today"])
    }

    @Test func tasksPutsOverdueTimedTaskBeforeDateOnlyTaskDueToday() {
        let store = EKEventStore()
        func reminder(_ title: String, due: DateComponents) -> EKReminder {
            let r = EKReminder(eventStore: store)
            r.title = title
            r.dueDateComponents = due
            return r
        }
        let now = at(10, 12)
        let dateOnly = reminder("date-only", due: calendar.dateComponents([.year, .month, .day], from: at(10, 0)))
        let timed = reminder("timed-9am", due: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: at(10, 9)))
        // Fed in the "wrong" order (date-only first) to prove the sort, not the input order, decides.
        let kept = DailyPlanning.tasks([dateOnly, timed], now: now, calendar: calendar) { _ in false }
        #expect(kept.map(\.title) == ["timed-9am", "date-only"])
    }
}
