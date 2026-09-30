import Foundation
import SwiftData

/// Daily EUR-based FX rate cache, keyed by "yyyy-MM-dd". Frankfurter (ECB)
/// always quotes EUR base; we store it verbatim and convert cross-rates
/// through EUR at use time.
struct FXRates: Codable, Equatable {
    var days: [String: [String: Decimal]] = [:]

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = formatter
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    /// Exact day if cached, else the nearest earlier cached day, else nil.
    func rates(on day: String) -> [String: Decimal]? {
        if let exact = days[day] { return exact }
        return days.keys.filter { $0 < day }.max().flatMap { days[$0] }
    }

    static func parse(_ data: Data) throws -> [String: Decimal] {
        struct Response: Decodable {
            let rates: [String: Double]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var rates = response.rates.reduce(into: [String: Decimal]()) { result, entry in
            result[entry.key] = Decimal(string: String(entry.value))
        }
        rates["EUR"] = 1
        return rates
    }

    static var url: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("fx-rates.json")
    }

    static func load() -> FXRates {
        guard let data = try? Data(contentsOf: url),
              let rates = try? JSONDecoder().decode(FXRates.self, from: data)
        else { return FXRates() }
        return rates
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

/// Home currency + conversion, backed by the FXRates cache above.
enum FX {
    static let homeKey = "finance.homeCurrency"

    static func home(_ defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: homeKey) ?? Locale.current.currency?.identifier ?? "USD"
    }

    /// Converts via EUR cross-rate. Same currency always succeeds, even with
    /// empty rates. Missing or zero rate for either currency -> nil.
    // ponytail: fixed 2dp rounding; use per-currency minor units if JPY display needs it.
    static func convert(_ amount: Decimal, from: String, to: String, rates: [String: Decimal]) -> Decimal? {
        if from == to { return amount }
        guard let fromRate = rates[from], fromRate != 0,
              let toRate = rates[to]
        else { return nil }
        var result = amount / fromRate * toRate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 2, .plain)
        return rounded
    }

    @MainActor
    static func fill(_ transactions: [Transaction], rates: FXRates, home: String) {
        for transaction in transactions where transaction.homeAmount == nil {
            if transaction.currency == home {
                transaction.homeAmount = transaction.amount
                continue
            }
            guard let dayRates = rates.days[day(transaction.date)] else { continue }
            transaction.homeAmount = convert(
                transaction.amount, from: transaction.currency, to: home, rates: dayRates
            )
        }
    }

    private static func day(_ date: Date) -> String { FXRates.day(date) }

    private static let base = "https://api.frankfurter.dev/v1"

    static func fetch(_ day: String?) async throws -> (day: String, rates: [String: Decimal]) {
        let url = URL(string: day.map { "\(base)/\($0)" } ?? "\(base)/latest")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let returnedDay = try parseDate(data)
        let rates = try FXRates.parse(data)
        return (returnedDay, rates)
    }

    private static func parseDate(_ data: Data) throws -> String {
        struct Response: Decodable { let date: String }
        return try JSONDecoder().decode(Response.self, from: data).date
    }

    /// Only networked entry point. Offline/errors are swallowed — the cache
    /// simply doesn't advance and we retry next call.
    @MainActor
    static func refresh(context: ModelContext, now: Date = .now) async {
        var cache = FXRates.load()
        let today = day(now)

        // ponytail: before ECB publishes (~16:00 CET) today's key holds
        // yesterday's rates; a later refresh the same day won't re-fetch.
        if cache.days[today] == nil {
            guard let latest = try? await fetch(nil) else { return }
            cache.days[latest.day] = latest.rates
            cache.days[today] = latest.rates
        }

        let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.homeAmount == nil })
        guard let pending = try? context.fetch(descriptor) else {
            cache.save()
            return
        }

        let missingDays = Set(pending.map { day($0.date) })
            .filter { cache.days[$0] == nil && $0 <= today }
            .sorted()

        // ponytail: cap fetches per run; a backlog beyond this catches up on later runs.
        for requestedDay in missingDays.prefix(30) {
            guard let fetched = try? await fetch(requestedDay) else { break }
            cache.days[requestedDay] = fetched.rates
            cache.days[fetched.day] = fetched.rates
        }

        cache.save()
        fill(pending, rates: cache, home: home())
        try? context.save()
    }

    @MainActor
    static func rebase(context: ModelContext) async {
        if let all = try? context.fetch(FetchDescriptor<Transaction>()) {
            for transaction in all { transaction.homeAmount = nil }
        }
        await refresh(context: context)
    }
}
