import Foundation
import SwiftData

/// Net worth in the home currency at one point in time; at most one per calendar day.
@Model
final class NetWorthSnapshot {
    var id: UUID = UUID()
    var date: Date = Date()
    var total: Decimal = 0
    var currency: String = ""

    init(date: Date, total: Decimal, currency: String) {
        self.date = date
        self.total = total
        self.currency = currency
    }
}

enum Reports {
    /// Upserts today's snapshot (latest value of the day wins). Unconverted balances are excluded.
    @MainActor
    static func recordNetWorth(context: ModelContext, rates: FXRates, home: String,
                               now: Date = .now, calendar: Calendar = .current) {
        guard !Storage.inMemory,  // seed data brings its own snapshots
              let accounts = try? context.fetch(FetchDescriptor<Account>()), !accounts.isEmpty
        else { return }
        let total = Accounts.netWorth(
            Holdings.worth(accounts, rates: rates),
            rates: rates, home: home, today: now
        ).total
        let day = calendar.dateInterval(of: .day, for: now)!
        let (start, end) = (day.start, day.end)
        let descriptor = FetchDescriptor<NetWorthSnapshot>(predicate: #Predicate { $0.date >= start && $0.date < end })
        if let today = try? context.fetch(descriptor).first {
            today.total = total
            today.currency = home
            today.date = now
        } else {
            context.insert(NetWorthSnapshot(date: now, total: total, currency: home))
        }
        try? context.save()
    }

    struct MonthTotal: Identifiable {
        var month: Date
        var income: Decimal
        var spend: Decimal
        var id: Date { month }
    }

    /// Home-currency income and spend for `count` calendar months ending with `now`'s month, oldest first.
    static func monthly(_ transactions: [Transaction], months count: Int, now: Date = .now, rates: FXRates,
                        home: String, calendar: Calendar = .current) -> (series: [MonthTotal], unconverted: Set<String>) {
        var unconverted = Set<String>()
        let series = (0..<count).reversed().map { back in
            let month = calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -back, to: now)!)!
            let income = Finance.homeIncome(transactions, in: month, rates: rates, home: home)
            let spend = Finance.homeSpend(transactions, in: month, rates: rates, home: home)
            for (code, amount) in income.unconverted.merging(spend.unconverted, uniquingKeysWith: +) where amount != 0 {
                unconverted.insert(code)
            }
            return MonthTotal(month: month.start, income: income.total, spend: spend.total)
        }
        return (series, unconverted)
    }

    struct CategoryTotal: Identifiable {
        var id: UUID?  // nil = Uncategorized
        var name: String
        var color: Int
        var amount: Decimal
    }

    /// Spending rows from `Budgets.spent`, largest first; income categories and unknown ids are skipped.
    static func categoryTotals(_ spent: (byCategory: [UUID: Decimal], uncategorized: Decimal, unconverted: [String: Decimal]),
                               categories: [Category]) -> [CategoryTotal] {
        var rows = categories.filter { !$0.isIncome }.compactMap { category in
            spent.byCategory[category.id].map {
                CategoryTotal(id: category.id, name: category.name, color: category.color, amount: $0)
            }
        }
        rows.append(CategoryTotal(id: nil, name: "Uncategorized", color: 0x8E8E93, amount: spent.uncategorized))
        return rows.filter { $0.amount > 0 }.sorted {
            $0.amount != $1.amount ? $0.amount > $1.amount : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    enum NetWorthRange: String, CaseIterable, Identifiable {
        case month = "1M", quarter = "3M", year = "1Y", all = "All"
        var id: Self { self }

        /// nil = no lower bound.
        func start(now: Date, calendar: Calendar = .current) -> Date? {
            let months = switch self {
            case .month: 1
            case .quarter: 3
            case .year: 12
            case .all: 0
            }
            return months == 0 ? nil : calendar.date(byAdding: .month, value: -months, to: now)
        }
    }

    /// Snapshots in the current home currency within `range`, oldest first.
    static func history(_ snapshots: [NetWorthSnapshot], range: NetWorthRange, home: String,
                        now: Date = .now, calendar: Calendar = .current) -> [NetWorthSnapshot] {
        let start = range.start(now: now, calendar: calendar) ?? .distantPast
        return snapshots.filter { $0.currency == home && $0.date >= start }.sorted { $0.date < $1.date }
    }
}
