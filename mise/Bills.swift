import Foundation
import SwiftData

// Recurring bills and subscriptions (#38). Same model rules as Finance.swift.

enum BillCadence: String, Codable, CaseIterable {
    case weekly, monthly, yearly
}

@Model
final class Bill {
    var id: UUID = UUID()
    var name: String = ""
    /// Positive magnitude of the outflow.
    var amount: Decimal = 0
    var currency: String = ""
    var account: Account?
    var category: Category?
    var cadence: BillCadence = BillCadence.monthly
    /// Every N weeks/months/years.
    var interval: Int = 1
    var nextDue: Date = Date()
    /// Day-of-month the bill is anchored to; short months clamp to their last day.
    var anchorDay: Int = 1
    /// Remind N days before; 0 = only on the due date.
    var remindDays: Int = 3
    var active: Bool = true
    var createdAt: Date = Date()

    init(name: String, amount: Decimal, currency: String, nextDue: Date) {
        self.name = name
        self.amount = amount
        self.currency = currency
        self.nextDue = nextDue
        self.anchorDay = Calendar.current.component(.day, from: nextDue)
    }
}

enum Bills {
    /// Next due date after `due`. Monthly/yearly land on `anchorDay`, clamped to the month's length.
    static func advance(_ due: Date, cadence: BillCadence, interval: Int, anchorDay: Int,
                        calendar: Calendar = .current) -> Date {
        let interval = max(interval, 1)
        let months: Int
        switch cadence {
        case .weekly: return calendar.date(byAdding: .day, value: 7 * interval, to: due)!
        case .monthly: months = interval
        case .yearly: months = 12 * interval
        }
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second, .nanosecond]
        var components = calendar.dateComponents(fields, from: due)
        components.day = 1
        let month = calendar.date(byAdding: .month, value: months, to: calendar.date(from: components)!)!
        components = calendar.dateComponents(fields, from: month)
        components.day = min(anchorDay, calendar.range(of: .day, in: .month, for: month)!.count)
        return calendar.date(from: components)!
    }

    static func monthlyAmount(_ amount: Decimal, cadence: BillCadence, interval: Int) -> Decimal {
        let interval = Decimal(max(interval, 1))
        switch cadence {
        case .weekly: return amount * 52 / 12 / interval
        case .monthly: return amount / interval
        case .yearly: return amount / 12 / interval
        }
    }

    /// Due on an earlier calendar day than `now`; due today is not overdue.
    static func isOverdue(_ due: Date, now: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }
}
