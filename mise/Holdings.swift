import Foundation
import SwiftData

// Investment holdings (#48). Same model rules as Finance.swift.

enum HoldingKind: String, Codable, CaseIterable {
    case stock, crypto, fund

    var label: String {
        switch self {
        case .stock: "Stock/ETF"
        case .crypto: "Crypto"
        case .fund: "Fund/Retirement"
        }
    }
}

/// A position inside an account (usually brokerage). Funds valued as a whole
/// use quantity 1 and price = total value.
@Model
final class Holding {
    var id: UUID = UUID()
    var account: Account?
    var kind: HoldingKind = HoldingKind.stock
    var symbol: String = ""
    var name: String = ""
    var quantity: Decimal = 0
    /// Total cost of the position, in `currency`.
    var costBasis: Decimal = 0
    var currency: String = ""
    /// Per-unit price in `currency`, and when it was taken. Set by manual entry;
    /// price fetchers (#49 CoinGecko, #50 stocks) write the same two fields.
    var price: Decimal?
    var priceDate: Date?
    /// CoinGecko coin id (#49). Set => price is auto-fetched and overwrites the manual price.
    var coinID: String?
    var createdAt: Date = Date()

    init(symbol: String, name: String, kind: HoldingKind, quantity: Decimal, costBasis: Decimal, currency: String) {
        self.symbol = symbol
        self.name = name
        self.kind = kind
        self.quantity = quantity
        self.costBasis = costBasis
        self.currency = currency
    }
}

enum Holdings {
    /// quantity × price, rounded to 2dp like FX.convert; nil without a price.
    static func value(_ holding: Holding) -> Decimal? {
        guard let price = holding.price else { return nil }
        var result = holding.quantity * price
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 2, .plain)
        return rounded
    }

    static func gain(_ holding: Holding) -> Decimal? {
        value(holding).map { $0 - holding.costBasis }
    }

    /// Home-currency totals at today's rates. Unpriced holdings are only counted;
    /// priced ones with no rate go to `unconverted` (value in their currency) and are excluded.
    static func summary(_ holdings: [Holding], rates: FXRates, home: String, today: Date = .now)
        -> (value: Decimal, gain: Decimal, unpriced: Int, unconverted: [String: Decimal]) {
        let dayRates = rates.rates(on: FXRates.day(today)) ?? [:]
        var total = Decimal(0), totalGain = Decimal(0), unpriced = 0
        var unconverted: [String: Decimal] = [:]
        for holding in holdings {
            guard let value = value(holding), let gain = gain(holding) else { unpriced += 1; continue }
            // ponytail: cost basis converted at today's rate, so FX gain/loss isn't separated;
            // store cost in home currency at buy date if that split matters.
            guard let homeValue = FX.convert(value, from: holding.currency, to: home, rates: dayRates),
                  let homeGain = FX.convert(gain, from: holding.currency, to: home, rates: dayRates)
            else { unconverted[holding.currency, default: 0] += value; continue }
            total += homeValue
            totalGain += homeGain
        }
        return (total, totalGain, unpriced, unconverted)
    }

    /// Net-worth inputs: each account's balance plus each priced holding's value, in their own currencies.
    static func worth(_ accounts: [Account], rates: FXRates) -> [(amount: Decimal, currency: String)] {
        accounts.flatMap { account in
            [(Finance.balance(of: account, rates: rates), account.currency)]
                + (account.holdings ?? []).compactMap { holding in value(holding).map { ($0, holding.currency) } }
        }
    }
}
