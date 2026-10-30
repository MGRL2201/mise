import Foundation
import SwiftData
#if os(iOS)
import BackgroundTasks
#endif

// Stock/ETF prices via Finnhub or Alpha Vantage, user-supplied free key (#50).
// Same pattern as CoinGecko.swift, but one request per symbol under a rate budget.

enum StockProvider: String, CaseIterable {
    case finnhub, alphaVantage

    static let key = "finance.stockProvider"

    static func current(_ defaults: UserDefaults = .standard) -> StockProvider {
        defaults.string(forKey: key).flatMap(StockProvider.init(rawValue:)) ?? .finnhub
    }

    var label: String {
        switch self {
        case .finnhub: "Finnhub"
        case .alphaVantage: "Alpha Vantage"
        }
    }

    var keyURL: URL {
        switch self {
        case .finnhub: URL(string: "https://finnhub.io/register")!
        case .alphaVantage: URL(string: "https://www.alphavantage.co/support/#api-key")!
        }
    }

    /// Requests per refresh run (Finnhub free: 60/min).
    // ponytail: caps one run only, two runs inside a minute can pass 60/min and hit 429
    // (the stop path recovers); add a per-minute call window if that shows up in practice.
    var perRun: Int {
        switch self {
        case .finnhub: 50
        case .alphaVantage: 20
        }
    }

    /// Requests per rolling 24 h, nil = no daily cap.
    var perDay: Int? {
        switch self {
        case .finnhub: nil
        case .alphaVantage: 25
        }
    }

    func url(symbol: String, key: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .finnhub:
            components = URLComponents(string: "https://finnhub.io/api/v1/quote")
            components?.queryItems = [URLQueryItem(name: "symbol", value: symbol), URLQueryItem(name: "token", value: key)]
        case .alphaVantage:
            components = URLComponents(string: "https://www.alphavantage.co/query")
            components?.queryItems = [
                URLQueryItem(name: "function", value: "GLOBAL_QUOTE"),
                URLQueryItem(name: "symbol", value: symbol),
                URLQueryItem(name: "apikey", value: key),
            ]
        }
        return components?.url
    }

    /// nil = skip this symbol; throws `StockError.stop` = stop the whole run (limit / bad key).
    /// Stop messages have `key` redacted: AV echoes it ("We have detected your API key as ...").
    func parse(_ data: Data, status: Int, now: Date, key: String) throws -> StockQuotes.Quote? {
        func stop(_ message: String) -> StockError {
            .stop(key.isEmpty ? message : message.replacingOccurrences(of: key, with: "•••"))
        }
        switch self {
        case .finnhub:
            struct Response: Decodable { let c: Double?; let t: Double?; let error: String? }
            let response = try? JSONDecoder().decode(Response.self, from: data)
            if status == 401 || status == 429 { throw stop(response?.error ?? "HTTP \(status)") }
            // Other non-200s (403 = no access, e.g. non-US tickers on the free tier) skip the symbol.
            guard status == 200, let c = response?.c, let price = Decimal(string: String(c)), price > 0 else { return nil }
            let t = response?.t ?? 0
            return StockQuotes.Quote(price: price, date: t > 0 ? Date(timeIntervalSince1970: t) : now)
        case .alphaVantage:
            struct Response: Decodable {
                let note: String?, information: String?, quote: [String: String]?
                enum CodingKeys: String, CodingKey {
                    case note = "Note", information = "Information", quote = "Global Quote"
                }
            }
            let response = try? JSONDecoder().decode(Response.self, from: data)
            if let message = response?.note ?? response?.information { throw stop(message) }
            // AV gives only a trading day, so the fetch time is the quote date.
            guard let text = response?.quote?["05. price"], let price = Decimal(string: text), price > 0 else { return nil }
            return StockQuotes.Quote(price: price, date: now)
        }
    }
}

enum StockError: Error {
    case stop(String)
}

/// Cached quotes plus the request log the rate budget is computed from.
struct StockQuotes: Codable, Equatable {
    struct Quote: Codable, Equatable {
        var price: Decimal
        var date: Date
    }

    /// Keyed by uppercased symbol.
    var quotes: [String: Quote] = [:]
    /// Last request per symbol, success or skip.
    var attempts: [String: Date] = [:]
    /// Request times, for daily-capped providers.
    var calls: [Date] = []
    /// Last run that got server responses without a stop.
    var fetchedAt: Date?
    var lastError: String?

