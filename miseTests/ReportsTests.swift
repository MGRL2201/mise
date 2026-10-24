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

    @Test func noAccountsNoSnapshot() throws {
        record(date(1, hour: 9))
        #expect(try snapshots().isEmpty)
    }
}
