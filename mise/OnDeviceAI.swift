import Foundation
import FoundationModels

enum OnDeviceAI {
    /// nil when the on-device model is ready; otherwise a user-facing reason.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This device doesn't support Apple Intelligence. Manual entry still works."
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to use smart capture. Manual entry still works."
        case .unavailable(.modelNotReady): "The on-device model is still downloading. Manual entry still works."
        case .unavailable: "On-device AI is unavailable. Manual entry still works."
        }
    }
}

@Generable
struct QuickCapture {
    @Generable
    enum Kind {
        case expense, task, note
    }

    @Guide(description: "expense if money was spent, task if something must be done, otherwise note")
    var kind: Kind
    @Guide(description: "Short title, e.g. 'Coffee' or 'Call mom'")
    var title: String
    @Guide(description: "Amount of money (the total for receipts), or nil")
    var amount: Double?
    @Guide(description: "ISO 4217 currency code like USD, EUR, GBP if stated or implied by a symbol, else nil")
    var currency: String?
    @Guide(description: "Merchant or shop name, or nil")
    var merchant: String?
    @Guide(description: "Spending category like Food, Transport, Housing, Subscriptions, or nil")
    var category: String?
    @Guide(description: "ISO 8601 local date-time like 2026-01-31T18:00:00 if a date or time is mentioned, relative to now, else nil")
    var due: String?

    static func parse(_ text: String, now: Date) async throws -> QuickCapture {
        let session = LanguageModelSession(instructions: """
            Classify a quick-capture entry from a personal organizer app and extract its fields. \
            Any entry containing a price or amount of money is an expense. \
            A place or shop where money was spent is the merchant. \
            Resolve relative dates and times ("tomorrow 6pm") against now. \
            Only fill fields that the text supports; leave currency nil unless a code or symbol is present.
            """)
        let nowText = now.formatted(Date.ISO8601FormatStyle(timeZone: .current))
        let weekday = now.formatted(.dateTime.weekday(.wide))
        return try await session.respond(
            to: "Now is \(weekday) \(nowText).\nEntry: \(text)",
            generating: QuickCapture.self
        ).content
    }
}
