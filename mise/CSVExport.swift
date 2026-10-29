import SwiftUI
import UniformTypeIdentifiers

/// CSV export of transactions (#42). RFC 4180 quoting, CRLF records, UTF-8 BOM so Excel reads non-ASCII.
enum CSVExport {
    static let header = ["date", "account", "merchant", "category", "amount", "currency",
                         "account_amount", "home_amount", "home_currency", "notes", "source"]

    nonisolated static func field(_ s: String) -> String {
        // Unicode scalars, not Characters: "\r\n" is one Character and would slip past a Character check.
        guard s.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    nonisolated static func encode(_ rows: [[String]]) -> Data {
        Data("\u{FEFF}".utf8) + Data(rows.map { $0.map(field).joined(separator: ",") + "\r\n" }.joined().utf8)
    }

    /// Header, then one row per transaction. Amounts use `Decimal.description` ('.' separator, no grouping, any locale).
    static func rows(_ transactions: [mise.Transaction], homeCurrency: String, timeZone: TimeZone = .current) -> [[String]] {
        let day = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
        return [header] + transactions.map { t in
            [t.date.formatted(day), t.account?.name ?? "", t.merchant, t.category?.name ?? "",
             "\(t.amount)", t.currency, t.accountAmount.map { "\($0)" } ?? "", t.homeAmount.map { "\($0)" } ?? "",
             homeCurrency, t.notes, t.source.rawValue]
        }
    }

    static func filename(now: Date = .now, timeZone: TimeZone = .current) -> String {
        "mise-transactions-\(now.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())).csv"
    }
}

struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
