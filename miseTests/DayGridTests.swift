import Testing
import Foundation
import EventKit
@testable import mise

@MainActor
struct DayGridTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    let store = EKEventStore()

    private func date(_ day: Int, month: Int = 3, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func visibleDaysClampsCount() {
        #expect(DayGrid.visibleDays(from: date(2), count: 0, calendar: calendar) == [date(2)])
        #expect(DayGrid.visibleDays(from: date(2), count: 9, calendar: calendar).count == 7)
    }

    @Test func visibleDaysAreMidnightsAcrossDST() {
        // DST starts 2026-03-08 in New York: that day is 23h long.
        let days = DayGrid.visibleDays(from: date(6, hour: 15), count: 5, calendar: calendar)
        #expect(days == (6...10).map { date($0) })
    }

    @Test func pageMovesByCountDays() {
        #expect(DayGrid.page(date(6), by: 1, count: 3, calendar: calendar) == date(9))
        #expect(DayGrid.page(date(6), by: -1, count: 7, calendar: calendar) == date(27, month: 2))
        #expect(DayGrid.page(date(6), by: 1, count: 1, calendar: calendar) == date(7))
    }

    @Test func pinchThresholdsAndClamps() {
        #expect(DayGrid.count(afterPinch: 1.5, from: 3) == 2)
        #expect(DayGrid.count(afterPinch: 0.6, from: 3) == 4)
        #expect(DayGrid.count(afterPinch: 1.1, from: 3) == 3)
        #expect(DayGrid.count(afterPinch: 0.9, from: 3) == 3)
        #expect(DayGrid.count(afterPinch: 1.5, from: 1) == 1)
        #expect(DayGrid.count(afterPinch: 0.6, from: 7) == 7)
    }

    @Test func allDaySpanClipsToVisibleDays() {
        let days = DayGrid.visibleDays(from: date(6), count: 3, calendar: calendar)  // 6, 7, 8
        // Unflagged midnight-to-midnight spans: isAllDay would re-normalize dates into the device time zone.
        func allDay(_ from: Int, _ to: Int) -> EKEvent {
            let e = EKEvent(eventStore: store)
            e.startDate = date(from); e.endDate = date(to)
            return e
        }
        #expect(DayGrid.allDaySpan(allDay(4, 7), days: days, calendar: calendar) == 0...0)   // clipped left
        #expect(DayGrid.allDaySpan(allDay(7, 12), days: days, calendar: calendar) == 1...2)  // clipped right
        #expect(DayGrid.allDaySpan(allDay(1, 20), days: days, calendar: calendar) == 0...2)
        #expect(DayGrid.allDaySpan(allDay(10, 11), days: days, calendar: calendar) == nil)
        let timed = EKEvent(eventStore: store)
        timed.startDate = date(7, hour: 9); timed.endDate = date(7, hour: 10)
        #expect(DayGrid.allDaySpan(timed, days: days, calendar: calendar) == nil)
    }
}
