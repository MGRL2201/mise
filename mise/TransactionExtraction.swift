import Foundation

/// Transaction field extraction from OCR / PDF text (#44): deterministic pre-pass.
enum TransactionExtraction {
    /// Fields read deterministically from receipt / bank-notice text. nil = not found (never guessed).
    struct Fields: Equatable {
        var merchant: String?
        var date: Date?
        var total: Decimal?
        var currency: String?
    }

    /// Pure. `now` bounds dates (reject dates more than 1 day after now).
    static func prepass(_ text: String, now: Date, calendar: Calendar = .current) -> Fields {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let tokens = lines.map(money)
        let all = tokens.joined()
        let total = zip(lines, tokens).filter { isTotalLine($0.0) }.flatMap(\.1).max { $0.amount < $1.amount }
            ?? all.first { $0.marked }
        // ponytail: naive heuristic (first plausible top line); the model refines it.
        let merchant = lines.first { line in
            let letters = line.count(where: \.isLetter)
            return letters >= 3 && line.count(where: \.isNumber) < letters && !line.contains("@")
                && line.range(of: #"https?:|www\.|\.com\b|\b(tax invoice|receipt|invoice|welcome|gst reg|uen|alert|notification|confirmation)\b"#,
                              options: [.regularExpression, .caseInsensitive]) == nil
                && dates(in: line, calendar: calendar).isEmpty && money(line).isEmpty
        }
        return Fields(merchant: merchant?.replacingOccurrences(of: #"^\w+:\s*"#, with: "", options: .regularExpression),
                      date: dates(in: text, calendar: calendar).first { $0 <= now.addingTimeInterval(86_400) },
                      total: total?.amount,
                      // Bare "$"/"¥" give nil (caller falls back to home currency); an ISO code / S$ anywhere in the text wins.
                      currency: total == nil ? nil : total?.currency ?? all.lazy.compactMap(\.currency).first)
    }

    private static func isTotalLine(_ line: String) -> Bool {
        func has(_ pattern: String) -> Bool { line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        return has(#"\b(total|amount|balance due)\b"#)  // also covers grand total, total due, amount due/payable
            && !has(#"\b(sub[ -]?total|savings|discount|paid|change|tendered|cash rounding)\b"#)
            && (has(#"\bincl"#) || !has(#"\b(gst|vat|tax)\b"#))
    }

    // ponytail: fixed allowlist (CUP/PEN/MOP are ISO codes and item words); extend as receipts show others.
    private static let codes = Set(ApplePay.symbols.map(\.1)
        + ["USD", "EUR", "GBP", "JPY", "CNY", "CHF", "THB", "IDR", "KRW", "TWD", "PHP", "VND"])

    private static let moneyPattern: NSRegularExpression = {
        let symbols = (ApplePay.symbols.map(\.0) + ["$", "¥"]).map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        // [marker] number [marker]; not glued to letters/digits or part of a date/time/ID ("12/10", "13:05", "M2-0012345-6").
        // "S$-12.50" keeps its marker. ponytail: ASCII-space thousands ("1 234,50") read as 234,50; NBSP/' work.
        return try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9]|\d[.,/:-])(?:([A-Z]{3}|"# + symbols
            + #")\s?-?)?(\d{1,3}(?:[,.'’\u00A0\u202F]\d{3})+(?:[.,]\d{2})?|\d+(?:[.,]\d{2})?)(?:\s?([A-Z]{3}|€|£|¥))?(?![A-Za-z0-9]|[.,/:-]\d)"#)
    }()

    /// Money tokens on one line. Money = 2 decimals or a currency marker ("¥1,280"); "Qty 3", "Table 12" are not.
    private static func money(_ line: String) -> [(amount: Decimal, currency: String?, marked: Bool)] {
        moneyPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: line).map { String(line[$0]) } }
            // A 3-letter prefix/suffix is a marker only if allowlisted ("SGD 25.00", not "TAX 3.29" / "PAPER CUP 3.50").
            let marker = [group(1), group(3)].compactMap { $0 }
                .first { !($0.count == 3 && $0.allSatisfy(\.isLetter)) || codes.contains($0) }
            let number = group(2)!
            guard marker != nil || number.range(of: #"[.,]\d{2}$"#, options: .regularExpression) != nil,
                  let parsed = ApplePay.parseAmount((marker ?? "") + number, fallback: "") else { return nil }
            // Bare "$"/"¥" are ambiguous: nil, caller falls back to home currency.
            return (parsed.amount, marker == "$" || marker == "¥" || parsed.currency.isEmpty ? nil : parsed.currency, marker != nil)
        }
    }

    private static let isoDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})([-/])(\d{1,2})\2(\d{1,2})(?!\d)"#)
    private static let numericDate = try! NSRegularExpression(pattern: #"(?<![\dA-Za-z.])(\d{1,2})([-/.])(\d{1,2})\2(\d{4}|\d{2})(?!\d)"#)
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Valid date candidates in text order, at noon in `calendar` (time of day unused; noon avoids day shifts).
    private static func dates(in text: String, calendar: Calendar) -> [Date] {
        let range = NSRange(text.startIndex..., in: text), nsText = text as NSString
        func int(_ match: NSTextCheckingResult, _ i: Int) -> Int { Int(nsText.substring(with: match.range(at: i)))! }
        var found = isoDate.matches(in: text, range: range).map {
            ($0.range.location, DateComponents(year: int($0, 1), month: int($0, 3), day: int($0, 4)))
        }
        for match in numericDate.matches(in: text, range: range) {
            var (day, month, year) = (int(match, 1), int(match, 3), int(match, 4))
            if month > 12 { swap(&day, &month) }  // day-first (SG) unless impossible: US "10/27/2026"
            found.append((match.range.location, DateComponents(year: year < 100 ? year + 2000 : year, month: month, day: day)))
        }
        // Textual dates only ("12 Oct 2026", "12OCT26"); numeric ones are parsed above and bare times are skipped.
        for match in detector.matches(in: text, range: range)
        where nsText.substring(with: match.range).range(of: "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec",
                                                         options: [.regularExpression, .caseInsensitive]) != nil {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = match.timeZone ?? .current  // detector reads the text in this zone
            found.append((match.range.location, local.dateComponents([.year, .month, .day], from: match.date!)))
        }
        return found.sorted { $0.0 < $1.0 }.compactMap { _, components in
            var components = components
            components.hour = 12
            return components.isValidDate(in: calendar) ? calendar.date(from: components) : nil
        }
    }
}
