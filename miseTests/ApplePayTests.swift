import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct ApplePayTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let defaults = UserDefaults(suiteName: UUID().uuidString)!

    @Test(arguments: [
        ("S$12.50", "SGD", "12.50", "SGD"), ("$4.20", "SGD", "4.20", "SGD"), ("$4.20", "EUR", "4.20", "USD"),
        ("12,50 €", "SGD", "12.50", "EUR"), ("SGD 7.00", "SGD", "7.00", "SGD"), ("7.00 sgd", "EUR", "7.00", "SGD"),
        ("€1.234,56", "SGD", "1234.56", "EUR"), ("1,234.56", "SGD", "1234.56", "SGD"), ("-$4.20", "SGD", "4.20", "SGD"),
        ("US$5", "SGD", "5", "USD"), ("£3", "SGD", "3", "GBP"), ("12.5", "SGD", "12.5", "SGD"),
        ("1\u{00A0}234,50\u{202F}€", "SGD", "1234.50", "EUR"), ("RM 8,90", "SGD", "8.90", "MYR"),
        ("1.234", "SGD", "1234", "SGD"), ("1.234.567", "SGD", "1234567", "SGD"), ("1,234", "SGD", "1234", "SGD"),
        ("", "SGD", nil, nil), ("abc", "SGD", nil, nil), ("$", "SGD", nil, nil), ("0.00", "SGD", nil, nil),
        ("12abc", "SGD", nil, nil), ("1.2.3,4,5", "SGD", nil, nil),
        ("CA$4.20", "SGD", "4.20", "CAD"), ("JP¥1,234", "SGD", "1234", "JPY"), ("¥12.50", "CNY", "12.50", "CNY"),
        ("¥500", "SGD", "500", "JPY"), ("1.234 ¥", "SGD", "1234", "JPY"),
    ] as [(String, String, String?, String?)])
    func parseAmount(raw: String, fallback: String, amount: String?, currency: String?) {
        let parsed = ApplePay.parseAmount(raw, fallback: fallback)
        #expect(parsed?.amount == amount.flatMap { Decimal(string: $0) })
        #expect(parsed?.currency == currency)
    }

    @Test func duplicate() {
        let card = Account(name: "Card", type: .credit, currency: "SGD")
        let other = Account(name: "Other", type: .credit, currency: "SGD")
        context.insert(card)
        context.insert(other)
        let date = Date(timeIntervalSince1970: 1_000_000)
        func existing(_ amount: Decimal = -4.2, merchant: String = "STARBUCKS #123", account: Account? = nil,
                      offset: TimeInterval = 0, source: TransactionSource = .applePay) -> [mise.Transaction] {
            let transaction = mise.Transaction(amount: amount, currency: "SGD", date: date.addingTimeInterval(offset))
            context.insert(transaction)
            transaction.merchant = merchant
            transaction.account = account ?? card
            transaction.source = source
            return [transaction]
        }
        func isDuplicate(_ transactions: [mise.Transaction]) -> Bool {
            ApplePay.isDuplicate(amount: -4.2, merchant: "Starbucks", account: card, date: date, in: transactions)
        }
        #expect(isDuplicate(existing(offset: 299)))
        #expect(isDuplicate(existing(offset: -300)))
        #expect(!isDuplicate(existing(offset: 360)))
        #expect(!isDuplicate(existing(account: other)))
        #expect(!isDuplicate(existing(-4.3)))
        #expect(!isDuplicate(existing(merchant: "Grab")))
        #expect(!isDuplicate(existing(source: .manual)))
        #expect(!isDuplicate([]))
    }

    @Test func cardMapping() {
        let visa = Account(name: "Visa", type: .credit, currency: "SGD")
        let fallback = Account(name: "Default", type: .cash, currency: "SGD")
        let archived = Account(name: "Old", type: .credit, currency: "SGD")
        archived.archived = true
        let accounts = [visa, fallback, archived]
        #expect(ApplePay.account(forCard: "Visa", in: accounts, defaults: defaults) == nil)

        defaults.set(["Visa Signature": visa.id.uuidString, "Old Card": archived.id.uuidString, "New": ""],
                     forKey: ApplePay.cardsKey)
        #expect(ApplePay.account(forCard: "Visa Signature", in: accounts, defaults: defaults) === visa)
        #expect(ApplePay.account(forCard: " visa signature ", in: accounts, defaults: defaults) === visa)
        #expect(ApplePay.account(forCard: "New", in: accounts, defaults: defaults) == nil)

        defaults.set(fallback.id.uuidString, forKey: ApplePay.defaultKey)
        #expect(ApplePay.account(forCard: "New", in: accounts, defaults: defaults) === fallback)
        #expect(ApplePay.account(forCard: "Unknown", in: accounts, defaults: defaults) === fallback)
        #expect(ApplePay.account(forCard: "Old Card", in: accounts, defaults: defaults) === fallback)

        ApplePay.remember(card: "  Amex  ", defaults: defaults)
        ApplePay.remember(card: "AMEX", defaults: defaults)
        ApplePay.remember(card: "VISA SIGNATURE", defaults: defaults)
        ApplePay.remember(card: " ", defaults: defaults)
        #expect(defaults.dictionary(forKey: ApplePay.cardsKey) as? [String: String] ==
                ["Visa Signature": visa.id.uuidString, "Old Card": archived.id.uuidString, "New": "", "Amex": ""])
    }
    @Test func log() async {
        func log(_ raw: String, merchant: String = "Starbucks", date: Date = .now) async -> (dialog: String, saved: mise.Transaction?) {
            await ApplePay.log(amount: raw, merchant: merchant, card: "Visa", date: date, context: context,
                               defaults: defaults, modelAvailable: false)
        }
        func count() -> Int { (try? context.fetchCount(FetchDescriptor<mise.Transaction>())) ?? -1 }

        let none = await log("S$12.50")
        #expect(none.dialog == "Choose a default Apple Pay account in mise: Money → Apple Pay.")
        #expect(none.saved == nil && count() == 0)

        let card = Account(name: "Card", type: .credit, currency: "SGD")
        let coffee = Category(name: "Coffee")
        context.insert(card)
        context.insert(coffee)
        defaults.set(card.id.uuidString, forKey: ApplePay.defaultKey)
        let date = Date.now
        let first = await log("S$12.50", merchant: " Starbucks ", date: date)
        #expect(first.dialog.hasPrefix("Logged"))
        #expect(first.saved?.amount == Decimal(string: "-12.50") && first.saved?.currency == "SGD")
        #expect(first.saved?.source == .applePay && first.saved?.account === card)
        #expect(first.saved?.merchant == "Starbucks" && first.saved?.category == nil && first.saved?.categoryIsAuto == false)
        #expect(count() == 1)

        let again = await log("S$12.50", date: date.addingTimeInterval(60))
        #expect(again.dialog.hasPrefix("Already logged") && again.saved == nil && count() == 1)

        defaults.set([Categorizer.normalize("Starbucks"): coffee.id.uuidString], forKey: Categorizer.rulesKey)
        let ruled = await log("S$4.20", date: date)
        #expect(ruled.saved?.category === coffee && ruled.saved?.categoryIsAuto == true && count() == 2)

        let garbage = await log("abc")
        #expect(garbage.dialog == "Couldn't read the amount \"abc\"." && garbage.saved == nil && count() == 2)

        let empty = await log("")
        #expect(empty.dialog == "Couldn't read the amount \"\"." && empty.saved == nil && count() == 2)
    }
}
