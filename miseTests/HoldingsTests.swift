import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct HoldingsTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let start = Date(timeIntervalSince1970: 1_000_000)

    func holding(_ quantity: Decimal, price: Decimal?, cost: Decimal = 0, currency: String = "USD") -> Holding {
        let holding = Holding(symbol: "X", name: "X", kind: .stock, quantity: quantity, costBasis: cost, currency: currency)
        holding.price = price
        return holding
    }

    @Test func valueRoundsTo2dpAndGainSubtractsCost() {
        let btc = holding(Decimal(string: "0.12345678")!, price: Decimal(string: "68250.5")!, cost: 8000)
        #expect(Holdings.value(btc) == Decimal(string: "8425.99"))
        #expect(Holdings.gain(btc) == Decimal(string: "425.99"))
    }

    @Test func noPriceMeansNoValueOrGain() {
        let unpriced = holding(5, price: nil, cost: 100)
        #expect(Holdings.value(unpriced) == nil)
        #expect(Holdings.gain(unpriced) == nil)
    }

    @Test func summaryConvertsToHomeCountsUnpricedAndKeepsUnconverted() {
        var rates = FXRates()
        rates.days[FXRates.day(start)] = ["EUR": 1, "USD": 2, "SGD": 4]
        let result = Holdings.summary([
            holding(10, price: 15, cost: 100),                  // 150 USD, gain 50 USD
            holding(1, price: 1000, cost: 900, currency: "JPY"), // no rate
            holding(3, price: nil, cost: 30),
        ], rates: rates, home: "SGD", today: start)
        #expect(result.value == 300)
        #expect(result.gain == 100)
        #expect(result.unpriced == 1)
        #expect(result.unconverted == ["JPY": 1000])
    }

    @Test func worthIsBalancesPlusPricedHoldings() {
        let broker = Account(name: "IBKR", type: .brokerage, currency: "USD", openingBalance: 50)
        let cash = Account(name: "Cash", type: .cash, currency: "SGD", openingBalance: 100)
        context.insert(broker)
        context.insert(cash)
        let priced = holding(2, price: 40, currency: "USD")
        let unpriced = holding(9, price: nil)
        context.insert(priced)
        context.insert(unpriced)
        priced.account = broker
        unpriced.account = broker

        let worth = Holdings.worth([broker, cash], rates: FXRates())
        #expect(worth.map(\.amount) == [50, 80, 100])
        #expect(worth.map(\.currency) == ["USD", "USD", "SGD"])
    }
}
