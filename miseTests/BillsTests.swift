import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct BillsTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
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

    func bill(due: Date, remindDays: Int = 3) -> Bill {
        let bill = Bill(name: "Netflix", amount: Decimal(string: "15.98")!, currency: "SGD", nextDue: due)
        bill.remindDays = remindDays
        return bill
    }

    func reminders(_ bills: [Bill], now: Date) -> [(id: String, date: Date, body: String)] {
        Bills.reminders(for: bills, now: now, calendar: calendar)
    }

    @Test func remindersBeforeAndDue() {
        let b = bill(due: date(2027, 5, 20, hour: 18))
        let result = reminders([b], now: date(2027, 5, 10, hour: 12))
        #expect(result.map(\.id) == ["bill|\(b.id.uuidString)|before", "bill|\(b.id.uuidString)|due"])
        #expect(result.map(\.date) == [date(2027, 5, 17), date(2027, 5, 20)])
        #expect(result[0].body.hasPrefix("Netflix: ") && result[0].body.hasSuffix(" due in 3 days"))
        #expect(result[1].body.hasSuffix(" due today"))
    }

    @Test func remindersSkipZeroInactivePastAndOverdue() {
        let now = date(2027, 5, 10, hour: 12)
        let zero = bill(due: date(2027, 5, 20), remindDays: 0)
        #expect(reminders([zero], now: now).map(\.id) == ["bill|\(zero.id.uuidString)|due"])
        let inactive = bill(due: date(2027, 5, 20))
        inactive.active = false
        #expect(reminders([inactive], now: now).isEmpty)
        let tomorrow = bill(due: date(2027, 5, 11))
        #expect(reminders([tomorrow], now: now).map(\.id) == ["bill|\(tomorrow.id.uuidString)|due"])
        #expect(reminders([bill(due: date(2027, 5, 9))], now: now).isEmpty)
    }

    @Test func markPaidRecordsTransactionAndAdvances() {
        let account = Account(name: "DBS", type: .debit, currency: "SGD")
        let category = mise.Category(name: "Subscriptions")
        context.insert(account)
        context.insert(category)
        let b = bill(due: date(2027, 1, 31))
        context.insert(b)
        b.account = account
        b.category = category
        b.anchorDay = 31
        let now = date(2027, 1, 30)
        let paid = Bills.markPaid(b, context: context, now: now, calendar: calendar)
        #expect(paid.amount == Decimal(string: "-15.98")!)
        #expect(paid.currency == "SGD")
        #expect(paid.merchant == "Netflix")
        #expect(paid.account === account)
        #expect(paid.category === category)
        #expect(paid.source == .manual)
        #expect(!paid.categoryIsAuto)
        #expect(paid.homeAmount == nil)
        #expect(paid.date == now)
        #expect(b.nextDue == date(2027, 2, 28))
        _ = Bills.markPaid(b, context: context, now: now, calendar: calendar)
        #expect(b.nextDue == date(2027, 3, 31))
        #expect(((try? context.fetch(FetchDescriptor<mise.Transaction>())) ?? []).count == 2)
    }

    @Test func cadenceLabelReadsNaturally() {
        #expect(Bills.cadenceLabel(.monthly, interval: 1) == "Monthly")
        #expect(Bills.cadenceLabel(.weekly, interval: 2) == "Every 2 weeks")
        #expect(Bills.cadenceLabel(.yearly, interval: 3) == "Every 3 years")
    }

    @Test func anchorDayMovesOnlyWithDateOrCadence() {
        func anchor(_ newDue: Date, _ old: BillCadence = .monthly, _ new: BillCadence = .monthly, oldDue: Date) -> Int {
            Bills.anchorDay(current: 31, oldDue: oldDue, newDue: newDue, oldCadence: old, newCadence: new, calendar: calendar)
        }
        #expect(anchor(date(2027, 2, 28, hour: 0), oldDue: date(2027, 2, 28, hour: 0)) == 31)
        #expect(anchor(date(2027, 3, 10), oldDue: date(2027, 2, 28, hour: 0)) == 10)
        #expect(anchor(date(2027, 2, 24), .weekly, .monthly, oldDue: date(2027, 2, 24, hour: 0)) == 24)
    }
}
