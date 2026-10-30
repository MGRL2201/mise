import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct CoinGeckoTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }

    func holding(_ coinID: String?, currency: String = "USD", price: Decimal? = nil) -> Holding {
        let holding = Holding(symbol: "X", name: "X", kind: .crypto, quantity: 1, costBasis: 0, currency: currency)
        holding.coinID = coinID
        holding.price = price
        context.insert(holding)
        return holding
    }

    @Test func parseSearchKeepsOrder() throws {
        let json = """
        {"coins":[{"id":"bitcoin","name":"Bitcoin","symbol":"BTC","market_cap_rank":1,"thumb":"x"},
                  {"id":"wrapped-bitcoin","name":"Wrapped Bitcoin","symbol":"WBTC","market_cap_rank":null}],
         "exchanges":[],"categories":[]}
        """
        let coins = try CoinGecko.parseSearch(Data(json.utf8))
        #expect(coins == [Coin(id: "bitcoin", symbol: "BTC", name: "Bitcoin"),
                          Coin(id: "wrapped-bitcoin", symbol: "WBTC", name: "Wrapped Bitcoin")])
    }

    @Test func parsePricesKeepsLastUpdated() throws {
        let json = """
        {"bitcoin":{"usd":68250.12,"sgd":92000.5,"last_updated_at":1730000000},
         "ethereum":{"usd":2500,"last_updated_at":1730000100}}
        """
        let prices = try CoinGecko.parsePrices(Data(json.utf8))
        #expect(prices["bitcoin"] == ["usd": Decimal(string: "68250.12")!, "sgd": Decimal(string: "92000.5")!,
                                      "last_updated_at": 1_730_000_000])
        #expect(prices["ethereum"] == ["usd": 2500, "last_updated_at": 1_730_000_100])
    }

    @Test func parsePricesDropsNulls() throws {
        let json = """
        {"bitcoin":{"usd":null,"sgd":92000.5,"last_updated_at":1730000000},
         "ethereum":{"usd":2500}}
        """
        let prices = try CoinGecko.parsePrices(Data(json.utf8))
        #expect(prices["bitcoin"] == ["sgd": Decimal(string: "92000.5")!, "last_updated_at": 1_730_000_000])
        #expect(prices["ethereum"] == ["usd": 2500])
    }

    @Test func applySetsPricesAndSkipsUnknown() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let prices = CoinPrices(fetchedAt: fetchedAt, coins: [
            "bitcoin": ["usd": 68250, "sgd": 92000, "last_updated_at": 1_730_000_000],
            "pepe": ["usd": Decimal(string: "0.00001234")!],
        ])
        let usd = holding("bitcoin")
        let sgd = holding("bitcoin", currency: "SGD")
        let chf = holding("pepe", currency: "CHF")
        let unknown = holding("dogecoin", price: 5)
        let manual = holding(nil, price: 7)

        CoinGecko.apply(prices, to: [usd, sgd, chf, unknown, manual], rates: ["EUR": 1, "USD": 2, "CHF": 3])

        #expect(usd.price == 68250 && usd.priceDate == Date(timeIntervalSince1970: 1_730_000_000))
        #expect(sgd.price == 92000)
        #expect(chf.price == Decimal(string: "0.00001851") && chf.priceDate == fetchedAt)
        #expect(unknown.price == 5 && unknown.priceDate == nil)
        #expect(manual.price == 7 && manual.priceDate == nil)
    }

    @Test func applyKeepsNewerManualPrice() {
        let prices = CoinPrices(fetchedAt: .now, coins: ["bitcoin": ["usd": 68250, "last_updated_at": 1_730_000_000]])
        let btc = holding("bitcoin", price: 70000)
        let manualDate = Date(timeIntervalSince1970: 1_730_000_500)
        btc.priceDate = manualDate
        CoinGecko.apply(prices, to: [btc], rates: [:])
        #expect(btc.price == 70000 && btc.priceDate == manualDate)
    }

    @Test func applySkipsMissingRate() {
        let prices = CoinPrices(fetchedAt: .now, coins: ["bitcoin": ["usd": 68250]])
        let jpy = holding("bitcoin", currency: "JPY", price: 1)
        CoinGecko.apply(prices, to: [jpy], rates: ["EUR": 1, "USD": 2])
        #expect(jpy.price == 1)
    }
}
