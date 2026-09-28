import Testing
import Foundation
@testable import mise

@MainActor
struct MonthGridTests {
    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.firstWeekday = firstWeekday
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func septemberSundayStart() {
        // 2026-09-01 is a Tuesday, 09-30 a Wednesday.
        let cal = calendar(firstWeekday: 1)
        let days = MonthGrid.days(in: date(2026, 9, 15, hour: 13, in: cal), calendar: cal)
        #expect(days.first == date(2026, 8, 30, in: cal))
        #expect(days.last == date(2026, 10, 3, in: cal))
        #expect(days.count == 35)
    }

    @Test func septemberMondayStart() {
        let cal = calendar(firstWeekday: 2)
        let days = MonthGrid.days(in: date(2026, 9, 1, in: cal), calendar: cal)
        #expect(days.first == date(2026, 8, 31, in: cal))
        #expect(days.last == date(2026, 10, 4, in: cal))
        #expect(days.count == 35)
    }

    @Test func februaryIsExactlyFourWeeksWithSundayStart() {
        // 2026-02-01 is a Sunday; 28 days.
        let cal = calendar(firstWeekday: 1)
        let days = MonthGrid.days(in: date(2026, 2, 10, in: cal), calendar: cal)
        #expect(days.count == 28)
        #expect(days.first == date(2026, 2, 1, in: cal))
        #expect(days.last == date(2026, 2, 28, in: cal))
    }

    @Test func februaryMondayStartAddsLeadingWeek() {
        let cal = calendar(firstWeekday: 2)
        let days = MonthGrid.days(in: date(2026, 2, 10, in: cal), calendar: cal)
        #expect(days.first == date(2026, 1, 26, in: cal))
        #expect(days.last == date(2026, 3, 1, in: cal))
        #expect(days.count == 35)
    }

    @Test(arguments: [1, 2]) func everyMonthIsWholeWeeksOfMidnights(firstWeekday: Int) {
        let cal = calendar(firstWeekday: firstWeekday)
        for month in 1...12 {
            let first = date(2026, month, 1, in: cal)
            let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: first)!
            let days = MonthGrid.days(in: first, calendar: cal)
            #expect(days.count % 7 == 0 && (28...42).contains(days.count))
            #expect(days.allSatisfy { $0 == cal.startOfDay(for: $0) })
            #expect(days.first! <= first && days.last! >= last)
            #expect(cal.component(.weekday, from: days.first!) == firstWeekday)
            // Consecutive calendar days, no gaps or repeats (DST month included: March).
            for (a, b) in zip(days, days.dropFirst()) {
                #expect(cal.date(byAdding: .day, value: 1, to: a) == b)
            }
        }
    }

    @Test func midnightDSTSwitchStillYieldsStartsOfDay() {
        // Santiago springs forward at midnight: 2026-09-06 starts at 01:00.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Santiago")!
        cal.firstWeekday = 1
        let days = MonthGrid.days(in: date(2026, 9, 15, hour: 12, in: cal), calendar: cal)
        #expect(days.allSatisfy { $0 == cal.startOfDay(for: $0) })
        #expect(days.count == 35 && Set(days).count == 35)
    }

    @Test func pagingCrossesYearBoundary() {
        let cal = calendar(firstWeekday: 1)
        #expect(MonthGrid.month(date(2026, 12, 20, hour: 9, in: cal), by: 1, calendar: cal) == date(2027, 1, 1, in: cal))
        #expect(MonthGrid.month(date(2026, 1, 31, in: cal), by: -1, calendar: cal) == date(2025, 12, 1, in: cal))
        #expect(MonthGrid.month(date(2026, 3, 31, in: cal), by: 0, calendar: cal) == date(2026, 3, 1, in: cal))
    }
}