    static let interval: TimeInterval = 4 * 3600

    static var url: URL {
        // Seeded sample data (Storage.inMemory) must never write the real cache.
        let root = Storage.inMemory ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("stock-prices.json")
    }

    static func load() -> StockQuotes {
        guard let data = try? Data(contentsOf: url),
              let quotes = try? JSONDecoder().decode(StockQuotes.self, from: data)
        else { return StockQuotes() }
        return quotes
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Symbols to request now: never attempted first, then oldest attempt,
    /// capped by the provider's per-run and remaining daily budget.
    func due(_ symbols: [String], provider: StockProvider, now: Date) -> [String] {
        var cap = provider.perRun
        if let perDay = provider.perDay {
            cap = min(cap, max(0, perDay - calls.filter { now.timeIntervalSince($0) < 86_400 }.count))
        }
        return Array(symbols
            .filter { attempts[$0].map { now.timeIntervalSince($0) >= Self.interval } ?? true }
            .sorted { (attempts[$0] ?? .distantPast, $0) < (attempts[$1] ?? .distantPast, $1) }
            .prefix(cap))
    }
}

enum Stocks {
    static let taskID = "\(Bundle.main.bundleIdentifier ?? "mise").stockprices"
    private static var running = false

    static func symbol(of holding: Holding) -> String? {
        guard holding.kind == .stock else { return nil }
        let symbol = holding.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return symbol.isEmpty ? nil : symbol
    }

    /// Writes cached quotes into .stock holdings by symbol. The quote is taken as the
    /// holding's currency: providers don't return currency reliably.
    /// Skips holdings deleted during the fetch and prices newer than the quote (manual edits).
    // ponytail: currency assumed, a LSE ticker quoted in GBX lands as-is; check the
    // provider's profile endpoint if mixed-currency listings matter.
    static func apply(_ quotes: StockQuotes, to holdings: [Holding]) {
        for holding in holdings {
            guard !holding.isDeleted, holding.modelContext != nil,
                  let symbol = symbol(of: holding), let quote = quotes.quotes[symbol] else { continue }
            if let current = holding.priceDate, current > quote.date { continue }
            holding.price = quote.price
            holding.priceDate = quote.date
        }
    }

    /// Networked entry point. Offline / limit errors land in `lastError`; the cache keeps serving.
    /// Callers run FX.refresh afterwards (it records the net-worth snapshot).
    static func refresh(context: ModelContext, now: Date = .now) async {
        guard let key = apiKey(), !running else { return }
        running = true
        defer { running = false }

        let holdings = ((try? context.fetch(FetchDescriptor<Holding>())) ?? []).filter { symbol(of: $0) != nil }
        guard !holdings.isEmpty else { return }
        let provider = StockProvider.current()
        var cache = StockQuotes.load()
        cache.calls.removeAll { now.timeIntervalSince($0) >= 86_400 }

        // ponytail: sequential requests, a few seconds per run at 50 symbols; fine for a household portfolio.
        var requested = false, failed = false
        for (index, symbol) in cache.due(Set(holdings.compactMap(symbol(of:))).sorted(), provider: provider, now: now).enumerated() {
            if provider == .alphaVantage, index > 0 { try? await Task.sleep(for: .seconds(1.2)) } // free tier burst limit
            guard let url = provider.url(symbol: symbol, key: key) else { continue }
            let data: Data, response: URLResponse
            do { (data, response) = try await URLSession.shared.data(from: url) } catch {
                cache.lastError = error.localizedDescription
                failed = true
                break
            }
            requested = true
            if provider.perDay != nil { cache.calls.append(now) }
            do {
                if let quote = try provider.parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, now: now, key: key) {
                    cache.quotes[symbol] = quote
                }
            } catch StockError.stop(let message) {
                cache.lastError = message
                failed = true
                break // no attempt recorded: the symbol stays due for the next run
            } catch {}
            cache.attempts[symbol] = now
        }
        if requested, !failed {
            cache.fetchedAt = now
            cache.lastError = nil
        }
        if requested || failed { cache.save() }

        apply(cache, to: holdings)
        try? context.save()
    }

    /// Trimmed stored key, nil when missing or blank.
    private static func apiKey() -> String? {
        let key = Keychain.get(Keychain.stockAPIKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    #if os(iOS)
    static func scheduleRefresh() {
        guard !Storage.inMemory, apiKey() != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = .now.addingTimeInterval(StockQuotes.interval)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
