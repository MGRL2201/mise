import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct ReportsTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))!
    }

    func record(_ now: Date) {
        Reports.recordNetWorth(context: context, rates: FXRates(), home: "SGD", now: now, calendar: calendar)
    }

    func snapshots() throws -> [NetWorthSnapshot] {
        try context.fetch(FetchDescriptor<NetWorthSnapshot>(sortBy: [SortDescriptor(\.date)]))
    }

    @Test func oneSnapshotPerDayLatestWins() throws {
        let account = Account(name: "Cash", type: .cash, currency: "SGD", openingBalance: 100)
        context.insert(account)

        record(date(1, hour: 9))
        var all = try snapshots()
        #expect(all.count == 1)
        #expect(all.first?.total == 100 && all.first?.currency == "SGD")

        account.openingBalance = 150
        record(date(1, hour: 18))
        all = try snapshots()
        #expect(all.count == 1)
        #expect(all.first?.total == 150 && all.first?.date == date(1, hour: 18))

        record(date(2, hour: 9))
        all = try snapshots()
        #expect(all.map(\.total) == [150, 150])
    }

    @Test func netWorthIncludesPricedHoldings() throws {
        let broker = Account(name: "IBKR", type: .brokerage, currency: "SGD", openingBalance: 1000)
        let holding = Holding(symbol: "VT", name: "Vanguard Total World", kind: .stock, quantity: 3, costBasis: 250, currency: "SGD")
        holding.price = 100
        context.insert(broker)
        context.insert(holding)
        holding.account = broker

        record(date(1, hour: 9))
        #expect(try snapshots().first?.total == 1300)
    }

    @Test func noAccountsNoSnapshot() throws {
        record(date(1, hour: 9))
        #expect(try snapshots().isEmpty)
    }

    func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func transaction(_ amount: Decimal, _ date: Date, currency: String = "SGD") -> mise.Transaction {
        mise.Transaction(amount: amount, currency: currency, date: date)
    }

    @Test func monthlyBucketsIncomeAndSpend() {
        let transactions = [
            transaction(-10, day(2026, 1, 5)),
            transaction(100, day(2026, 1, 20)),
            transaction(-5, day(2026, 3, 2)),
            transaction(-7, day(2026, 3, 14)),
            transaction(-99, day(2025, 12, 31)),
            transaction(-99, day(2026, 4, 1)),
        ]
        let result = Reports.monthly(transactions, months: 3, now: day(2026, 3, 15), rates: FXRates(), home: "SGD", calendar: calendar)
        #expect(result.series.map(\.month) == [day(2026, 1, 1, hour: 0), day(2026, 2, 1, hour: 0), day(2026, 3, 1, hour: 0)])
        #expect(result.series.map(\.spend) == [10, 0, 12])
        #expect(result.series.map(\.income) == [100, 0, 0])
        #expect(result.unconverted.isEmpty)

        let usd = Reports.monthly(transactions + [transaction(-3, day(2026, 2, 10), currency: "USD")], months: 3,
                                  now: day(2026, 3, 15), rates: FXRates(), home: "SGD", calendar: calendar)
        #expect(usd.unconverted == ["USD"])
        #expect(usd.series.map(\.spend) == [10, 0, 12])
    }

    @Test func monthlyBoundaryBelongsToNewMonth() {
        let result = Reports.monthly([transaction(-4, day(2026, 2, 1, hour: 0))], months: 2, now: day(2026, 2, 15),
                                     rates: FXRates(), home: "SGD", calendar: calendar)
        #expect(result.series.map(\.spend) == [0, 4])
    }

    @Test func categoryTotalsSortedWithUncategorized() {
        let a = mise.Category(name: "A", color: 1)
        let b = mise.Category(name: "B", color: 2)
        let zero = mise.Category(name: "Zero")
        let income = mise.Category(name: "Income")
        income.isIncome = true
        let categories = [a, b, zero, income]
        let byCategory: [UUID: Decimal] = [a.id: 30, b.id: 50, zero.id: 0, income.id: 20, UUID(): 70]

        let totals = Reports.categoryTotals((byCategory, 40, [:]), categories: categories)
        #expect(totals.map(\.name) == ["B", "Uncategorized", "A"])
        #expect(totals.map(\.amount) == [50, 40, 30])
        #expect(totals[1].id == nil && totals[1].color == 0x8E8E93)
        #expect(totals[0].id == b.id && totals[0].color == 2)

        #expect(Reports.categoryTotals((byCategory, 0, [:]), categories: categories).map(\.name) == ["B", "A"])
    }

    @Test func historyFiltersByRangeAndHomeCurrency() {
        let now = day(2026, 6, 15)
        let ago = { (days: Int) in self.calendar.date(byAdding: .day, value: -days, to: now)! }
        let snapshots = [
            NetWorthSnapshot(date: ago(200), total: 1, currency: "SGD"),
            NetWorthSnapshot(date: ago(10), total: 3, currency: "SGD"),
            NetWorthSnapshot(date: ago(5), total: 9, currency: "USD"),
            NetWorthSnapshot(date: ago(40), total: 2, currency: "SGD"),
        ]
        func history(_ range: Reports.NetWorthRange) -> [Decimal] {
            Reports.history(snapshots, range: range, home: "SGD", now: now, calendar: calendar).map(\.total)
        }
        #expect(history(.month) == [3])
        #expect(history(.quarter) == [2, 3])
        #expect(history(.year) == [1, 2, 3])
        #expect(history(.all) == [1, 2, 3])
    }
}
