import Foundation
import FoundationModels

/// Transaction field extraction from OCR / PDF text (#44): deterministic pre-pass, then on-device model merge.
enum TransactionExtraction {
    /// Fields read deterministically from receipt / bank-notice text. nil = not found (never guessed).
    nonisolated struct Fields: Equatable, Sendable {
        var merchant: String?
        var date: Date?
        var total: Decimal?
        var currency: String?
    }

    /// Pure. `now` bounds dates (reject dates more than 1 day after now).
    nonisolated static func prepass(_ text: String, now: Date, calendar: Calendar = .current) -> Fields {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let tokens = lines.map(money)
        let all = tokens.joined()
        func largest(_ isTotal: (String) -> Bool) -> Money? {
            zip(lines, tokens).filter { isTotal($0.0) }.flatMap(\.1).max { $0.amount < $1.amount }
        }
        // "Total Paid" / "Amount Paid" only when no strict total line (else it is often cash tendered).
        let total = largest { isTotalLine($0) } ?? largest { isTotalLine($0, paid: true) } ?? all.first { $0.marked }
        // ponytail: naive heuristic (first plausible top line); the model refines it.
        let label = #"^(to|merchant(?: name)?|payee|from|at)\s*:\s*"#
        let merchant = lines.lazy.map {
            $0.replacingOccurrences(of: label, with: "", options: [.regularExpression, .caseInsensitive])
        }.first { line in
            let letters = line.count(where: \.isLetter)
            return letters >= 3 && line.count(where: \.isNumber) < letters && !line.contains("@")
                && line.range(of: #"https?:|www\.|\.com\b|\b(tax invoice|receipt|invoice|welcome|gst reg|uen|alert|notification|confirmation)\b"#,
                              options: [.regularExpression, .caseInsensitive]) == nil
                && dates(in: line, calendar: calendar).isEmpty && money(line).isEmpty
        }
        return Fields(merchant: merchant,
                      date: dates(in: text, calendar: calendar).first { $0 <= now.addingTimeInterval(86_400) },
                      total: total?.amount,
                      // Only codes/symbols attached to an amount count: the total's own, else the first marked amount's.
                      // Bare "$"/"¥" give nil (`draft` resolves them against the home currency).
                      currency: total == nil ? nil : total?.currency ?? all.lazy.compactMap(\.currency).first)
    }

