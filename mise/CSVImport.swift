import Foundation

/// Bank CSV import (#47): RFC 4180 parsing, lenient amount/date parsing, column mapping -> review drafts.
enum CSVImport {
    static let dateFormats = ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd.MM.yyyy", "d MMM yyyy"]

    /// UTF-8 (else Windows-1252), BOM stripped, delimiter "," ";" or tab picked from the first line.
    /// Quoted fields may hold delimiters, "" and newlines; CRLF/LF/CR records; all-blank rows dropped.
    nonisolated static func rows(_ data: Data) -> [[String]] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
        // Unicode scalars, not Characters: "\r\n" is one Character.
        let scalars = text.unicodeScalars.first == "\u{FEFF}" ? text.unicodeScalars.dropFirst() : text.unicodeScalars[...]

        // A quote opens quoted mode only at the start of a field; elsewhere it is literal.
        let candidates: [Unicode.Scalar] = [",", ";", "\t"]
        var counts: [Unicode.Scalar: Int] = [:]
        var quoted = false, wasQuoted = false, previous: Unicode.Scalar?
        for s in scalars {
            let atStart = previous.map { candidates.contains($0) } ?? true
            if s == "\"", quoted || atStart || wasQuoted && previous == "\"" { quoted.toggle(); wasQuoted = true }
            else if !quoted, s == "\n" || s == "\r" { break }
            else if !quoted { counts[s, default: 0] += 1; if candidates.contains(s) { wasQuoted = false } }
            previous = s
        }
        let delimiter = candidates.max { counts[$0, default: 0] < counts[$1, default: 0] }!  // ties keep the first: ","

