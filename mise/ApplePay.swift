import Foundation
import SwiftData

/// Apple Pay auto-import (#153) helpers: parse the Shortcuts Transaction amount, dedupe, map card -> account.
enum ApplePay {
    static let cardsKey = "finance.cardAccounts"       // [card name: account uuidString]; "" = seen but unmapped
    static let defaultKey = "finance.applePayDefault"  // account uuidString
    static let duplicateWindow: TimeInterval = 300

    // ponytail: fixed symbol list; extend when real automation values show others.
    // Order matters: "US$" before "S$", "CA$" before "A$". Bare "$"/"¥" resolve via fallback.
    nonisolated static let symbols = [("US$", "USD"), ("S$", "SGD"), ("HK$", "HKD"), ("NZ$", "NZD"), ("CA$", "CAD"),
                                  ("A$", "AUD"), ("JP¥", "JPY"), ("CN¥", "CNY"), ("€", "EUR"), ("£", "GBP"),
                                  ("₹", "INR"), ("RM", "MYR")]
    nonisolated private static let dollarCurrencies: Set = ["USD", "SGD", "AUD", "CAD", "NZD", "HKD"]

    /// Positive magnitude + ISO code from a raw Shortcuts amount ("S$12.50", "12,50 €", "SGD 7.00").
    /// nil for blank, no digits, leftover junk, or zero.
    nonisolated static func parseAmount(_ raw: String, fallback: String) -> (amount: Decimal, currency: String)? {
        let code = raw.split { !$0.isLetter }.map { $0.uppercased() }
            .first { $0.count == 3 && Locale.commonISOCurrencyCodes.contains($0) }
        let symbol = symbols.first { raw.contains($0.0) }?.1
        let currency = code ?? symbol
            ?? (raw.contains("$") ? (dollarCurrencies.contains(fallback) ? fallback : "USD")
                : raw.contains("¥") ? (["JPY", "CNY"].contains(fallback) ? fallback : "JPY") : fallback)

        var rest = code.map { raw.replacingOccurrences(of: $0, with: "", options: .caseInsensitive) } ?? raw
        for marker in symbols.map(\.0) + ["$", "¥"] { rest = rest.replacingOccurrences(of: marker, with: "") }
        rest.removeAll { $0.isWhitespace || "'’-+−".contains($0) }
        guard rest.contains(where: \.isASCIIDigit), rest.allSatisfy({ $0.isASCIIDigit || $0 == "." || $0 == "," })
        else { return nil }

        let dots = rest.count { $0 == "." }, commas = rest.count { $0 == "," }
        let decimal: Character?
        if let dot = rest.lastIndex(of: "."), let comma = rest.lastIndex(of: ",") {
            decimal = dot > comma ? "." : ","
        } else if let sep: Character = commas > 0 ? "," : dots > 0 ? "." : nil {
            // Lone separator is decimal only with 1-2 digits after: "12,50" / "12.5" vs "1,234" / "1.234".
            let digitsAfter = rest.distance(from: rest.lastIndex(of: sep)!, to: rest.endIndex) - 1
            decimal = (sep == "," ? commas : dots) == 1 && (1...2).contains(digitsAfter) ? sep : nil
        } else {
            decimal = nil
        }

        var number = rest.filter(\.isASCIIDigit)
        if let decimal, let index = rest.lastIndex(of: decimal) {
            let whole = rest[..<index].filter { $0 != (decimal == "." ? "," : ".") }
            guard !whole.contains(decimal) else { return nil }
            number = whole + "." + rest[rest.index(after: index)...]
        }
        guard let amount = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")), amount != 0
        else { return nil }
        return (amount, currency)
    }

    /// Card identity = its mapped account (Transaction has no card field; same card always maps to the same account).
    static func isDuplicate(amount: Decimal, merchant: String, account: Account, date: Date,
                            in transactions: [Transaction]) -> Bool {
        let key = Categorizer.normalize(merchant)
        return transactions.contains {
            $0.source == .applePay && $0.account?.id == account.id && $0.amount == amount
                && abs($0.date.timeIntervalSince(date)) <= duplicateWindow && Categorizer.normalize($0.merchant) == key
        }
    }

    private static func cards(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: cardsKey) as? [String: String] ?? [:]
    }

    /// Mapped account for the card (trimmed, case-insensitive), else the default; archived/missing accounts skipped.
    static func account(forCard card: String, in accounts: [Account], defaults: UserDefaults = .standard) -> Account? {
        let name = card.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = cards(defaults).first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        func live(_ id: String?) -> Account? { accounts.first { !$0.archived && $0.id.uuidString == id } }
        return live(mapped) ?? live(defaults.string(forKey: defaultKey))
    }

    /// Record a seen card as unmapped ("") unless already known. Blank card = no-op.
    static func remember(card: String, defaults: UserDefaults = .standard) {
        let name = card.trimmingCharacters(in: .whitespacesAndNewlines)
        var cards = cards(defaults)
        guard !Storage.inMemory, !name.isEmpty,  // seeded sample data must never write real settings
              !cards.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        cards[name] = ""
        defaults.set(cards, forKey: cardsKey)
    }
}

extension ApplePay {
    /// Shortcuts Transaction automation entry point: map card, parse, dedupe, categorize, save. Dialog for Siri/Shortcuts.
    @MainActor
    static func log(amount raw: String, merchant: String, card: String, date: Date, context: ModelContext,
                    defaults: UserDefaults = .standard,
                    modelAvailable: Bool = OnDeviceAI.unavailableReason == nil) async -> (dialog: String, saved: Transaction?) {
        remember(card: card, defaults: defaults)
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard let account = account(forCard: card, in: accounts, defaults: defaults) else {
            return ("Choose a default Apple Pay account in mise: Money → Apple Pay.", nil)
        }
        guard let parse = parseAmount(raw, fallback: account.currency) else {
            return ("Couldn't read the amount \"\(raw)\".", nil)
        }
        let signed = -parse.amount  // Apple Pay taps are outflows
        let merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = parse.amount.formatted(.currency(code: parse.currency)) + (merchant.isEmpty ? "" : " at \(merchant)")
        let (lo, hi) = (date.addingTimeInterval(-duplicateWindow), date.addingTimeInterval(duplicateWindow))
        let nearby = (try? context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.date >= lo && $0.date <= hi }))) ?? []
        if isDuplicate(amount: signed, merchant: merchant, account: account, date: date, in: nearby) {
            return ("Already logged \(label).", nil)
        }
        let transaction = Transaction(amount: signed, currency: parse.currency, date: date)
        context.insert(transaction)
        transaction.merchant = merchant
        transaction.account = account
        transaction.source = .applePay
        // Save before the (possibly slow) model call so a background kill doesn't lose the purchase.
        do { try context.save() } catch {
            context.delete(transaction)
            return ("Couldn't save the transaction. Open mise and try again.", nil)
        }
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        transaction.category = await Categorizer.suggest(merchant: merchant, amount: signed, categories: categories,
                                                         defaults: defaults, modelAvailable: modelAvailable)
        transaction.categoryIsAuto = transaction.category != nil
        try? context.save()  // failure keeps the saved uncategorized transaction
        return ("Logged \(label).", transaction)
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}
