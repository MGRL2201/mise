import Foundation

/// Pure helpers behind manual transaction entry and transfers (#36).
enum TransactionEntry {
    /// The sign comes from the income/expense toggle only; a typed "-12" is just 12.
    static func signed(_ magnitude: Decimal, income: Bool) -> Decimal {
        income ? abs(magnitude) : -abs(magnitude)
    }

    /// Past merchants starting with `text` (case/diacritic-insensitive), most used first,
    /// first-seen spelling kept; the exact text itself is not suggested.
    static func merchantSuggestions(_ text: String, from merchants: [String], limit: Int = 5) -> [String] {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for merchant in merchants where merchant.range(of: text, options: options) != nil {
            let key = merchant.lowercased()
            counts[key, default: 0] += 1
            if spelling[key] == nil { spelling[key] = merchant }
        }
        counts[text.lowercased()] = nil
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .compactMap { spelling[$0.key] }
    }

    /// nil when the transfer can be saved, else a short reason.
    static func transferError(from: Account?, to: Account?, amount: Decimal?, toAmount: Decimal?) -> String? {
        guard let from, let to else { return "Choose both accounts" }
        if from === to { return "Choose two different accounts" }
        guard let amount, amount > 0 else { return "Enter an amount" }
        if from.currency != to.currency, (toAmount ?? 0) <= 0 { return "Enter the amount received" }
        return nil
    }

    static func matches(_ transaction: Transaction, search: String) -> Bool {
        let search = search.trimmingCharacters(in: .whitespaces)
        if search.isEmpty { return true }
        return transaction.merchant.localizedStandardContains(search)
            || transaction.notes.localizedStandardContains(search)
    }
}
