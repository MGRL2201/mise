import Testing
import Foundation
import SwiftData
@testable import mise

@MainActor
struct TransactionExtractionTests {
    static let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return calendar
    }()
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))!

    // (text, merchant, [year, month, day], total, currency)
    nonisolated static let fixtures: [(String, String?, [Int]?, String?, String?)] = [
        ("""
        FAIRPRICE
        NTUC FairPrice Co-operative Ltd
        GST Reg No: M2-0012345-6
        12/10/2026 18:42
        MILO 1KG            12.95
        EGGS 10S             3.20
        OLIVE OIL 1L        25.02
        PAPER CUP 3.50
        SUBTOTAL            41.17
        GST 9%               3.29
        TOTAL               44.46
        TOTAL PAID          50.00
        CHANGE               5.54
        """, "FAIRPRICE", [2026, 10, 12], "44.46", nil),
        ("""
        Toast Box
        Raffles City B1-23
        Date: 27/10/2026 08:15
        Kaya Toast Set   S$5.60
        Teh C            S$1.80
        Total (2 items)  S$7.40
        """, "Toast Box", [2026, 10, 27], "7.40", "SGD"),
        ("""
        Ya Kun Kaya Toast
        14 Oct 2026
        Kaya Toast Set x1   $5.80
        Kopi x2             $7.00
        Total $12.80 (incl. GST $1.06)
        Total GST           1.06
        """, "Ya Kun Kaya Toast", [2026, 10, 14], "12.80", nil),
        ("""
        Transaction Alert
        Amount: SGD 25.00
        Date & Time: 28 Oct 2026 13:05 SGT
        To: GRAB*RIDE
        """, "GRAB*RIDE", [2026, 10, 28], "25.00", "SGD"),
        ("""
        Café de Flore
        172 Boulevard Saint-Germain
        75006 Paris
        22/10/2026
        Café crème          9,00 €
        Croque monsieur    23,40 €
        Total:             1\u{A0}234,50 €
        """, "Café de Flore", [2026, 10, 22], "1234.50", "EUR"),
        ("""
        TRADER JOE'S #123
        1234 Main St, Springfield
        10/27/2026 5:42 PM
        BANANAS          1.99
        BIC PEN 2.50
        SUBTOTAL        41.17
        TAX              3.29
        TOTAL           44.46
        VISA            44.46
        """, "TRADER JOE'S #123", [2026, 10, 27], "44.46", nil),
        ("""
        LAWSON 渋谷店
        2026/10/20 14:03
        おにぎり        ¥150
        お茶           ¥130
        弁当           ¥1,000
        TOTAL         ¥1,280
        """, "LAWSON 渋谷店", [2026, 10, 20], "1280", nil),
        ("""
        TAX INVOICE
        Acme Pte Ltd
        UEN 201912345K
        Invoice date 2026-10-01
        Amount Due SGD 1,234.50
        """, "Acme Pte Ltd", [2026, 10, 1], "1234.50", "SGD"),
        ("""
        Notes
        Call the plumber about the sink
        """, "Notes", nil, nil, nil),
        ("""
        KOPITIAM
        Date: 05/01/2027
        TOTAL           18.20
        SERVICE CHARGE   1.82
        GRAND TOTAL     20.02
        """, "KOPITIAM", nil, "20.02", nil),
        ("""
        Confiserie Sprüngli
        Terminal v1.2.26
        TOTAL       1'234.50 CHF
        """, "Confiserie Sprüngli", nil, "1234.50", "CHF"),
        ("""
        Uniqlo
        Refund 26/10/2026
        TOTAL        S$-12.50
        """, "Uniqlo", [2026, 10, 26], "12.50", "SGD"),
        ("""
        LATTE S$4.50
        BREAD S$3.20
        TOTAL PAID S$7.70
        """, nil, nil, "7.70", "SGD"),
        ("""
        Merchant:
        GRAB*RIDE
        Amount SGD 25.00
        """, "GRAB*RIDE", nil, "25.00", "SGD"),
        ("""
        Café: Ya Kun
        Kopi  $1.80
        """, "Café: Ya Kun", nil, "1.80", nil),
    ]

    @Test(arguments: fixtures)
    func prepass(text: String, merchant: String?, ymd: [Int]?, total: String?, currency: String?) {
        let fields = TransactionExtraction.prepass(text, now: now, calendar: Self.calendar)
        #expect(fields.merchant == merchant)
        #expect(fields.date.map { Self.calendar.dateComponents([.year, .month, .day], from: $0) }
            .map { [$0.year!, $0.month!, $0.day!] } == ymd)
        #expect(fields.total == total.flatMap { Decimal(string: $0) })
        #expect(fields.currency == currency)
    }

    /// Fullwidth (Japanese OCR) and Arabic-Indic digits must not trap the date regexes' Int parse.
    @Test func prepassNonASCIIDigits() {
        let fields = TransactionExtraction.prepass("２０２６/１０/２０\n٢٠/١٠/٢٠٢٦\nTOTAL 44.46", now: now, calendar: Self.calendar)
        #expect(fields.total == Decimal(string: "44.46"))
    }

    @Test func chunks() {
        let text = (1...300).map { "LINE \($0) ITEM            \($0).99" }.joined(separator: "\n")
            + "\n" + String(repeating: "x", count: 5_000) + "\nTOTAL 44.46"
        let chunks = TransactionExtraction.chunks(text, limit: 2_000)
        #expect(chunks.count > 3)
        #expect(chunks.allSatisfy { $0.count <= 2_000 })
        #expect(chunks.joined().filter { !$0.isNewline } == text.filter { !$0.isNewline })
        #expect(TransactionExtraction.chunks("", limit: 10).isEmpty)
    }

    let container = try! ModelContainer(for: Schema(Storage.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let food = mise.Category(name: "Food"), transport = mise.Category(name: "Transport")
    let salary = { let category = mise.Category(name: "Salary"); category.isIncome = true; return category }()

    func draft(_ model: [ExtractedTransaction], text: String, prepass: TransactionExtraction.Fields = .init()) -> DraftTransaction {
        TransactionExtraction.draft(prepass: prepass, model: model, text: text, categories: [food, transport, salary],
                                    fallbackCurrency: "SGD", now: now, defaults: defaults)
    }

    @Test func draftAmount() {
        let text = "SHOP\nTOTAL 44.46\nCASH 50.00"
        #expect(draft([ExtractedTransaction(total: "50.00")], text: text, prepass: .init(total: Decimal(string: "44.46"))).amount == Decimal(string: "-44.46"))
        #expect(draft([ExtractedTransaction(total: "50.00")], text: text).amount == -50)
        #expect(draft([ExtractedTransaction(total: "99.99")], text: text).amount == 0)
        #expect(draft([ExtractedTransaction(total: "44.46"), ExtractedTransaction(total: "nil")], text: text).amount == Decimal(string: "-44.46"))
    }

    @Test func draftCurrency() {
        #expect(draft([ExtractedTransaction(currency: "EUR")], text: "SHOP\nTOTAL 44.46").currency == "SGD")
        #expect(draft([ExtractedTransaction(currency: "eur")], text: "SHOP\nTOTAL 44.46 EUR").currency == "EUR")
        #expect(draft([ExtractedTransaction(currency: "EUR")], text: "SHOP EUR\nTOTAL 44.46",
                      prepass: .init(currency: "CHF")).currency == "CHF")
        #expect(draft([ExtractedTransaction(currency: "NULL")], text: "x").currency == "SGD")
        #expect(draft([], text: "TOTAL ¥1,280").currency == "JPY")
        #expect(draft([], text: "TOTAL $12.80").currency == "SGD")
    }

    @Test func draftDateAndMerchant() {
        let date = draft([ExtractedTransaction(merchant: "Ghost Cafe", date: "2026-10-12"),
                          ExtractedTransaction(merchant: "Trader Joe's")], text: "TRADER JOE'S #123\nTOTAL 1.00")
        #expect(date.date == now)
        #expect(date.merchant == "Trader Joe's")
        #expect(draft([ExtractedTransaction(merchant: "Visa Card")], text: "TRADER JOE'S #123\nVISA 44.46",
                      prepass: .init(merchant: "TRADER JOE'S #123")).merchant == "TRADER JOE'S #123")
        let none = draft([ExtractedTransaction(merchant: "none", date: "unknown")], text: "x", prepass: .init(merchant: "SHOP"))
        #expect(none.date == now)
        #expect(none.merchant == "SHOP")
    }

    @Test func draftCategory() {
        let auto = draft([ExtractedTransaction(merchant: "Grab", category: "food")], text: "GRAB")
        #expect(auto.category === food)
        #expect(auto.categoryIsAuto)
        #expect(draft([ExtractedTransaction(category: "Groceries")], text: "x").category == nil)
        #expect(draft([ExtractedTransaction(category: "Salary")], text: "x").category == nil)
        #expect(draft([ExtractedTransaction(category: "Groceries"), ExtractedTransaction(category: "Food")], text: "x").category === food)
        Categorizer.learn("Grab", category: transport, defaults: defaults)
        #expect(draft([ExtractedTransaction(merchant: "Grab", category: "Food")], text: "GRAB").category === transport)
        let empty = draft([], text: "x")
        #expect(empty.category == nil && !empty.categoryIsAuto && empty.account == nil)
    }

    @Test(arguments: fixtures)
    func extractWithoutModel(text: String, merchant: String?, ymd: [Int]?, total: String?, currency: String?) async {
        let drafts = await TransactionExtraction.extract(text, categories: [food], fallbackCurrency: "SGD", now: now,
                                                         defaults: defaults, modelAvailable: false)
        #expect(drafts.count == 1)
        #expect(drafts.first?.amount == total.flatMap { Decimal(string: $0) }.map { -$0 } ?? 0)
        #expect(drafts.first?.currency == (text.hasPrefix("LAWSON") ? "JPY" : currency ?? "SGD"))
    }

    @Test func extractBlank() async {
        #expect(await TransactionExtraction.extract(" \n ", categories: [], modelAvailable: false).isEmpty)
    }

    // Opt-in: TEST_RUNNER_MISE_FM_SPIKE=1 (the simulator reports the model available but every call throws).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MISE_FM_SPIKE"] != nil))
    func extractWithModel() async {
        let text = Self.fixtures.first { $0.0.hasPrefix("TRADER JOE'S") }!.0
        let groceries = mise.Category(name: "Groceries"), shopping = mise.Category(name: "Shopping")
        let drafts = await TransactionExtraction.extract(text, categories: [food, transport, groceries, shopping, salary],
                                                         fallbackCurrency: "USD", now: now, defaults: defaults, modelAvailable: true)
        #expect(drafts.first?.amount == Decimal(string: "-44.46"))
        // Only the model can pick a category here (no learned rule in this fresh suite).
        #expect(drafts.first?.category != nil)  // real model picks Food or Groceries; either is reasonable
        #expect(drafts.first?.categoryIsAuto == true)
    }
}
