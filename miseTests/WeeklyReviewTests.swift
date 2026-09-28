import Testing
import Foundation
import EventKit
import UserNotifications
@testable import mise

@MainActor
struct WeeklyReviewTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }
    private func span(_ day: Int, _ start: Int, _ end: Int) -> DateInterval {
        DateInterval(start: at(day, start), end: at(day, end))
    }

    @Test func hoursByCalendarMergesOverlapClipsAndSplitsCalendars() {
        let window = DateInterval(start: at(3, 10), end: at(10, 10))
        let hours = WeeklyReview.hoursByCalendar([
            ("work", span(4, 9, 11)), ("work", span(4, 10, 12)),  // overlap: 9-12 = 3h
            ("work", span(5, 9, 10)), ("work", span(5, 10, 11)),  // touching: 2h
            ("home", span(4, 10, 11)),                             // other calendar: 1h
            ("home", span(3, 8, 12)),                              // clipped to 10-12: 2h
            ("home", span(1, 8, 9)),                               // outside window: 0
        ], within: window)
        #expect(hours == ["work": 5 * 3600, "home": 3 * 3600])
    }

    @Test func componentsTriggerOnWeekdayAndTime() {
        let components = WeeklyReview.components(weekday: 4, minutes: 18 * 60 + 30)
        #expect(components == DateComponents(hour: 18, minute: 30, weekday: 4))
        let next = UNCalendarNotificationTrigger(dateMatching: components, repeats: true).nextTriggerDate()
        let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: next!)
        #expect(parts.weekday == 4 && parts.hour == 18 && parts.minute == 30)
    }

    @Test func weekTasksKeepUpcomingButNotBeyondSevenDays() {
        let store = EKEventStore()
        func reminder(_ title: String, due: Date? = nil) -> EKReminder {
            let r = EKReminder(eventStore: store)
            r.title = title
            r.dueDateComponents = due.map { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
            return r
        }
        let now = at(10, 12)
        let all = [reminder("in 3 days", due: at(13, 9)), reminder("in 10 days", due: at(20, 9)),
                   reminder("today", due: at(10, 17)), reminder("undated"), reminder("linked", due: at(12, 9))]
        let kept = DailyPlanning.tasks(all, week: true, now: now, calendar: calendar) { $0.title == "linked" }
        #expect(kept.map(\.title) == ["today", "in 3 days"])
        #expect(DailyPlanning.tasks(all, now: now, calendar: calendar) { $0.title == "linked" }.map(\.title) == ["today"])
    }
}