    /// `paid`: the second tier, "Total Paid" / "Amount Paid" lines.
    nonisolated private static func isTotalLine(_ line: String, paid: Bool = false) -> Bool {
        func has(_ pattern: String) -> Bool { line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        return has(#"\b(total|amount|balance due)\b"#)  // also covers grand total, total due, amount due/payable
            && has(#"\bpaid\b"#) == paid
            && !has(#"\b(sub[ -]?total|savings|discount|change|tendered|cash rounding)\b"#)
            && (has(#"\bincl"#) || !has(#"\b(gst|vat|tax)\b"#))
    }

    // ponytail: fixed allowlist (CUP/PEN/MOP are ISO codes and item words); extend as receipts show others.
    nonisolated private static let codes = Set(ApplePay.symbols.map(\.1)
        + ["USD", "EUR", "GBP", "JPY", "CNY", "CHF", "THB", "IDR", "KRW", "TWD", "PHP", "VND"])

    nonisolated private static let moneyPattern: NSRegularExpression = {
        let symbols = (ApplePay.symbols.map(\.0) + ["$", "¥"]).map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        // [marker] number [marker]; not glued to letters/digits or part of a date/time/ID ("12/10", "13:05", "M2-0012345-6").
        // "S$-12.50" keeps its marker. ponytail: ASCII-space thousands ("1 234,50") read as 234,50; NBSP/' work.
        return try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9]|\d[.,/:-])(?:([A-Z]{3}|"# + symbols
            + #")\s?-?)?(\d{1,3}(?:[,.'’\u00A0\u202F]\d{3})+(?:[.,]\d{2})?|\d+(?:[.,]\d{2})?)(?:\s?([A-Z]{3}|€|£|¥))?(?![A-Za-z0-9]|[.,/:-]\d)"#)
    }()

    private typealias Money = (amount: Decimal, currency: String?, marked: Bool, bare: String?)

    /// Money tokens on one line. Money = 2 decimals or a currency marker ("¥1,280"); "Qty 3", "Table 12" are not.
    nonisolated private static func money(_ line: String) -> [Money] {
        moneyPattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: line).map { String(line[$0]) } }
            // A 3-letter prefix/suffix is a marker only if allowlisted ("SGD 25.00", not "TAX 3.29" / "PAPER CUP 3.50").
            let marker = [group(1), group(3)].compactMap { $0 }
                .first { !($0.count == 3 && $0.allSatisfy(\.isLetter)) || codes.contains($0) }
            let number = group(2)!
            guard marker != nil || number.range(of: #"[.,]\d{2}$"#, options: .regularExpression) != nil,
                  let parsed = ApplePay.parseAmount((marker ?? "") + number, fallback: "") else { return nil }
            // Bare "$"/"¥" are ambiguous: currency nil, marker kept in `bare` for `draft` to resolve.
            let bare = marker == "$" || marker == "¥" ? marker : nil
            return (parsed.amount, bare != nil || parsed.currency.isEmpty ? nil : parsed.currency, marker != nil, bare)
        }
    }

    nonisolated private static let isoDate = try! NSRegularExpression(pattern: #"(?<![0-9])([0-9]{4})([-/])([0-9]{1,2})\2([0-9]{1,2})(?![0-9])"#)
    nonisolated private static let numericDate = try! NSRegularExpression(pattern: #"(?<![0-9A-Za-z.])([0-9]{1,2})([-/.])([0-9]{1,2})\2([0-9]{4}|[0-9]{2})(?![0-9])"#)
    nonisolated private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Valid date candidates in text order, at noon in `calendar` (time of day unused; noon avoids day shifts).
    nonisolated private static func dates(in text: String, calendar: Calendar) -> [Date] {
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

extension TransactionExtraction {
    /// Entry point for #45/#46/#47. Never throws, never blocks: model unavailable or erroring (guardrail, ModelManagerError)
    /// -> pre-pass only. Blank text -> []. One transaction per text; callers split per document/page as they need.
    /// A non-empty result doesn't mean a transaction was found: amount 0 = no total.
    @MainActor static func extract(_ text: String, categories: [Category], fallbackCurrency: String = FX.home(),
                                   now: Date = .now, defaults: UserDefaults = .standard,
                                   modelAvailable: Bool = OnDeviceAI.unavailableReason == nil) async -> [DraftTransaction] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let (fields, parts) = await scan(text, now: now)
        var model: [ExtractedTransaction] = []
        if modelAvailable {
            let names = categories.filter { !$0.isIncome }.map(\.name).joined(separator: ", ")
            let instructions = """
                Extract the purchase from receipt or bank-notice text. \
                Leave a field empty when the text does not state it; never guess.
                """ + (names.isEmpty ? "" : "\nPick category from: \(names)")
            // ponytail: only the first 3 chunks (~6,000 chars) reach the model; the pre-pass still sees all text.
            // Raise the cap if notices put totals later.
            for chunk in parts.prefix(3) {
                if Task.isCancelled { break }
                let session = LanguageModelSession(instructions: instructions)
                // English lead-in: a bare all-caps/numeric receipt fails language detection (unsupportedLanguageOrLocale).
                let prompt = "Here is the receipt or bank notice text:\n\(chunk)"
                if let output = try? await session.respond(to: prompt, generating: ExtractedTransaction.self).content {
                    model.append(output)
                }
            }
        }
        return [draft(prepass: fields, model: model, text: text, categories: categories,
                      fallbackCurrency: fallbackCurrency, now: now, defaults: defaults)]
    }

    /// Pre-pass + chunking off the main actor (long PDF text).
    @concurrent private nonisolated static func scan(_ text: String, now: Date) async -> (Fields, [String]) {
        (prepass(text, now: now), chunks(text))
    }

    /// Line-boundary chunks of at most `limit` characters; a single longer line is hard-split. Pure.
    nonisolated static func chunks(_ text: String, limit: Int = 2_000) -> [String] {
        var result: [String] = [], current = ""
        for var line in text.split(whereSeparator: \.isNewline) {
            while line.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(line.prefix(limit)))
                line = line.dropFirst(limit)
            }
            if !current.isEmpty, current.count + 1 + line.count > limit { result.append(current); current = "" }
            if !current.isEmpty { current += "\n" }
            current += line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Pure merge of pre-pass + per-chunk model outputs (chunk order) into one draft.
    /// Pre-pass wins for total/currency/date; model merchant preferred when every word is in the text.
    /// Model strings are only accepted when they check out against `text`.
    static func draft(prepass: Fields, model: [ExtractedTransaction], text: String, categories: [Category],
                      fallbackCurrency: String, now: Date, defaults: UserDefaults = .standard) -> DraftTransaction {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !["", "nil", "null", "none", "n/a", "unknown"].contains(value.lowercased()) else { return nil }
            return value
        }
        // ponytail: money scan of the full text stays on main; PDF import caps text at 5 pages so it stays small.
        // Move tokens into `scan` if long text gets slow.
        let tokens = text.components(separatedBy: .newlines).flatMap(money)
        let amounts = Set(tokens.map(\.amount))
        let total = prepass.total ?? model.compactMap { clean($0.total).flatMap { ApplePay.parseAmount($0, fallback: "")?.amount } }
            .last { amounts.contains($0) }
        let words = Set(text.uppercased().split { !$0.isLetter }.map(String.init))
        let currency = prepass.currency ?? model.lazy.compactMap { clean($0.currency)?.uppercased() }
            .first { codes.contains($0) && words.contains($0) }
            // Bare "$"/"¥" only when nothing explicit: ¥ -> JPY unless home is JPY/CNY; $ -> home if a dollar, else USD.
            ?? tokens.lazy.compactMap(\.bare).first.flatMap { ApplePay.parseAmount($0 + "1", fallback: fallbackCurrency)?.currency }
        let textTokens = Set(Categorizer.normalize(text).split(separator: " "))
        let merchant = model.lazy.compactMap { clean($0.merchant) }
            .first { Set(Categorizer.normalize($0).split(separator: " ")).isSubset(of: textTokens) }
            ?? prepass.merchant ?? ""
        let spending = categories.filter { !$0.isIncome }
        let category = Categorizer.rule(for: merchant, in: spending, defaults: defaults)
            ?? model.lazy.compactMap { clean($0.category).flatMap { Budgets.named($0, in: spending) } }.first
        // ponytail: always an outflow; refunds/credits are not detected, the user flips the sign in review.
        return DraftTransaction(amount: total.map { -$0 } ?? 0, currency: currency ?? fallbackCurrency, date: prepass.date ?? now,
                                merchant: merchant, category: category, categoryIsAuto: category != nil)
    }
}

/// Model output for transaction extraction. Strings only: `draft` validates every field against the source text.
@Generable
struct ExtractedTransaction {
    @Guide(description: "Merchant or shop name exactly as written on the receipt; leave empty if not stated")
    var merchant: String?
    // Slot for the model's date reading; intentionally never trusted, dates come from the pre-pass.
    @Guide(description: "Purchase date exactly as written on the receipt; leave empty if not stated")
    var date: String?
    @Guide(description: "Final amount paid exactly as written, not the subtotal, tax, change or cash tendered; leave empty if not stated")
    var total: String?
    @Guide(description: "ISO currency code or symbol, only if printed on the receipt; leave empty if not stated")
    var currency: String?
    @Guide(description: "One of the listed category names, or empty")
    var category: String?
}
