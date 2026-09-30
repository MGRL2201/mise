import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct FXTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }

    @discardableResult
    func transaction(_ amount: Decimal, currency: String, date: Date, homeAmount: Decimal? = nil) -> mise.Transaction {
        let transaction = mise.Transaction(amount: amount, currency: currency, date: date)
        transaction.homeAmount = homeAmount
        context.insert(transaction)
        return transaction
    }

    // MARK: - convert

    @Test func convertSameCurrencyWithEmptyRatesReturnsAmount() {
        #expect(FX.convert(100, from: "USD", to: "USD", rates: [:]) == 100)
    }

    @Test func convertCrossRateViaEUR() {
        let rates: [String: Decimal] = ["EUR": 1, "SGD": Decimal(string: "1.4503")!, "USD": Decimal(string: "1.1")!]
        #expect(FX.convert(100, from: "USD", to: "SGD", rates: rates) == Decimal(string: "131.85")!)
        #expect(FX.convert(Decimal(string: "1.4503")!, from: "SGD", to: "EUR", rates: rates) == 1)
        #expect(FX.convert(10, from: "EUR", to: "SGD", rates: rates) == Decimal(string: "14.50")!)
    }

    @Test func convertMissingRateReturnsNil() {
        let rates: [String: Decimal] = ["EUR": 1, "USD": Decimal(string: "1.1")!]
        #expect(FX.convert(100, from: "USD", to: "VND", rates: rates) == nil)
    }

    // MARK: - parse

    @Test func parseDecodesExactDecimalsAndDate() throws {
        let json = """
        {"amount":1.0,"base":"EUR","date":"2024-01-05","rates":{"SGD":1.4503,"USD":1.0945}}
        """
        let data = Data(json.utf8)
        let rates = try FXRates.parse(data)
        #expect(rates["SGD"] == Decimal(string: "1.4503")!)
        #expect(rates["USD"] == Decimal(string: "1.0945")!)
        #expect(rates["EUR"] == 1)

        struct DateOnly: Decodable { let date: String }
        let date = try JSONDecoder().decode(DateOnly.self, from: data).date
        #expect(date == "2024-01-05")
    }

    // MARK: - rates(on:)

    @Test func ratesOnExactDayReturnsThatDay() {
        var cache = FXRates()
        cache.days["2024-01-05"] = ["EUR": 1]
        cache.days["2024-01-08"] = ["EUR": 2]
        #expect(cache.rates(on: "2024-01-08") == ["EUR": 2])
    }

    @Test func ratesOnNearestEarlierDay() {
        var cache = FXRates()
        cache.days["2024-01-05"] = ["EUR": 1]
        #expect(cache.rates(on: "2024-01-08") == ["EUR": 1])
    }

    @Test func ratesOnNoneEarlierReturnsNil() {
        var cache = FXRates()
        cache.days["2024-01-08"] = ["EUR": 1]
        #expect(cache.rates(on: "2024-01-05") == nil)
    }

    // MARK: - day(_:)

    @Test func dayFormatsInFixedCalendar() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_704_499_200) // 2024-01-06 00:00:00 UTC
        #expect(FXRates.day(date, calendar: utc) == "2024-01-06")
    }

    // MARK: - fill

    @Test func fillUsesExactDayOnlyAndSkipsAlreadyFilled() {
        let cachedDay = Date(timeIntervalSince1970: 1_704_499_200) // 2024-01-06
        let uncachedDay = cachedDay.addingTimeInterval(86_400 * 5) // only earlier day cached
        var cache = FXRates()
        cache.days[FXRates.day(cachedDay)] = ["EUR": 1, "USD": Decimal(string: "1.1")!]

        let onCachedDay = transaction(110, currency: "USD", date: cachedDay)
        let onUncachedDay = transaction(110, currency: "USD", date: uncachedDay)
        let sameCurrency = transaction(50, currency: "EUR", date: cachedDay)
        let alreadyFilled = transaction(200, currency: "USD", date: cachedDay, homeAmount: 999)

        FX.fill([onCachedDay, onUncachedDay, sameCurrency, alreadyFilled], rates: cache, home: "EUR")

        #expect(onCachedDay.homeAmount == 100)
        #expect(onUncachedDay.homeAmount == nil)
        #expect(sameCurrency.homeAmount == 50)
        #expect(alreadyFilled.homeAmount == 999)
    }
}
