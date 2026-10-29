import Testing
import SwiftData
import Foundation
@testable import mise

@MainActor
struct CSVImportTests {
    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    var context: ModelContext { container.mainContext }

    func rows(_ text: String) -> [[String]] { CSVImport.rows(Data(text.utf8)) }
    func ymd(_ date: Date?) -> [Int]? {
        date.map { let c = Calendar.current.dateComponents([.year, .month, .day], from: $0); return [c.year!, c.month!, c.day!] }
    }

    @Test func rowsParseRFC4180() {
        let csv = "\u{FEFF}Date,Description,Amount\r\n"
            + "2026-10-01,\"Shop, Inc\",-5.00\r\n"
            + "2026-10-02,\"Say \"\"hi\"\"\",3\r\n"
            + "2026-10-03,\"line1\r\nline2\",1\r\n"
            + ",,\r\n"
            + "\r\n"
        #expect(rows(csv) == [["Date", "Description", "Amount"],
                              ["2026-10-01", "Shop, Inc", "-5.00"],
                              ["2026-10-02", "Say \"hi\"", "3"],
                              ["2026-10-03", "line1\r\nline2", "1"]])
        #expect(rows("a,b\rc,d\ne,\"\"") == [["a", "b"], ["c", "d"], ["e", ""]])
        #expect(rows("Date,Desc,Amount\n2026-10-01,Monitor 27\" screen,-10.00\n2026-10-02,Coffee,-5.00\n")
                == [["Date", "Desc", "Amount"], ["2026-10-01", "Monitor 27\" screen", "-10.00"], ["2026-10-02", "Coffee", "-5.00"]])
    }

    @Test func rowsDetectDelimiter() {
        #expect(rows("Date;Amount;\"x,y\"\n2026-10-01;1,50;z") == [["Date", "Amount", "x,y"], ["2026-10-01", "1,50", "z"]])
        #expect(rows("a\tb\tc,d\n1\t2\t3") == [["a", "b", "c,d"], ["1", "2", "3"]])
    }

    @Test func rowsFallBackToWindows1252() {
        #expect(CSVImport.rows(Data([0x43, 0x61, 0x66, 0xE9, 0x2C, 0x31])) == [["Café", "1"]])
    }

    @Test func amountParsing() {
        func a(_ s: String, _ comma: Bool = false) -> Decimal? { CSVImport.amount(s, decimalComma: comma) }
        #expect(a("1,234.56") == Decimal(string: "1234.56"))
        #expect(a("1.234,56", true) == Decimal(string: "1234.56"))
        #expect(a("(12.50)") == Decimal(string: "-12.50"))
        #expect(a("12.50-") == Decimal(string: "-12.50"))
        #expect(a("S$ -7.40") == Decimal(string: "-7.40"))
        #expect(a("−3,00", true) == -3)
        #expect(a("1\u{202F}234,5 EUR", true) == Decimal(string: "1234.5"))
        #expect(a("1'234.00 €") == 1234)
        #expect(a("+8") == 8)
        #expect(a("") == nil)
        #expect(a("abc") == nil)
        #expect(a("1.2.3") == nil)
        #expect(a("12*3") == nil)
        #expect(a("100.00 DR") == -100)
        #expect(a("100.00 CR") == 100)
        #expect(a("SGD 7.00") == 7)
        #expect(a("12,50 €", true) == Decimal(string: "12.5"))
        for junk in ["12abc34", "Ref 123", "1E5", "1٢", "1,2,3"] { #expect(a(junk) == nil, "\(junk)") }
        #expect(a("1,50") == nil)
        #expect(a("1,234.56", true) == nil)
        #expect(a("1,234") == 1234)
        #expect(a("1.234", true) == 1234)
    }

    @Test func dateFormats() {
        let samples = ["2026-10-25", "25/10/2026", "10/25/2026", "25.10.2026", "25 Oct 2026"]
        for (format, sample) in zip(CSVImport.dateFormats, samples) {
            #expect(ymd(CSVImport.date(sample, format: format)) == [2026, 10, 25], "\(format)")
        }
        #expect(ymd(CSVImport.date(" 2026-10-25 14:03 ", format: "yyyy-MM-dd")) == [2026, 10, 25])
        #expect(CSVImport.date("25/10/2026", format: "MM/dd/yyyy") == nil)
        #expect(CSVImport.date("25/10/26", format: "dd/MM/yyyy") == nil)
        #expect(CSVImport.date("", format: "yyyy-MM-dd") == nil)
    }

    @Test func draftsFromDebitCreditRows() {
        let account = Account(name: "DBS", type: .debit, currency: "SGD")
        context.insert(account)
        var mapping = CSVMapping()
        mapping.date = 0; mapping.description = 1; mapping.debit = 2; mapping.credit = 3; mapping.currency = 4
        mapping.dateFormat = "dd/MM/yyyy"
        let csv: [[String]] = [["Date", "Description", "Debit", "Credit", "Currency"],
                   ["01/10/2026", "  Kopi\n  Shop ", "4.50", "", "sgd"],
                   ["02/10/2026", "Salary", "", "3,000.00", "usd"],
                   ["2026-13-40", "Bad date", "", "1", ""],
                   ["04/10/2026", "Nothing", "", "", ""],
                   ["05/10/2026", "Junk", "abc", "", ""],
                   ["06/10/2026", "Short"],
                   ["07/10/2026", "Zero", "0.00", "", "XYZ"],
                   ["08/10/2026", "Refund", "-2", "", "XYZ"]]

        let (drafts, skipped) = CSVImport.drafts(csv, mapping: mapping, account: account)
        #expect(skipped == 5)
        #expect(drafts.map(\.amount) == [Decimal(string: "-4.50")!, 3000, -2])
        #expect(drafts.map(\.merchant) == ["Kopi Shop", "Salary", "Refund"])
        #expect(drafts.map(\.currency) == ["SGD", "USD", "SGD"])
        #expect(ymd(drafts[0].date) == [2026, 10, 1])
        #expect(drafts.allSatisfy { $0.account === account && $0.accountAmount == nil && $0.category == nil })

        mapping.negate = true
        #expect(CSVImport.drafts(csv, mapping: mapping, account: account).drafts.map(\.amount) == [Decimal(string: "4.50")!, -3000, 2])

        mapping.hasHeader = false
        #expect(CSVImport.drafts(csv, mapping: mapping, account: account).skipped == 6)
    }

    @Test func rowUsesAmountColumn() {
        var mapping = CSVMapping()
        mapping.date = 0; mapping.amount = 1; mapping.decimalComma = true
        let row = CSVImport.row(["2026-10-25", "-1.234,50"], mapping: mapping, fallbackCurrency: "EUR")
        #expect(row?.amount == Decimal(string: "-1234.5"))
        #expect(row?.merchant == "")
        #expect(row?.currency == "EUR")
        #expect(CSVImport.row(["2026-10-25"], mapping: mapping, fallbackCurrency: "EUR") == nil)
    }

    @Test func mappingPersistsPerAccount() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let a = UUID(), b = UUID()
        #expect(CSVMapping.saved(for: a, defaults: defaults) == nil)
        var first = CSVMapping()
        first.date = 2; first.amount = 5; first.dateFormat = "dd.MM.yyyy"; first.decimalComma = true
        var second = CSVMapping()
        second.hasHeader = false; second.debit = 1; second.credit = 2; second.negate = true
        first.save(for: a, defaults: defaults)
        second.save(for: b, defaults: defaults)
        #expect(CSVMapping.saved(for: a, defaults: defaults) == first)
        #expect(CSVMapping.saved(for: b, defaults: defaults) == second)
        #expect(defaults.dictionary(forKey: CSVMapping.key)?[a.uuidString] is Data)
        #expect(Backup.settingsKeys.contains(CSVMapping.key))
    }

    @Test func guessFromHeader() {
        let m = CSVImport.guess(header: ["Transaction Date", "Description", "Debit", "Credit", "Currency"])
        var expected = CSVMapping()
        expected.date = 0; expected.description = 1; expected.debit = 2; expected.credit = 3; expected.currency = 4
        #expect(m == expected)
        let dbs = CSVImport.guess(header: ["Date", "Reference", "Debit Amount", "Credit Amount", "Payee"])
        #expect(dbs.amount == nil && dbs.debit == 2 && dbs.credit == 3 && dbs.description == 1)
        #expect(CSVImport.guess(header: ["DATE", "AMOUNT", "MERCHANT"]).amount == 1)
    }
}
