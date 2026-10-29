import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct MonthSummaryTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func fire(_ now: Date, minutes: Int = 20 * 60) -> [Int?] {
        let c = MonthSummary.fireDate(after: now, minutes: minutes, calendar: calendar)
        return [c.year, c.month, c.day, c.hour, c.minute]
    }

    @Test func fireDateIsLastDayOfMonth() {
        #expect(fire(day(2026, 10, 3)) == [2026, 10, 31, 20, 0])
        #expect(fire(day(2026, 4, 3)) == [2026, 4, 30, 20, 0])
        #expect(fire(day(2024, 2, 3)) == [2024, 2, 29, 20, 0])
        #expect(fire(day(2025, 2, 3)) == [2025, 2, 28, 20, 0])
        #expect(fire(day(2000, 2, 3)) == [2000, 2, 29, 20, 0])
        #expect(fire(day(2100, 2, 3)) == [2100, 2, 28, 20, 0])
        #expect(fire(day(2026, 10, 3), minutes: 7 * 60 + 45) == [2026, 10, 31, 7, 45])
    }

    @Test func fireDateRollsOverAfterTime() {
        #expect(fire(day(2026, 10, 31, hour: 19)) == [2026, 10, 31, 20, 0])
        #expect(fire(day(2026, 10, 31, hour: 21)) == [2026, 11, 30, 20, 0])
        #expect(fire(day(2026, 10, 31, hour: 20)) == [2026, 11, 30, 20, 0])
        #expect(fire(day(2026, 12, 31, hour: 21)) == [2027, 1, 31, 20, 0])
    }

    @Test func categoryLines() {
        let food = mise.Category(name: "Food", color: 1)
        food.budget = 100
        let travel = mise.Category(name: "Travel")
        travel.budget = 50
        let fun = mise.Category(name: "Fun")
        let idle = mise.Category(name: "Idle")
        let salary = mise.Category(name: "Salary")
        salary.isIncome = true
        let categories = [food, travel, fun, idle, salary]

        let spent: (byCategory: [UUID: Decimal], uncategorized: Decimal, unconverted: [String: Decimal]) =
            ([food.id: 100, fun.id: 300, salary.id: 9], 0, [:])
        let lines = MonthSummary.categoryLines(spent, categories: categories)
        #expect(lines.map(\.name) == ["Food", "Fun", "Travel"])
        #expect(lines.map(\.isOver) == [true, false, false])
        #expect(lines.first?.color == 1 && lines.first?.budget == 100)
        #expect(lines.last?.spent == 0)

        let withUncategorized = MonthSummary.categoryLines((spent.byCategory, 20, [:]), categories: categories)
        #expect(withUncategorized.map(\.name) == ["Food", "Fun", "Uncategorized", "Travel"])
        #expect(withUncategorized[2].id == nil && withUncategorized[2].color == 0x8E8E93)
    }

    func transaction(_ amount: Decimal, _ merchant: String, _ date: Date, currency: String = "SGD") -> mise.Transaction {
        let transaction = mise.Transaction(amount: amount, currency: currency, date: date)
        context.insert(transaction)
        transaction.merchant = merchant
        return transaction
    }

    @Test func topMerchants() {
        let october = calendar.dateInterval(of: .month, for: day(2026, 10, 5))!
        let usd = transaction(-10, "Grab", day(2026, 10, 3), currency: "USD")
        usd.homeAmount = -13
        // Name = latest in-month spelling, whatever the array order; September's spelling never shows.
        let all = [
            transaction(-99, "Starbucks #999", day(2026, 9, 30)),
            transaction(-4, "Starbucks #123", day(2026, 10, 2)),
            transaction(50, "Starbucks", day(2026, 10, 10)),
            transaction(-6, "STARBUCKS", day(2026, 10, 9)),
            usd,
            transaction(-2, "Kopi", day(2026, 10, 4)),
            transaction(-1, "", day(2026, 10, 4)),
        ]
        let top = MonthSummary.topMerchants(all, in: october, rates: FXRates(), home: "SGD")
        #expect(top.map(\.name) == ["Grab", "Starbucks", "Kopi"])
        #expect(top.map(\.amount) == [13, 10, 2])

        let limited = MonthSummary.topMerchants(all, in: october, rates: FXRates(), home: "SGD", limit: 2)
        #expect(limited.map(\.name) == ["Grab", "Starbucks"])
    }
}
