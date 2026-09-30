import Foundation
import RegexBuilder
#if DEBUG
import SwiftData
#endif

/// Pure helpers for the Accounts screen (#35).
enum Accounts {
    /// Amount as the user would type it back into an editor.
    static func plain(_ amount: Decimal) -> String {
        amount.formatted(.number.grouping(.never).precision(.fractionLength(0...18)))
    }

    /// nil = unparseable; empty = 0. Whole-match so "12abc" / "1.2.3" are rejected, not truncated
    /// (Decimal(string:) and Decimal(_:format:) both silently parse a prefix).
    static func parseAmount(_ text: String, locale: Locale = .current) -> Decimal? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        return try? Regex { Capture(Decimal.FormatStyle(locale: locale)) }.wholeMatch(in: text)?.1
    }

    /// Non-archived accounts by type (AccountType.allCases order), name-sorted; empty types omitted.
    static func grouped(_ accounts: [Account]) -> [(type: AccountType, accounts: [Account])] {
        let active = accounts.filter { !$0.archived }
        return AccountType.allCases.compactMap { type in
            let matches = active.filter { $0.type == type }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return matches.isEmpty ? nil : (type, matches)
        }
    }

    /// Sum of balances in `home` at today's rates. Signs kept (credit owed is negative).
    /// Balances with no rate are returned per currency in `unconverted`.
    static func netWorth(
        _ balances: [(amount: Decimal, currency: String)], rates: FXRates, home: String, today: Date = .now
    ) -> (total: Decimal, unconverted: [String: Decimal]) {
        let dayRates = rates.rates(on: FXRates.day(today)) ?? [:]
        var total = Decimal(0)
        var unconverted: [String: Decimal] = [:]
        for balance in balances {
            if let converted = FX.convert(balance.amount, from: balance.currency, to: home, rates: dayRates) {
                total += converted
            } else {
                unconverted[balance.currency, default: 0] += balance.amount
            }
        }
        return (total, unconverted)
    }

    /// Transactions grouped by day, newest day first, newest transaction first within a day.
    static func days(_ transactions: [Transaction], calendar: Calendar = .current) -> [(day: Date, transactions: [Transaction])] {
        Dictionary(grouping: transactions) { calendar.startOfDay(for: $0.date) }
            .map { (day: $0.key, transactions: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}

#if DEBUG
extension Accounts {
    /// Screenshot data for `-miseSeedFinance YES`; only ever inserted into an in-memory container.
    static func seed(_ context: ModelContext) {
        func account(_ name: String, _ type: AccountType, _ currency: String, _ opening: Decimal) -> Account {
            let account = Account(name: name, type: type, currency: currency, openingBalance: opening)
            context.insert(account)
            return account
        }
        _ = account("Wallet", .cash, "SGD", 120)
        let dbs = account("DBS Multiplier", .debit, "SGD", Decimal(string: "4250.30")!)
        let wise = account("Wise USD", .debit, "USD", 800)
        let citi = account("Citi Rewards", .credit, "SGD", Decimal(string: "-640.50")!)
        _ = account("IBKR", .brokerage, "USD", 12_000)
        account("Old POSB", .debit, "SGD", 0).archived = true

        let groceries = Category(name: "Groceries", icon: "cart", color: 0x34C759)
        let transport = Category(name: "Transport", icon: "car", color: 0x007AFF)
        let income = Category(name: "Income", icon: "banknote", color: 0x30B0C7)
        let dining = Category(name: "Dining", icon: "fork.knife", color: 0xFF9500)
        // Screenshot budgets vs the rows below: groceries ~83% orange, transport >100% red, dining green.
        for (index, (category, budget)) in [(groceries, 180), (transport, 50), (income, nil), (dining, 100)].enumerated() {
            category.sortOrder = index
            category.budget = budget.map { Decimal($0) }
        }
        let day: TimeInterval = 86_400
        // Clamp into this month (order kept) so the Budgets screen has spend on the 1st-3rd too.
        let monthStart = Calendar.current.dateInterval(of: .month, for: .now)!.start
        func date(_ ago: TimeInterval) -> Date { max(.now - ago, monthStart + (3 * day - ago) / 1_000) }
        let rows: [(String, String, Category, TimeInterval)] = [
            ("Salary", "5200", income, 2 * day + 3_600),
            ("FairPrice", "-84.35", groceries, 2 * day),
            ("Grab", "-18.60", transport, day + 7_200),
            ("FairPrice", "-12.90", groceries, day + 3_600),
            ("Grab", "-9.40", transport, day),
            ("Cold Storage", "-46.20", groceries, 10_800),
            ("Grab", "-22.10", transport, 3_600),
            ("FairPrice", "-6.75", groceries, 600),
        ]
        for (merchant, amount, category, ago) in rows {
            let transaction = Transaction(amount: Decimal(string: amount)!, currency: "SGD", date: date(ago))
            transaction.merchant = merchant
            transaction.account = dbs
            transaction.category = category
            context.insert(transaction)
        }
        let coffee = Transaction(amount: Decimal(string: "-6.50")!, currency: "USD", date: date(3 * day))
        coffee.merchant = "Blue Bottle"
        coffee.notes = "SF trip"
        coffee.accountAmount = Decimal(string: "-8.80")!
        coffee.account = citi
        coffee.category = dining
        context.insert(coffee)
        for (from, to, amount, toAmount, ago) in [
            (dbs, wise, Decimal(1350), Decimal(1000), 4 * day),
            (dbs, citi, Decimal(string: "640.50")!, Decimal(string: "640.50")!, 5 * day),
        ] {
            let transfer = Transfer(amount: amount, toAmount: toAmount, date: .now - ago)
            transfer.from = from
            transfer.to = to
            context.insert(transfer)
        }
        try? context.save()
    }
}
#endif
