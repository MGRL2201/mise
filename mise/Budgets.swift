import Foundation
import SwiftData
import UserNotifications

/// Categories + monthly budgets with 80% / 100% alerts (#37).
enum Budgets {
    /// Alert ids already posted (see `alertIDs`).
    // ponytail: grows by ≤2 ids per category per month; prune old months if it ever matters.
    static let sentKey = "budget.alerted"
    static let starterKey = "finance.starterCategories"

    static let starter: [(name: String, icon: String, color: Int)] = [
        ("Groceries", "cart", 0x34C759),
        ("Dining", "fork.knife", 0xFF9500),
        ("Transport", "car", 0x007AFF),
        ("Housing", "house", 0x8E6E53),
        ("Utilities", "bolt", 0xFFCC00),
        ("Shopping", "bag", 0xFF2D55),
        ("Health", "cross.case", 0xFF3B30),
        ("Entertainment", "film", 0xAF52DE),
        ("Travel", "airplane", 0x5AC8FA),
        ("Subscriptions", "repeat", 0x5856D6),
    ]

    /// Seeds the starter set once per install; never again, even after the user deletes them all.
    @MainActor
    static func addStarterCategories(context: ModelContext, defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: starterKey) { return }
        if (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0 == 0 {
            for (index, item) in starter.enumerated() {
                let category = Category(name: item.name, icon: item.icon, color: item.color)
                category.sortOrder = index
                context.insert(category)
            }
            guard (try? context.save()) != nil else { return }
        }
        defaults.set(true, forKey: starterKey)
    }

    static func ordered(_ categories: [Category]) -> [Category] {
        categories.sorted {
            $0.sortOrder != $1.sortOrder
                ? $0.sortOrder < $1.sortOrder
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Trimmed, case-insensitive exact name match.
    static func named(_ name: String, in categories: [Category]) -> Category? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return categories.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Home-currency outflows in `month` per category id (via `Finance.homeSpend`).
    /// Refunds (positive amounts) do not net off spending.
    static func spent(
        _ transactions: [Transaction], in month: DateInterval, rates: FXRates, home: String
    ) -> (byCategory: [UUID: Decimal], uncategorized: Decimal, unconverted: [String: Decimal]) {
        var byCategory: [UUID: Decimal] = [:]
        var uncategorized = Decimal(0)
        var unconverted: [String: Decimal] = [:]
        for (id, group) in Dictionary(grouping: transactions, by: { $0.category?.id }) {
            let spend = Finance.homeSpend(group, in: month, rates: rates, home: home)
            if let id { byCategory[id] = spend.total } else { uncategorized = spend.total }
            unconverted.merge(spend.unconverted, uniquingKeysWith: +)
        }
        return (byCategory, uncategorized, unconverted)
    }

    /// Which of 80 / 100 percent `spent` has reached; [] without a positive budget.
    static func thresholds(spent: Decimal, budget: Decimal?) -> [Int] {
        guard let budget, budget > 0 else { return [] }
        return [80, 100].filter { spent * 100 >= budget * Decimal($0) }
    }

    /// "budget|<category>|<yyyy-MM>|<threshold>" for reached thresholds not yet in `sent`.
    static func alertIDs(categoryID: UUID, month: Date, spent: Decimal, budget: Decimal?,
                         sent: Set<String>, calendar: Calendar = .current) -> [String] {
        let components = calendar.dateComponents([.year, .month], from: month)
        let key = String(format: "%04d-%02d", components.year!, components.month!)
        return thresholds(spent: spent, budget: budget)
            .map { "budget|\(categoryID.uuidString)|\(key)|\($0)" }
            .filter { !sent.contains($0) }
    }

    /// Newly reached alert ids for `category` this month, marked sent in `defaults`.
    @MainActor
    static func claimAlerts(for category: Category?, on date: Date, context: ModelContext,
                            now: Date = .now, defaults: UserDefaults = .standard) -> [String] {
        let calendar = Calendar.current
        guard !Storage.inMemory, let category, let budget = category.budget,
              calendar.isDate(date, equalTo: now, toGranularity: .month),
              let month = calendar.dateInterval(of: .month, for: now)
        else { return [] }
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        // ponytail: unconverted foreign spend is ignored here until rates arrive.
        let spent = Budgets.spent(transactions, in: month, rates: .load(), home: FX.home(defaults)).byCategory[category.id] ?? 0
        let sent = defaults.stringArray(forKey: sentKey) ?? []
        let ids = alertIDs(categoryID: category.id, month: now, spent: spent, budget: budget, sent: Set(sent))
        // Marked sent before the permission check on purpose: granting permission later must not flood old alerts.
        if !ids.isEmpty { defaults.set(sent + ids, forKey: sentKey) }
        return ids
    }

    /// Call after saving a transaction dated `date` in `category`; posts any newly reached alert.
    @MainActor
    static func checkAlerts(for category: Category?, on date: Date, context: ModelContext,
                            now: Date = .now, defaults: UserDefaults = .standard) async {
        guard let category, let budget = category.budget,
              let last = claimAlerts(for: category, on: date, context: context, now: now, defaults: defaults).last,
              await LocalNotifications.authorized(prompt: false),
              let month = Calendar.current.dateInterval(of: .month, for: now)
        else { return }
        let home = FX.home(defaults)
        let transactions = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let spent = Budgets.spent(transactions, in: month, rates: .load(), home: home).byCategory[category.id] ?? 0
        // Both thresholds at once: only the 100% one is shown.
        await post(id: last, name: category.name, spent: spent, budget: budget, home: home)
    }

    private static func post(id: String, name: String, spent: Decimal, budget: Decimal, home: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(name) budget"
        let amounts = "\(spent.formatted(.currency(code: home))) of \(budget.formatted(.currency(code: home)))"
        content.body = id.hasSuffix("|100")
            ? "Over budget: \(amounts)"
            : "80% of your monthly budget used (\(amounts))"
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
