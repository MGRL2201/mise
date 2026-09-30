import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct FinanceTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let start = Date(timeIntervalSince1970: 1_000_000)

    @discardableResult
    func transaction(_ amount: Decimal, on account: Account?, currency: String = "SGD", at date: Date? = nil) -> mise.Transaction {
        let transaction = mise.Transaction(amount: amount, currency: currency, date: date ?? start)
        context.insert(transaction)
        transaction.account = account
        return transaction
    }

    func transfer(_ amount: Decimal, from: Account, to: Account) {
        let transfer = Transfer(amount: amount, toAmount: amount, date: start)
        context.insert(transfer)
        transfer.from = from
        transfer.to = to
    }

    @Test func balanceSumsTransactionsAndTransfers() throws {
        let account = Account(name: "Main", type: .debit, currency: "SGD", openingBalance: 100)
        let other = Account(name: "Other", type: .cash, currency: "SGD")
        context.insert(account)
        context.insert(other)
        transaction(-30, on: account)
        transaction(50, on: account)
        transaction(-999, on: account, currency: "USD")
        transfer(20, from: account, to: other)
        transfer(10, from: other, to: account)
        try context.save()
        #expect(Finance.balance(of: account) == 110)
    }

    @Test func creditCardPaymentIsNotSpentTwice() throws {
        let debit = Account(name: "Debit", type: .debit, currency: "SGD", openingBalance: 500)
        let card = Account(name: "Card", type: .credit, currency: "SGD")
        context.insert(debit)
        context.insert(card)
        transaction(-40, on: card)
        transfer(40, from: debit, to: card)
        try context.save()
        #expect(Finance.balance(of: card) == 0)
        #expect(Finance.balance(of: debit) == 460)
        let range = DateInterval(start: start, duration: 86_400)
        #expect(Finance.spend(try context.fetch(FetchDescriptor<mise.Transaction>()), in: range) == ["SGD": 40])
    }

    @Test func spendIsHalfOpenOutflowsGroupedByCurrency() {
        let range = DateInterval(start: start, duration: 86_400)
        let transactions = [
            transaction(-10, on: nil, at: range.start),
            transaction(-5, on: nil, at: range.start + 60),
            transaction(-7, on: nil, currency: "USD", at: range.start + 60),
            transaction(100, on: nil, at: range.start + 60),
            transaction(-1000, on: nil, at: range.end),
            transaction(-1000, on: nil, at: range.start - 1),
        ]
        #expect(Finance.spend(transactions, in: range) == ["SGD": 15, "USD": 7])
    }
}
