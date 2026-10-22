import Foundation
import SwiftData
import FoundationModels

/// Auto-categorization (#154): learned merchant rules first, on-device model fallback.
/// One entry point for manual entry, imports and Apple Pay (#153): `suggest`.
enum Categorizer {
    static let rulesKey = "finance.merchantRules"   // [normalized merchant: category uuidString]

    private static let companySuffixes: Set = ["pte", "ltd", "limited", "inc", "llc", "co", "corp", "sdn", "bhd"]
    // ponytail: small fixed location list; extend when imports show more.
    private static let locations: Set = ["sg", "sgp", "singapore", "us", "usa", "uk", "gb", "my", "hk"]

    /// Pure. Lowercase, diacritics folded; drop "#123"-style store numbers; delete . ' ’ - (so "7-Eleven" -> "7eleven",
    /// "McDonald's" -> "mcdonalds", "Pte. Ltd." -> "pte ltd"); other punctuation/symbols -> space ("GRAB*RIDE" -> "grab ride");
    /// drop all-digit tokens of 3+ digits; drop trailing company suffix and location tokens; collapse whitespace.
    /// If the result would be empty, return the folded lowercased input, trimmed and whitespace-collapsed.
    static func normalize(_ merchant: String) -> String {
        let folded = merchant.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var text = folded.replacing(/#\d+/, with: " ")
        text.removeAll { ".'’-".contains($0) }
        var tokens = String(text.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").map(String.init)
            .filter { !($0.count >= 3 && $0.allSatisfy(\.isNumber)) }
        while let last = tokens.last, companySuffixes.contains(last) || locations.contains(last) { tokens.removeLast() }
        return (tokens.isEmpty ? folded.split(whereSeparator: \.isWhitespace).map(String.init) : tokens).joined(separator: " ")
    }

    private static func rules(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: rulesKey) as? [String: String] ?? [:]
    }

    /// Rule category for this merchant among `categories` (stale ids and income categories resolve to nil).
    static func rule(for merchant: String, in categories: [Category], defaults: UserDefaults = .standard) -> Category? {
        guard let id = rules(defaults)[normalize(merchant)] else { return nil }
        return categories.first { !$0.isIncome && $0.id.uuidString == id }
    }

    /// Record the user's choice. nil category removes the rule. Empty normalized merchant = no-op.
    static func learn(_ merchant: String, category: Category?, defaults: UserDefaults = .standard) {
        let key = normalize(merchant)
        guard !Storage.inMemory, !key.isEmpty else { return }  // seeded sample data must never write real rules
        var rules = rules(defaults)
        rules[key] = category?.id.uuidString
        defaults.set(rules, forKey: rulesKey)
    }

    /// Rule, else the on-device model; nil = Uncategorized. Never throws; model errors -> nil.
    /// Skip the model when `modelAvailable` is false, merchant is blank, or categories is empty.
    @MainActor
    static func suggest(merchant: String, amount: Decimal, categories: [Category],
                        defaults: UserDefaults = .standard,
                        modelAvailable: Bool = OnDeviceAI.unavailableReason == nil) async -> Category? {
        let categories = categories.filter { !$0.isIncome }  // outflow-only: income is never suggested
        if let rule = rule(for: merchant, in: categories, defaults: defaults) { return rule }
        let merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        var names: [String] = []  // case-insensitive dedupe; "Uncategorized" only if no category has that name
        for name in categories.map(\.name) + ["Uncategorized"]
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        guard modelAvailable, !merchant.isEmpty, !categories.isEmpty,
              let schema = try? GenerationSchema(
                root: DynamicGenerationSchema(name: "Category", anyOf: names),
                dependencies: [])
        else { return nil }
        let session = LanguageModelSession(instructions: """
            Pick the spending category for a card transaction from the merchant name and amount. \
            Answer Uncategorized unless one category clearly fits.
            """)
        let prompt = "Merchant: \(merchant)\nAmount: \(abs(amount))"
        guard let name = try? await session.respond(to: prompt, schema: schema).content.value(String.self) else { return nil }
        return Budgets.named(name, in: categories)
    }

    /// Sets every uncategorized or auto-categorized transaction whose normalized merchant equals `merchant`'s to
    /// `category` (categoryIsAuto = false on those), saves, returns the count whose category changed.
    /// Manual picks and inflows are left untouched. Blank merchant = no-op.
    @MainActor
    static func applyToAll(merchant: String, category: Category?, context: ModelContext) -> Int {
        let key = normalize(merchant)
        guard !key.isEmpty else { return 0 }
        // ponytail: fetches every transaction and normalizes in memory; add a stored normalized column if this gets slow.
        let matches = ((try? context.fetch(FetchDescriptor<Transaction>())) ?? [])
            .filter { $0.amount < 0 && ($0.category == nil || $0.categoryIsAuto) && normalize($0.merchant) == key }
        var changed = 0
        for transaction in matches {
            transaction.categoryIsAuto = false
            if transaction.category !== category {
                transaction.category = category
                changed += 1
            }
        }
        try? context.save()
        return changed
    }
}
