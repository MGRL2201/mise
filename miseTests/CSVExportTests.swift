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
}
