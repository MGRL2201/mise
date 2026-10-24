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
            accounts.map { (Finance.balance(of: $0, rates: rates), $0.currency) },
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
}
