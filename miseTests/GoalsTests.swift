import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct GoalsTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func needed(saved: Decimal = 400, by date: Date?) -> Decimal? {
        Goals.monthlyNeeded(saved: saved, target: 1000, by: date, now: self.date(2026, 1, 15), calendar: calendar)
    }

    @Test func monthlyNeeded() {
        #expect(needed(by: date(2026, 7, 15)) == 100)
        // 6 months + 5 days counts as 7 months; 600 / 7 rounds up.
        #expect(needed(by: date(2026, 7, 20)) == Decimal(string: "85.72"))
        #expect(needed(by: date(2025, 12, 1)) == 600)
        #expect(needed(by: date(2026, 1, 25)) == 600)
        #expect(needed(saved: 1000, by: date(2026, 7, 15)) == 0)
        #expect(needed(by: nil) == nil)
        // Time of day is ignored: same day-of-month, target later in the day, is still 6 months.
        #expect(needed(by: date(2026, 7, 15, hour: 10)) == 100)
        // Jan 31 → Feb 28 is one month.
        #expect(Goals.monthlyNeeded(saved: 400, target: 1000, by: date(2026, 2, 28), now: date(2026, 1, 31),
                                    calendar: calendar) == 600)
    }

    @Test func fraction() {
        #expect(Goals.fraction(saved: 400, target: 1000) == 0.4)
        #expect(Goals.fraction(saved: 1500, target: 1000) == 1)
        #expect(Goals.fraction(saved: -50, target: 1000) == 0)
        #expect(Goals.fraction(saved: 50, target: 0) == 0)
    }

    @Test func savedSumsContributions() {
        let goal = Goal(name: "Trip", target: 1000, currency: "SGD")
        goal.contributions = [100, 250, -50].map { GoalContribution(amount: $0, date: .now) }
        #expect(Goals.saved(goal, rates: FXRates()) == 300)
    }

    @Test func savedFollowsLinkedAccountUntilDeleted() throws {
        let account = Account(name: "Savings", type: .debit, currency: "SGD", openingBalance: 500)
        let goal = Goal(name: "Trip", target: 1000, currency: "SGD")
        goal.contributions = [GoalContribution(amount: 10, date: .now)]
        let transaction = mise.Transaction(amount: -120, currency: "SGD", date: .now)
        context.insert(account)
        context.insert(goal)
        context.insert(transaction)
        transaction.account = account
        goal.account = account
        try context.save()
        #expect(Goals.saved(goal, rates: FXRates()) == 380)

        context.delete(account)
        try context.save()
        #expect(goal.account == nil)
        #expect(Goals.saved(goal, rates: FXRates()) == 10)
    }
}
