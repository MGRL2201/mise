import Testing
import Foundation
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
    @Test(arguments: [
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
    ] as [(String, String?, [Int]?, String?, String?)])
    func prepass(text: String, merchant: String?, ymd: [Int]?, total: String?, currency: String?) {
        let fields = TransactionExtraction.prepass(text, now: now, calendar: Self.calendar)
        #expect(fields.merchant == merchant)
        #expect(fields.date.map { Self.calendar.dateComponents([.year, .month, .day], from: $0) }
            .map { [$0.year!, $0.month!, $0.day!] } == ymd)
        #expect(fields.total == total.flatMap { Decimal(string: $0) })
        #expect(fields.currency == currency)
    }
}
