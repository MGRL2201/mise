import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct BudgetsTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let month = DateInterval(start: Date(timeIntervalSince1970: 1_000_000), duration: 30 * 86_400)

    @discardableResult
    func transaction(_ amount: Decimal, _ category: mise.Category?, at date: Date? = nil) -> mise.Transaction {
        let transaction = mise.Transaction(amount: amount, currency: "SGD", date: date ?? month.start)
        context.insert(transaction)
        transaction.category = category
        return transaction
    }

    @Test func thresholds() {
        #expect(Budgets.thresholds(spent: Decimal(string: "79.99")!, budget: 100) == [])
        #expect(Budgets.thresholds(spent: 80, budget: 100) == [80])
        #expect(Budgets.thresholds(spent: 100, budget: 100) == [80, 100])
        #expect(Budgets.thresholds(spent: 500, budget: nil) == [])
        #expect(Budgets.thresholds(spent: 500, budget: 0) == [])
    }

    @Test func alertIDsSkipSent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let id = UUID()
        let march = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15)))
        let prefix = "budget|\(id.uuidString)|2026-03|"
        #expect(Budgets.alertIDs(categoryID: id, month: march, spent: 100, budget: 100, sent: [], calendar: calendar)
                == [prefix + "80", prefix + "100"])
        #expect(Budgets.alertIDs(categoryID: id, month: march, spent: 100, budget: 100, sent: [prefix + "80"], calendar: calendar)
                == [prefix + "100"])
        #expect(Budgets.alertIDs(categoryID: id, month: march, spent: 10, budget: 100, sent: [], calendar: calendar) == [])
    }

    @Test func spentGroupsOutflowsPerCategoryInMonth() throws {
        let food = mise.Category(name: "Food")
        let travel = mise.Category(name: "Travel")
        context.insert(food)
        context.insert(travel)
        let all = [
            transaction(-30, food),
            transaction(-20, food),
            transaction(15, food),
            transaction(-100, food, at: month.end),
            transaction(-7, travel),
            transaction(-5, nil),
        ]
        let result = Budgets.spent(all, in: month, rates: FXRates(), home: "SGD")
        #expect(result.byCategory == [food.id: 50, travel.id: 7])
        #expect(result.uncategorized == 5)
        #expect(result.unconverted.isEmpty)
    }

    @Test func claimAlertsOncePerThresholdInCurrentMonth() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        defaults.set("SGD", forKey: FX.homeKey)
        let now = Date.now
        let food = mise.Category(name: "Food")
        food.budget = 100
        context.insert(food)
        func spend(_ amount: Decimal, at date: Date = now) {
            transaction(-amount, food, at: date).homeAmount = -amount
        }
        let claim = { (date: Date) in Budgets.claimAlerts(for: food, on: date, context: self.context, now: now, defaults: defaults) }
        let month = String(format: "%04d-%02d", Calendar.current.component(.year, from: now), Calendar.current.component(.month, from: now))
        let prefix = "budget|\(food.id.uuidString)|\(month)|"

        spend(85)
        #expect(claim(now) == [prefix + "80"])
        #expect(claim(now) == [])
        spend(20)
        #expect(claim(now) == [prefix + "100"])

        let lastMonth = try #require(Calendar.current.date(byAdding: .month, value: -1, to: now))
        spend(500, at: lastMonth)
        #expect(claim(lastMonth) == [])
    }

    @Test func claimAlertsNeedsBudget() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let food = mise.Category(name: "Food")
        context.insert(food)
        transaction(-500, food, at: .now).homeAmount = -500
        #expect(Budgets.claimAlerts(for: food, on: .now, context: context, defaults: defaults) == [])
        #expect(Budgets.claimAlerts(for: nil, on: .now, context: context, defaults: defaults) == [])
    }

    @Test func starterCategoriesCreatedOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        Budgets.addStarterCategories(context: context, defaults: defaults)
        let created = try context.fetch(FetchDescriptor<mise.Category>())
        #expect(created.count == 10)
        #expect(Budgets.ordered(created).map(\.sortOrder) == Array(0...9))
        created.forEach(context.delete)
        try context.save()
        Budgets.addStarterCategories(context: context, defaults: defaults)
        #expect(try context.fetchCount(FetchDescriptor<mise.Category>()) == 0)
    }

    @Test func starterCategoriesSkippedWhenCategoriesExist() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        context.insert(mise.Category(name: "Mine"))
        try context.save()
        Budgets.addStarterCategories(context: context, defaults: defaults)
        #expect(try context.fetch(FetchDescriptor<mise.Category>()).map(\.name) == ["Mine"])
        #expect(defaults.bool(forKey: Budgets.starterKey))
    }

    @Test func orderedAndNamed() {
        let b = mise.Category(name: "b")
        let a2 = mise.Category(name: "a10")
        let a1 = mise.Category(name: "a9")
        let first = mise.Category(name: "z")
        first.sortOrder = -1
        let categories = [b, a2, a1, first]
        #expect(Budgets.ordered(categories).map(\.name) == ["z", "a9", "a10", "b"])
        #expect(Budgets.named("  A9 ", in: categories) === a1)
        #expect(Budgets.named("a9\n", in: categories) === a1)
        #expect(Budgets.named("a", in: categories) == nil)
    }
}
