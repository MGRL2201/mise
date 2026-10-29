import Foundation
import SwiftData

// Crypto prices via CoinGecko's free, keyless API (#49). Same pattern as FX.swift.

struct Coin: Decodable, Identifiable, Equatable {
    let id: String
    let symbol: String
    let name: String
}

/// Cached simple/price quotes: coin id -> lowercase currency -> per-unit price,
/// plus "last_updated_at" (unix seconds) in the same dict, as CoinGecko returns it.
struct CoinPrices: Codable, Equatable {
    var fetchedAt: Date?
    var coins: [String: [String: Decimal]] = [:]

    static var url: URL {
        // Seeded sample data (Storage.inMemory) must never write the real cache.
        let root = Storage.inMemory ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("coingecko-prices.json")
    }

    static func load() -> CoinPrices {
        guard let data = try? Data(contentsOf: url),
              let prices = try? JSONDecoder().decode(CoinPrices.self, from: data)
        else { return CoinPrices() }
        return prices
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}

enum CoinGecko {
    static let base = "https://api.coingecko.com/api/v3"

    static func parseSearch(_ data: Data) throws -> [Coin] {
        struct Response: Decodable { let coins: [Coin] }
        return try JSONDecoder().decode(Response.self, from: data).coins
    }

    static func search(_ query: String) async throws -> [Coin] {
        var components = URLComponents(string: "\(base)/search")
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        return Array(try parseSearch(try await get(components?.url)).prefix(10))
    }

    static func parsePrices(_ data: Data) throws -> [String: [String: Decimal]] {
        try JSONDecoder().decode([String: [String: Double]].self, from: data).mapValues { quote in
            quote.reduce(into: [String: Decimal]()) { result, entry in
                result[entry.key] = Decimal(string: String(entry.value))
            }
        }
    }

    private static func get(_ url: URL?) async throws -> Data {
        guard let url else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Writes cached quotes into holdings with a coinID. Holding currency missing
    /// from the quote -> USD quote via EUR cross-rate, unrounded (2dp would zero cheap coins).
    /// Returns whether any holding changed.
    @MainActor
    static func apply(_ prices: CoinPrices, to holdings: [Holding], rates: [String: Decimal]) -> Bool {
        var changed = false
        for holding in holdings {
            guard let id = holding.coinID, let quote = prices.coins[id] else { continue }
            var price = quote[holding.currency.lowercased()]
            if price == nil, let usd = quote["usd"],
               let usdRate = rates["USD"], usdRate != 0,
               let toRate = rates[holding.currency], toRate != 0 {
                price = usd / usdRate * toRate
            }
            guard let price else { continue }
            let date = quote["last_updated_at"].map { Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue) }
                ?? prices.fetchedAt ?? .now
            if holding.price != price { holding.price = price; changed = true }
            if holding.priceDate != date { holding.priceDate = date; changed = true }
        }
        return changed
    }

    /// Networked entry point. Errors are swallowed; offline keeps using the cache.
    /// Callers run FX.refresh afterwards (it records the net-worth snapshot).
    @MainActor
    static func refresh(context: ModelContext, now: Date = .now) async {
        let holdings = ((try? context.fetch(FetchDescriptor<Holding>())) ?? [])
            .filter { $0.kind == .crypto && $0.coinID != nil }
        guard !holdings.isEmpty else { return }
        var cache = CoinPrices.load()
        let ids = Set(holdings.compactMap(\.coinID)).sorted()

        // ponytail: free tier rate limit, ~10 min throttle; a coin id CoinGecko
        // doesn't know stays missing and re-triggers a fetch each app-active.
        let stale = cache.fetchedAt.map { now.timeIntervalSince($0) > 600 } ?? true
        if stale || ids.contains(where: { cache.coins[$0] == nil }) {
            let currencies = Set(holdings.map { $0.currency.lowercased() } + ["usd"]).sorted()
            var components = URLComponents(string: "\(base)/simple/price")
            components?.queryItems = [
                URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
                URLQueryItem(name: "vs_currencies", value: currencies.joined(separator: ",")),
                URLQueryItem(name: "include_last_updated_at", value: "true"),
            ]
            if let data = try? await get(components?.url), let fetched = try? parsePrices(data) {
                cache.coins.merge(fetched) { _, new in new }
                cache.fetchedAt = now
                cache.save()
            }
        }

        let rates = FXRates.load().rates(on: FXRates.day(now)) ?? [:]
        if apply(cache, to: holdings, rates: rates) { try? context.save() }
    }
}
