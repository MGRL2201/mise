import SwiftUI
import UniformTypeIdentifiers

/// CSV export of transactions (#42) and holdings (#48). RFC 4180 quoting, CRLF records, UTF-8 BOM so Excel reads non-ASCII.
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

    static let holdingsHeader = ["account", "kind", "symbol", "name", "quantity", "cost_basis", "currency", "price",
                                 "price_date", "value", "gain_loss", "home_value", "home_currency"]

    /// Header, then one row per holding. Value fields are empty without a price; home_value is empty without a cached rate on or before today.
    static func holdingRows(_ holdings: [Holding], rates: FXRates, homeCurrency: String, today: Date = .now,
                            timeZone: TimeZone = .current) -> [[String]] {
        let day = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day()
        let dayRates = rates.rates(on: FXRates.day(today)) ?? [:]
        return [holdingsHeader] + holdings.map { h in
            let value = Holdings.value(h)
            return [h.account?.name ?? "", h.kind.rawValue, h.symbol, h.name, "\(h.quantity)", "\(h.costBasis)", h.currency,
                    h.price.map { "\($0)" } ?? "", h.priceDate?.formatted(day) ?? "", value.map { "\($0)" } ?? "",
                    Holdings.gain(h).map { "\($0)" } ?? "",
                    value.flatMap { FX.convert($0, from: h.currency, to: homeCurrency, rates: dayRates) }.map { "\($0)" } ?? "",
                    homeCurrency]
        }
    }

    static func filename(_ kind: String = "transactions", now: Date = .now, timeZone: TimeZone = .current) -> String {
        "mise-\(kind)-\(now.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())).csv"
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
