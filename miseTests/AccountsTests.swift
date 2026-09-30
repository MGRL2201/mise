import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct AccountsTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func groupedFollowsTypeOrderSortsByNameSkipsArchivedAndEmpty() {
        let archived = Account(name: "Old", type: .cash, currency: "SGD")
        archived.archived = true
        let accounts = [
            Account(name: "Visa 10", type: .credit, currency: "SGD"),
            Account(name: "Main", type: .debit, currency: "SGD"),
            Account(name: "Visa 9", type: .credit, currency: "SGD"),
            archived,
        ]
        let groups = Accounts.grouped(accounts)
        #expect(groups.map(\.type) == [.debit, .credit])
        #expect(groups[1].accounts.map(\.name) == ["Visa 9", "Visa 10"])
    }

    @Test func netWorthSubtractsCreditConvertsForeignAndKeepsUnconverted() {
        var rates = FXRates()
        rates.days[FXRates.day(start)] = ["EUR": 1, "USD": 2, "SGD": 4]
        let result = Accounts.netWorth(
            [(100, "SGD"), (-30, "SGD"), (10, "USD"), (500, "JPY")],
            rates: rates, home: "SGD", today: start
        )
        #expect(result.total == 90)
        #expect(result.unconverted == ["JPY": 500])
    }

    @Test func daysNewestFirstWithinAndAcross() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: start)
        func make(_ offset: TimeInterval) -> mise.Transaction {
            let transaction = mise.Transaction(amount: -1, currency: "SGD", date: day + offset)
            context.insert(transaction)
            return transaction
        }
        let early = make(3_600), late = make(7_200), nextDay = make(86_400 + 60)
        let days = Accounts.days([early, nextDay, late], calendar: calendar)
        #expect(days.map(\.day) == [day + 86_400, day])
        #expect(days[1].transactions.map(\.id) == [late.id, early.id])
        #expect(days[0].transactions.map(\.id) == [nextDay.id])
    }
}
