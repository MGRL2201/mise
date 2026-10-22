import Testing
import Foundation
@testable import mise

@MainActor
struct BillsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func advance(_ due: Date, _ cadence: BillCadence, interval: Int = 1, anchor: Int) -> Date {
        Bills.advance(due, cadence: cadence, interval: interval, anchorDay: anchor, calendar: calendar)
    }

    @Test func monthlyClampsToMonthEndAndReturnsToAnchor() {
        let feb = advance(date(2027, 1, 31), .monthly, anchor: 31)
        #expect(feb == date(2027, 2, 28))
        #expect(advance(feb, .monthly, anchor: 31) == date(2027, 3, 31))
        #expect(advance(date(2028, 1, 31), .monthly, anchor: 31) == date(2028, 2, 29))
    }

    @Test func monthlyInterval() {
        #expect(advance(date(2027, 1, 15), .monthly, interval: 3, anchor: 15) == date(2027, 4, 15))
        #expect(advance(date(2027, 1, 15), .monthly, interval: 0, anchor: 15) == date(2027, 2, 15))
    }

    @Test func weeklyInterval() {
        #expect(advance(date(2027, 1, 15), .weekly, interval: 2, anchor: 15) == date(2027, 1, 29))
    }

    @Test func yearlyLeapDay() {
        let y2029 = advance(date(2028, 2, 29), .yearly, anchor: 29)
        #expect(y2029 == date(2029, 2, 28))
        let y2030 = advance(y2029, .yearly, anchor: 29)
        #expect(y2030 == date(2030, 2, 28))
        #expect(advance(date(2031, 2, 28), .yearly, anchor: 29) == date(2032, 2, 29))
    }

    @Test func monthlyAmount() {
        #expect(Bills.monthlyAmount(12, cadence: .weekly, interval: 1) == 52)
        #expect(Bills.monthlyAmount(30, cadence: .monthly, interval: 3) == 10)
        #expect(Bills.monthlyAmount(120, cadence: .yearly, interval: 1) == 10)
        // Unrounded so several bills sum without drift: 3 x 3.33 would show 9.99.
        var sum = Bills.monthlyAmount(10, cadence: .monthly, interval: 3) * 3
        var shown = Decimal()
        NSDecimalRound(&shown, &sum, 2, .plain)
        #expect(shown == 10)
    }

    @Test func isOverdue() {
        let now = date(2027, 5, 10, hour: 12)
        #expect(Bills.isOverdue(date(2027, 5, 9, hour: 23), now: now, calendar: calendar))
        #expect(!Bills.isOverdue(date(2027, 5, 10, hour: 1), now: now, calendar: calendar))
        #expect(!Bills.isOverdue(date(2027, 5, 11, hour: 1), now: now, calendar: calendar))
    }
}
