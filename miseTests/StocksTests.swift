import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct StocksTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func holding(_ symbol: String, kind: HoldingKind = .stock, price: Decimal? = nil) -> Holding {
        let holding = Holding(symbol: symbol, name: symbol, kind: kind, quantity: 1, costBasis: 0, currency: "USD")
        holding.price = price
        context.insert(holding)
        return holding
    }

    func parse(_ provider: StockProvider, _ json: String, status: Int = 200) throws -> StockQuotes.Quote? {
        try provider.parse(Data(json.utf8), status: status, now: now)
    }

    func stopMessage(_ provider: StockProvider, _ json: String, status: Int = 200) -> String? {
        do { _ = try parse(provider, json, status: status) } catch StockError.stop(let message) { return message } catch {}
        return nil
    }

    // MARK: Finnhub

    @Test func finnhubQuote() throws {
        let json = #"{"c":189.5,"d":1,"dp":0.5,"h":190,"l":188,"o":189,"pc":188.5,"t":1730000000}"#
        let quote = try parse(.finnhub, json)
        #expect(quote == StockQuotes.Quote(price: Decimal(string: "189.5")!, date: Date(timeIntervalSince1970: 1_730_000_000)))
    }

    @Test func finnhubUnknownSymbolIsNil() throws {
        #expect(try parse(.finnhub, #"{"c":0,"d":null,"dp":null,"h":0,"l":0,"o":0,"pc":0,"t":0}"#) == nil)
    }

    @Test func finnhubLimitStops() {
        #expect(stopMessage(.finnhub, #"{"error":"API limit reached. Please try again later."}"#, status: 429)
            == "API limit reached. Please try again later.")
    }

    @Test func finnhubBadKeyStops() {
        #expect(stopMessage(.finnhub, "", status: 401) == "HTTP 401")
    }

    @Test func finnhubNoAccessIsNil() throws {
        #expect(try parse(.finnhub, #"{"error":"You don't have access to this resource."}"#, status: 403) == nil)
    }

    // MARK: Alpha Vantage

    @Test func alphaVantageQuote() throws {
        let json = """
        {"Global Quote": {"01. symbol": "IBM", "02. open": "188.0000", "03. high": "190.0000",
         "04. low": "187.5000", "05. price": "189.1400", "06. volume": "3000000",
         "07. latest trading day": "2026-10-29", "08. previous close": "188.0000",
         "09. change": "1.1400", "10. change percent": "0.6064%"}}
        """
        #expect(try parse(.alphaVantage, json) == StockQuotes.Quote(price: Decimal(string: "189.14")!, date: now))
    }

    @Test func alphaVantageEmptyIsNil() throws {
        #expect(try parse(.alphaVantage, #"{"Global Quote": {}}"#) == nil)
        #expect(try parse(.alphaVantage, #"{"Error Message": "Invalid API call."}"#) == nil)
        #expect(try parse(.alphaVantage, #"{"Global Quote": {"05. price": "0.0000"}}"#) == nil)
    }

    @Test func alphaVantageNoteStops() {
        #expect(stopMessage(.alphaVantage, #"{"Note": "Thank you for using Alpha Vantage!"}"#) == "Thank you for using Alpha Vantage!")
        let info = "We have detected your API key as test-key and our standard API rate limit is 25 requests per day."
        #expect(stopMessage(.alphaVantage, #"{"Information": "\#(info)"}"#) == info)
    }

    // MARK: url

    @Test func urls() throws {
        for (provider, host, keyName) in [(StockProvider.finnhub, "finnhub.io", "token"), (.alphaVantage, "www.alphavantage.co", "apikey")] {
            let url = try #require(provider.url(symbol: "VOO", key: "test-key"))
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = components.queryItems ?? []
            #expect(components.host == host)
            #expect(items.contains(URLQueryItem(name: "symbol", value: "VOO")))
            #expect(items.contains(URLQueryItem(name: keyName, value: "test-key")))
        }
    }

    // MARK: apply

    @Test func applySetsStockPricesOnly() {
        let date = Date(timeIntervalSince1970: 1_730_000_000)
        let quotes = StockQuotes(quotes: ["VOO": .init(price: 500, date: date)])
        let voo = holding(" voo ")
        let crypto = holding("VOO", kind: .crypto, price: 1)
        let unknown = holding("ZZZZ", price: 2)
        let manual = holding("VOO", price: 600)
        let manualDate = Date(timeIntervalSince1970: 1_730_000_500)
        manual.priceDate = manualDate

        Stocks.apply(quotes, to: [voo, crypto, unknown, manual])

        #expect(voo.price == 500 && voo.priceDate == date)
        #expect(crypto.price == 1 && crypto.priceDate == nil)
        #expect(unknown.price == 2 && unknown.priceDate == nil)
        #expect(manual.price == 600 && manual.priceDate == manualDate)
    }

    // MARK: due

    @Test func dueOrdersNeverAttemptedFirstThenOldest() {
        let hour: TimeInterval = 3600
        let cache = StockQuotes(attempts: [
            "AAA": now.addingTimeInterval(-5 * hour),
            "BBB": now.addingTimeInterval(-9 * hour),
            "CCC": now.addingTimeInterval(-1 * hour),
        ])
        #expect(cache.due(["AAA", "BBB", "CCC", "ZZZ", "DDD"], provider: .finnhub, now: now) == ["DDD", "ZZZ", "BBB", "AAA"])
    }

    @Test func dueCapsAtPerRun() {
        let symbols = (0..<60).map { "S\($0)" }
        #expect(StockQuotes().due(symbols, provider: .finnhub, now: now).count == 50)
        #expect(StockQuotes().due(symbols, provider: .alphaVantage, now: now).count == 20)
    }

    @Test func dueRespectsDailyBudget() {
        let symbols = (0..<30).map { "S\($0)" }
        let recent = Array(repeating: now.addingTimeInterval(-3600), count: 10)
        let old = Array(repeating: now.addingTimeInterval(-25 * 3600), count: 30)
        #expect(StockQuotes(calls: recent + old).due(symbols, provider: .alphaVantage, now: now).count == 15)
        #expect(StockQuotes(calls: recent + recent + recent).due(symbols, provider: .alphaVantage, now: now).isEmpty)
        #expect(StockQuotes(calls: recent + recent + recent).due(symbols, provider: .finnhub, now: now).count == 30)
    }
}
