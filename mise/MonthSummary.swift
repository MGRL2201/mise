import Foundation
import Observation
import UserNotifications

/// Month-end spending summary notification (#41). Tapping it opens the summary for that month.
enum MonthSummary {
    static let enabledKey = "finance.monthEnd"
    static let timeKey = "finance.monthEndTime"
    /// Minutes after midnight.
    static let defaultTime = 20 * 60
    nonisolated static let prefix = "month-end|"
    private static var last: Task<Void, Never>?

    /// Last day of `now`'s month at `minutes`; the next month's last day once that moment has passed.
    static func fireDate(after now: Date, minutes: Int, calendar: Calendar = .current) -> DateComponents {
        let start = calendar.dateInterval(of: .month, for: now)!.start
        func lastDay(monthsAhead: Int) -> DateComponents {
            let month = calendar.date(byAdding: .month, value: monthsAhead, to: start)!
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = calendar.range(of: .day, in: .month, for: month)!.count
            components.hour = minutes / 60
            components.minute = minutes % 60
            return components
        }
        let this = lastDay(monthsAhead: 0)
        return calendar.date(from: this)! > now ? this : lastDay(monthsAhead: 1)
    }

    /// Schedules or removes the notification to match the settings. `prompt: false` never asks for permission.
    /// Serialized like `DailyPlanning.sync`.
    static func sync(prompt: Bool) async {
        let prev = last
        let task = Task { await prev?.value; await apply(prompt: prompt) }
        last = task
        await task.value
    }

    // ponytail: only the next month-end is scheduled; rescheduled on app active, so a month without
    // opening the app gets no notification. Schedule several months ahead if that matters.
    private static func apply(prompt: Bool) async {
        guard !Storage.inMemory else { return }  // seeded sample data must never replace real notifications
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey), await LocalNotifications.authorized(prompt: prompt) else {
            return await LocalNotifications.replace(prefix: prefix, with: [])
        }
        let calendar = Calendar.current
        let components = fireDate(after: .now, minutes: defaults.object(forKey: timeKey) as? Int ?? defaultTime, calendar: calendar)
        let content = UNMutableNotificationContent()
        content.title = "Month-end summary"
        content.body = "See how \(calendar.date(from: components)!.formatted(.dateTime.month(.wide))) went."
        content.sound = .default
        let id = prefix + String(format: "%04d-%02d", components.year!, components.month!)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        await LocalNotifications.replace(prefix: prefix, with: [UNNotificationRequest(identifier: id, content: content, trigger: trigger)])
    }

    struct CategoryLine: Identifiable {
        var id: UUID?  // nil = Uncategorized
        var name: String
        var color: Int
        var spent: Decimal
        var budget: Decimal?
        var isOver: Bool { Budgets.thresholds(spent: spent, budget: budget).contains(100) }
    }

    /// Spending categories with spend or a budget, plus Uncategorized if any; over budget first, then largest.
    static func categoryLines(_ spent: (byCategory: [UUID: Decimal], uncategorized: Decimal, unconverted: [String: Decimal]),
                              categories: [Category]) -> [CategoryLine] {
        var lines = categories.filter { !$0.isIncome }.compactMap { category -> CategoryLine? in
            let amount = spent.byCategory[category.id] ?? 0
            guard amount > 0 || (category.budget ?? 0) > 0 else { return nil }
            return CategoryLine(id: category.id, name: category.name, color: category.color, spent: amount, budget: category.budget)
        }
        if spent.uncategorized > 0 {
            lines.append(CategoryLine(id: nil, name: "Uncategorized", color: 0x8E8E93, spent: spent.uncategorized, budget: nil))
        }
        return lines.sorted {
            if $0.isOver != $1.isOver { return $0.isOver }
            if $0.spent != $1.spent { return $0.spent > $1.spent }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Largest home-currency outflows in `month`, merchants merged by `Categorizer.normalize`;
    /// named by the latest in-month spelling.
    static func topMerchants(_ transactions: [Transaction], in month: DateInterval, rates: FXRates, home: String,
                             limit: Int = 5) -> [(name: String, amount: Decimal)] {
        Dictionary(grouping: transactions, by: { Categorizer.normalize($0.merchant) })
            .filter { !$0.key.isEmpty }
            .compactMap { _, group -> (name: String, amount: Decimal)? in
                let amount = Finance.homeSpend(group, in: month, rates: rates, home: home).total
                guard amount != 0, let name = group
                    .filter({ month.start <= $0.date && $0.date < month.end && !$0.merchant.isEmpty })
                    .max(by: { $0.date < $1.date })?.merchant else { return nil }
                return (name, amount)
            }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(limit)
            .map { $0 }
    }
}

/// Presents the month-end summary from a notification tap; non-nil `month` = presenting. Like `BillPrompt`.
@Observable final class MonthSummaryPrompt {
    static let shared = MonthSummaryPrompt()
    var month: Date?
    func show(month: Date) { self.month = month }
}
