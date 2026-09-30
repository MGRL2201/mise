import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct TransactionEntryTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }

    @Test func signedTakesSignFromToggleOnly() {
        #expect(TransactionEntry.signed(12, income: false) == -12)
        #expect(TransactionEntry.signed(12, income: true) == 12)
        #expect(TransactionEntry.signed(-12, income: false) == -12)
        #expect(TransactionEntry.signed(-12, income: true) == 12)
    }

    @Test func merchantSuggestionsPrefixDedupedByFrequency() {
        let merchants = ["Starbucks", "Stripe", "starbucks", "Stripe", "Stripe", "Café Nero", "Shell", "Costa"]
        #expect(TransactionEntry.merchantSuggestions(" st", from: merchants) == ["Stripe", "Starbucks"])
        #expect(TransactionEntry.merchantSuggestions("CAFE", from: merchants) == ["Café Nero"])
        #expect(TransactionEntry.merchantSuggestions("s", from: merchants, limit: 2) == ["Stripe", "Starbucks"])
    }

    @Test func merchantSuggestionsExcludeExactMatchAndEmptyText() {
        let merchants = ["Starbucks", "Starbucks Reserve"]
        #expect(TransactionEntry.merchantSuggestions("starbucks", from: merchants) == ["Starbucks Reserve"])
        #expect(TransactionEntry.merchantSuggestions("  ", from: merchants) == [])
    }

    @Test func transferErrorCoversEachCase() {
        let sgd = Account(name: "A", type: .debit, currency: "SGD")
        let sgd2 = Account(name: "B", type: .cash, currency: "SGD")
        let usd = Account(name: "C", type: .debit, currency: "USD")
        [sgd, sgd2, usd].forEach(context.insert)
        #expect(TransactionEntry.transferError(from: nil, to: sgd2, amount: 10, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: nil, amount: 10, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: sgd, amount: 10, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: sgd2, amount: nil, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: sgd2, amount: 0, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: sgd2, amount: -5, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: sgd2, amount: 10, toAmount: nil) == nil)
        #expect(TransactionEntry.transferError(from: sgd, to: usd, amount: 10, toAmount: nil) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: usd, amount: 10, toAmount: 0) != nil)
        #expect(TransactionEntry.transferError(from: sgd, to: usd, amount: 10, toAmount: Decimal(string: "7.40")) == nil)
    }

    @Test func matchesSearchesMerchantAndNotes() {
        let transaction = mise.Transaction(amount: -5, currency: "SGD", date: .now)
        transaction.merchant = "Café Nero"
        transaction.notes = "Team lunch"
        context.insert(transaction)
        #expect(TransactionEntry.matches(transaction, search: " "))
        #expect(TransactionEntry.matches(transaction, search: "cafe"))
        #expect(TransactionEntry.matches(transaction, search: "LUNCH"))
        #expect(!TransactionEntry.matches(transaction, search: "dinner"))
    }

    @Test func monthsDistinctNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = { (m: Int, d: Int) in calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }
        let transactions = [date(3, 5), date(5, 1), date(3, 30), date(4, 15)].map {
            mise.Transaction(amount: -1, currency: "SGD", date: $0)
        }
        transactions.forEach(context.insert)
        #expect(TransactionEntry.months(transactions, calendar: calendar) == [5, 4, 3].map {
            calendar.date(from: DateComponents(year: 2026, month: $0, day: 1))!
        })
    }
}
