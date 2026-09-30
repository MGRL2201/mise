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
        #expect(Finance.balance(of: account, rates: FXRates()) == 110)
    }

    @Test func creditCardPaymentIsNotSpentTwice() throws {
        let debit = Account(name: "Debit", type: .debit, currency: "SGD", openingBalance: 500)
        let card = Account(name: "Card", type: .credit, currency: "SGD")
        context.insert(debit)
        context.insert(card)
        transaction(-40, on: card)
        transfer(40, from: debit, to: card)
        try context.save()
        #expect(Finance.balance(of: card, rates: FXRates()) == 0)
        #expect(Finance.balance(of: debit, rates: FXRates()) == 460)
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

    @Test func balanceConvertsForeignTransactionAtDateRate() throws {
        let account = Account(name: "Main", type: .debit, currency: "SGD")
        context.insert(account)
        transaction(-10, on: account, currency: "USD", at: start)
        try context.save()
        var rates = FXRates()
        rates.days[FXRates.day(start)] = [
            "EUR": Decimal(string: "1")!,
            "USD": Decimal(string: "1.1")!,
            "SGD": Decimal(string: "1.4503")!,
        ]
        #expect(Finance.balance(of: account, rates: rates) == Decimal(string: "-13.18"))
    }

    @Test func balanceUsesStoredAccountAmountForForeignTransaction() throws {
        let account = Account(name: "Main", type: .debit, currency: "SGD")
        context.insert(account)
        transaction(-10, on: account, currency: "USD").accountAmount = Decimal(string: "-13.50")
        try context.save()
        #expect(Finance.balance(of: account, rates: FXRates()) == Decimal(string: "-13.50"))
    }

    @Test func balanceSkipsForeignTransactionWithoutAccountAmountOrRate() throws {
        let account = Account(name: "Main", type: .debit, currency: "SGD", openingBalance: 5)
        context.insert(account)
        transaction(-10, on: account, currency: "USD")
        try context.save()
        #expect(Finance.balance(of: account, rates: FXRates()) == 5)
    }

    @Test func homeSpendConvertsToHomeCurrencyAndSeparatesUnconverted() {
        let day = FXRates.day(start)
        var rates = FXRates()
        rates.days[day] = [
            "EUR": Decimal(string: "1")!,
            "USD": Decimal(string: "1.1")!,
            "SGD": Decimal(string: "1.4503")!,
        ]
        let sgd = transaction(-10, on: nil, currency: "SGD", at: start)
        let usdWithHomeAmount = transaction(-11, on: nil, currency: "USD", at: start)
        usdWithHomeAmount.homeAmount = Decimal(string: "-20")
        let usdNoHomeAmount = transaction(-11, on: nil, currency: "USD", at: start)
        let vnd = transaction(-50000, on: nil, currency: "VND", at: start)
        let range = DateInterval(start: start, duration: 86_400)
        let result = Finance.homeSpend(
            [sgd, usdWithHomeAmount, usdNoHomeAmount, vnd], in: range, rates: rates, home: "SGD")
        #expect(result.total == Decimal(string: "44.50"))
        #expect(result.unconverted == ["VND": 50000])
    }
}
