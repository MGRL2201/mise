import Foundation
import Observation
import SwiftData
import UserNotifications

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
    nonisolated static let prefix = "bill|"
    private static var last: Task<Void, Never>?
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

    /// 09:00 reminders for each active bill's next occurrence: `remindDays` before (if > 0) and on the due day. Past ones dropped.
    // ponytail: iOS keeps only 64 pending notifications shared across features (2 per bill → ~30 bills ceiling); cap by soonest date if it ever matters.
    static func reminders(for bills: [Bill], now: Date, calendar: Calendar = .current) -> [(id: String, date: Date, body: String)] {
        bills.filter(\.active).flatMap { bill in
            let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.startOfDay(for: bill.nextDue))!
            let label = "\(bill.name): \(bill.amount.formatted(.currency(code: bill.currency))) due"
            var result: [(id: String, date: Date, body: String)] = []
            if bill.remindDays > 0 {
                let when = bill.remindDays == 1 ? "tomorrow" : "in \(bill.remindDays) days"
                result.append(("\(prefix)\(bill.id.uuidString)|before",
                               calendar.date(byAdding: .day, value: -bill.remindDays, to: due)!, "\(label) \(when)"))
            }
            result.append(("\(prefix)\(bill.id.uuidString)|due", due, "\(label) today"))
            return result.filter { $0.date > now }
        }
    }

    /// Reschedules every bill reminder. `prompt: false` never asks for permission. Serialized like `DailyPlanning.sync`.
    static func sync(context: ModelContext, prompt: Bool) async {
        let prev = last
        let task = Task { await prev?.value; await apply(context: context, prompt: prompt) }
        last = task
        await task.value
    }

    private static func apply(context: ModelContext, prompt: Bool) async {
        guard !Storage.inMemory else { return }  // seeded sample data must never replace real notifications
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        guard await LocalNotifications.authorized(prompt: prompt) else {
            return await LocalNotifications.replace(prefix: prefix, with: [])
        }
        let calendar = Calendar.current
        let requests = reminders(for: bills, now: .now, calendar: calendar).map { reminder in
            let content = UNMutableNotificationContent()
            content.title = "Bill due"
            content.body = reminder.body
            content.sound = .default
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
        }
        await LocalNotifications.replace(prefix: prefix, with: requests)
    }

    /// Records the payment as a manual outflow and moves the bill to its next due date.
    /// No side effects: callers run `FX.refresh`, `Budgets.checkAlerts(for:on:context:)` and
    /// `Bills.sync(context:prompt:)` afterwards, like `TransactionEditor.save`.
    @discardableResult
    static func markPaid(_ bill: Bill, context: ModelContext, now: Date = .now, calendar: Calendar = .current) -> Transaction {
        let transaction = Transaction(amount: -bill.amount, currency: bill.currency, date: now)
        context.insert(transaction)
        transaction.merchant = bill.name
        transaction.account = bill.account
        transaction.category = bill.category
        transaction.source = .manual
        transaction.categoryIsAuto = false
        transaction.homeAmount = nil  // FX.refresh fills it.
        bill.nextDue = advance(bill.nextDue, cadence: bill.cadence, interval: bill.interval, anchorDay: bill.anchorDay, calendar: calendar)
        try? context.save()
        return transaction
    }
}

/// Presents the Bills screen from a reminder tap; like `WakePrompt`.
@Observable final class BillPrompt {
    static let shared = BillPrompt()
    var isPresented = false
    func show() { isPresented = true }
}
