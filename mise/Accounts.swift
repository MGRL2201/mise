import Foundation

/// Pure helpers for the Accounts screen (#35).
enum Accounts {
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