        var rows: [[String]] = [], row: [String] = [], field = String.UnicodeScalarView()
        previous = nil
        quoted = false
        wasQuoted = false
        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            wasQuoted = false
        }
        func endRow() {
            endField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []
        }
        for s in scalars {
            if s == "\"", quoted || field.isEmpty && !wasQuoted {
                quoted.toggle(); wasQuoted = true
            } else if s == "\"", wasQuoted, previous == "\"" {
                field.append(s); quoted = true  // "" inside a quoted field
            } else if quoted {
                field.append(s)
            } else if s == delimiter {
                endField()
            } else if s == "\r" || s == "\n" {
                if !(s == "\n" && previous == "\r") { endRow() }
            } else {
                field.append(s)
            }
            previous = s
        }
        endRow()
        return rows
    }

    /// Strips spaces, currency symbols and ' grouping anywhere; letters only at the ends (ISO code or ≤2 letters, e.g. "S$").
    /// Negative: leading - or −, trailing -, (parentheses) or DR; CR forces positive.
    /// decimalComma: "1.234,56"; else "1,234.56". nil for blank, malformed grouping/decimal or leftover junk.
    nonisolated static func amount(_ text: String, decimalComma: Bool) -> Decimal? {
        let stripped = String(text.unicodeScalars.filter {
            !(CharacterSet.whitespacesAndNewlines.contains($0)
              || $0.properties.generalCategory == .currencySymbol || "'’".unicodeScalars.contains($0))
        })
        guard let parts = stripped.wholeMatch(of: /(\p{L}*)(.*?)(\p{L}*)/)?.output else { return nil }
        var s = String(parts.2), forced: Bool?
        for code in [parts.1, parts.3].map({ $0.uppercased() }) where !code.isEmpty {
            switch code {
            case "DR": forced = true
            case "CR": forced = false
            case _ where code.count <= 2 || Locale.commonISOCurrencyCodes.contains(code): break
            default: return nil
            }
        }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if let sign = s.first, "-−+".contains(sign) { negative = negative || sign != "+"; s.removeFirst() }
        else if s.hasSuffix("-") { negative = true; s.removeLast() }
        let shape = decimalComma ? /[0-9]{1,3}(?:\.[0-9]{3})*(?:,[0-9]*)?|[0-9]+(?:,[0-9]*)?|,[0-9]+/
                                 : /[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]*)?|[0-9]+(?:\.[0-9]*)?|\.[0-9]+/
        guard s.wholeMatch(of: shape) != nil else { return nil }
        s.removeAll { $0 == (decimalComma ? "." : ",") }
        if decimalComma { s = s.replacingOccurrences(of: ",", with: ".") }
        guard let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return (forced ?? negative) ? -value : value
    }

    /// Strict POSIX parse in the current time zone. Falls back to the leading whitespace-separated components
    /// ("2026-10-25 14:03" with "yyyy-MM-dd"). Years before 1900 are rejected.
    nonisolated static func date(_ text: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        formatter.isLenient = false
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = text.split(whereSeparator: \.isWhitespace).prefix(format.split(separator: " ").count).joined(separator: " ")
        guard let date = formatter.date(from: text) ?? formatter.date(from: head),
              Calendar.current.component(.year, from: date) >= 1900 else { return nil }
        return date
    }

    /// nil when date or amount is missing/unparsable or the amount is 0. Out-of-range columns count as missing.
    static func row(_ fields: [String], mapping: CSVMapping,
                    fallbackCurrency: String) -> (date: Date, amount: Decimal, merchant: String, currency: String)? {
        func cell(_ index: Int?) -> String? { index.flatMap { fields.indices.contains($0) ? fields[$0] : nil } }
        guard let date = cell(mapping.date).flatMap({ CSVImport.date($0, format: mapping.dateFormat) }) else { return nil }

        var value: Decimal
        if mapping.amount != nil {
            guard let parsed = cell(mapping.amount).flatMap({ amount($0, decimalComma: mapping.decimalComma) }) else { return nil }
            value = parsed
        } else {  // credit minus |debit|; blank = 0, non-blank junk rejects the row
            let pair = [mapping.credit, mapping.debit].map { cell($0)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            guard pair.contains(where: { !$0.isEmpty }) else { return nil }
            let parsed = pair.map { $0.isEmpty ? 0 : amount($0, decimalComma: mapping.decimalComma) }
            guard let credit = parsed[0], let debit = parsed[1] else { return nil }
            value = credit - abs(debit)
        }
        if mapping.negate { value = -value }
        guard value != 0 else { return nil }

        let merchant = cell(mapping.description)?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        let code = cell(mapping.currency)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        return (date, value, merchant, Locale.commonISOCurrencyCodes.contains(code) ? code : fallbackCurrency)
    }

    static func drafts(_ rows: [[String]], mapping: CSVMapping, account: Account) -> (drafts: [DraftTransaction], skipped: Int) {
        let parsed = rows.dropFirst(mapping.hasHeader ? 1 : 0).map { row($0, mapping: mapping, fallbackCurrency: account.currency) }
        let drafts = parsed.compactMap { $0 }.map {
            DraftTransaction(amount: $0.amount, currency: $0.currency, date: $0.date, merchant: $0.merchant, account: account)
        }
        return (drafts, parsed.count - drafts.count)
    }

    /// Case-insensitive contains-match on header names; first matching column wins.
    static func guess(header: [String]) -> CSVMapping {
        let names = header.map { $0.lowercased() }
        func find(_ keys: String...) -> Int? { names.firstIndex { name in keys.contains { name.contains($0) } } }
        var mapping = CSVMapping()
        mapping.date = find("date")
        mapping.debit = find("debit", "withdrawal")
        mapping.credit = find("credit", "deposit")
        if let amount = find("amount"), amount != mapping.debit, amount != mapping.credit { mapping.amount = amount }
        mapping.description = find("description", "merchant", "payee", "details", "narrative", "reference")
        mapping.currency = find("currency")
        return mapping
    }
}

/// Column indices (0-based) for one bank's CSV layout, remembered per account.
struct CSVMapping: Codable, Equatable {
    var hasHeader = true
    var date: Int?
    var amount: Int?
    var debit: Int?
    var credit: Int?
    var description: Int?
    var currency: Int?
    var dateFormat = "yyyy-MM-dd"
    var decimalComma = false
    var negate = false

    static let key = "finance.csvMappings"   // [account uuidString: JSON-encoded CSVMapping]

    static func saved(for account: UUID, defaults: UserDefaults = .standard) -> CSVMapping? {
        (defaults.dictionary(forKey: key)?[account.uuidString] as? Data).flatMap { try? JSONDecoder().decode(CSVMapping.self, from: $0) }
    }

    func save(for account: UUID, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        all[account.uuidString] = try? JSONEncoder().encode(self)
        defaults.set(all, forKey: Self.key)
    }
}
