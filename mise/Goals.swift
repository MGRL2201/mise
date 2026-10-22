import Foundation
import SwiftData

// Savings goals (#39). Same model rules as Finance.swift.

/// A manual deposit into a goal, in the goal's currency; negative = withdrawal.
struct GoalContribution: Codable, Hashable, Identifiable {
    var id = UUID()
    var amount: Decimal
    var date: Date
}

@Model
final class Goal {
    var id: UUID = UUID()
    var name: String = ""
    /// Positive amount to reach.
    var target: Decimal = 0
    var currency: String = ""
    var targetDate: Date?
    /// When set, progress is the account's balance and `currency` follows the account's.
    var account: Account?
    var contributions: [GoalContribution] = []
    var createdAt: Date = Date()

    init(name: String, target: Decimal, currency: String) {
        self.name = name
        self.target = target
        self.currency = currency
    }
}

enum Goals {
    /// The linked account's balance, otherwise the sum of contributions.
    // ponytail: a linked account whose currency later changes isn't converted; convert via FX if that happens.
    static func saved(_ goal: Goal, rates: FXRates) -> Decimal {
        if let account = goal.account { return Finance.balance(of: account, rates: rates) }
        return goal.contributions.reduce(Decimal(0)) { $0 + $1.amount }
    }

    /// 0...1 for ProgressView; 0 when there's no positive target.
    static func fraction(saved: Decimal, target: Decimal) -> Double {
        guard target > 0 else { return 0 }
        return min(max(NSDecimalNumber(decimal: saved / target).doubleValue, 0), 1)
    }

    /// Amount per month to reach `target` by `date`, rounded up to cents. A partial month counts
    /// as a whole one; a past or same-month date means everything is due now.
    static func monthlyNeeded(saved: Decimal, target: Decimal, by date: Date?, now: Date = .now,
                              calendar: Calendar = .current) -> Decimal? {
        guard let date else { return nil }
        guard saved < target else { return 0 }
        let start = calendar.startOfDay(for: now), end = calendar.startOfDay(for: date)
        let whole = calendar.dateComponents([.month], from: start, to: end).month ?? 0
        let partial = calendar.date(byAdding: .month, value: whole, to: start)! < end
        var perMonth = (target - saved) / Decimal(max(whole + (partial ? 1 : 0), 1))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &perMonth, 2, .up)
        return rounded
    }
}
