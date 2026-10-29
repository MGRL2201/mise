import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct CSVExportTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }
    let plus2 = TimeZone(secondsFromGMT: 7200)!

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int, minute: Int = 0, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func fieldEscaping() {
        #expect(CSVExport.field("plain") == "plain")
        #expect(CSVExport.field("a,b") == "\"a,b\"")
        #expect(CSVExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExport.field("line1\nline2") == "\"line1\nline2\"")
        #expect(CSVExport.field("a\rb") == "\"a\rb\"")
        #expect(CSVExport.field("a\r\nb") == "\"a\r\nb\"")
        #expect(CSVExport.field("") == "")
    }

    @Test func encodeWritesBOMAndCRLFRecords() {
        let data = CSVExport.encode([["a", "b,c", ""], ["1", "", ""]])
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(text(data) == "\u{FEFF}a,\"b,c\",\r\n1,,\r\n")
    }

    @Test func encodeKeepsNonASCII() {
        let s = text(CSVExport.encode([["Café Zürich 東京"]]))
        #expect(s == "\u{FEFF}Café Zürich 東京\r\n")
    }

    @Test func rowsMapTransactionFields() {
        let visa = Account(name: "Visa", type: .credit, currency: "EUR")
        let food = mise.Category(name: "Food")
        context.insert(visa)
        context.insert(food)
        let t = mise.Transaction(amount: Decimal(string: "-1234.5")!, currency: "USD",
                                 date: date(2026, 3, 5, hour: 23, minute: 30, in: plus2))
        t.account = visa
        t.category = food
        t.merchant = "Joe's \"Diner\", NYC"
        t.accountAmount = Decimal(string: "-1100.25")!
        t.notes = "a\nb"
        t.source = .applePay
        let bare = mise.Transaction(amount: Decimal(string: "1234567.89")!, currency: "EUR",
                                    date: date(2026, 3, 6, hour: 12, in: plus2))
        context.insert(t)
        context.insert(bare)

        let rows = CSVExport.rows([t, bare], homeCurrency: "EUR", timeZone: plus2)
        #expect(rows.count == 3)
        #expect(rows[0].joined(separator: ",") == "date,account,merchant,category,amount,currency,account_amount,home_amount,home_currency,notes,source")
        #expect(rows[1] == ["2026-03-05", "Visa", "Joe's \"Diner\", NYC", "Food", "-1234.5", "USD",
                            "-1100.25", "", "EUR", "a\nb", "applePay"])
        #expect(rows[2] == ["2026-03-06", "", "", "", "1234567.89", "EUR", "", "", "EUR", "", "manual"])
    }

    @Test func filenameUsesLocalDate() {
        #expect(CSVExport.filename(now: date(2026, 3, 5, hour: 23, minute: 30, in: plus2), timeZone: plus2)
                == "mise-transactions-2026-03-05.csv")
    }

    @Test func holdingRowsMapFieldsAndConvertToHome() {
        let broker = Account(name: "IBKR", type: .brokerage, currency: "USD")
        context.insert(broker)
        let today = date(2026, 3, 5, hour: 12, in: plus2)
        let rates = FXRates(days: [FXRates.day(today): ["EUR": 1, "USD": Decimal(string: "1.1")!, "SGD": Decimal(string: "1.5")!]])
        let apple = Holding(symbol: "AAPL", name: "Apple, Inc.", kind: .stock, quantity: 10, costBasis: 1600, currency: "USD")
        apple.price = Decimal(string: "150.25")!
        apple.priceDate = date(2026, 3, 4, hour: 0, minute: 30, in: plus2)  // UTC: 3 Mar
        let btc = Holding(symbol: "BTC", name: "Bitcoin", kind: .crypto, quantity: Decimal(string: "0.5")!, costBasis: 20000, currency: "USD")
        let gbp = Holding(symbol: "VUSA", name: "S&P", kind: .fund, quantity: 2, costBasis: 100, currency: "GBP")
        gbp.price = 60
        [apple, btc, gbp].forEach(context.insert)
        apple.account = broker

        let rows = CSVExport.holdingRows([apple, btc, gbp], rates: rates, homeCurrency: "SGD", today: today, timeZone: plus2)
        #expect(rows.count == 4)
        #expect(rows[0].joined(separator: ",") == "account,kind,symbol,name,quantity,cost_basis,currency,price,price_date,value,gain_loss,home_value,home_currency")
        #expect(rows[1] == ["IBKR", "stock", "AAPL", "Apple, Inc.", "10", "1600", "USD", "150.25", "2026-03-04",
                            "1502.5", "-97.5", "2048.86", "SGD"])
        #expect(rows[2] == ["", "crypto", "BTC", "Bitcoin", "0.5", "20000", "USD", "", "", "", "", "", "SGD"])
        #expect(rows[3] == ["", "fund", "VUSA", "S&P", "2", "100", "GBP", "60", "", "120", "20", "", "SGD"])
        #expect(text(CSVExport.encode(rows)).contains("\r\nIBKR,stock,AAPL,\"Apple, Inc.\",10,"))
    }

    @Test func holdingsFilename() {
        #expect(CSVExport.filename("holdings", now: date(2026, 3, 5, hour: 23, minute: 30, in: plus2), timeZone: plus2)
                == "mise-holdings-2026-03-05.csv")
    }
}
