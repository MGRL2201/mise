import Foundation
import SwiftData

// Finance models (#33). Same rules as Storage.swift: every stored property has
// a default, no @Attribute(.unique), relationships optional (CloudKit-compatible).
// Money is `Decimal`; `currency` is an ISO 4217 code next to every amount.

enum AccountType: String, Codable, CaseIterable {
    case cash, debit, credit, brokerage
}

enum TransactionSource: String, Codable {
    case manual, imported, applePay
}

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var type: AccountType = AccountType.cash
    var currency: String = ""
    var openingBalance: Decimal = 0
    var archived: Bool = false
    var createdAt: Date = Date()
    @Relationship(deleteRule: .nullify, inverse: \Transaction.account) var transactions: [Transaction]? = []
    @Relationship(deleteRule: .nullify, inverse: \Transfer.from) var outgoingTransfers: [Transfer]? = []
    @Relationship(deleteRule: .nullify, inverse: \Transfer.to) var incomingTransfers: [Transfer]? = []

    init(name: String, type: AccountType, currency: String, openingBalance: Decimal = 0) {
        self.name = name
        self.type = type
        self.currency = currency
        self.openingBalance = openingBalance
    }
}

@Model
final class Category {
    var id: UUID = UUID()
    var name: String = ""
    /// SF Symbol name.
    var icon: String = "tag"
    /// 0xRRGGBB; UI reads it as `Color.Resolved(UInt32(color))` (Theme.swift).
    var color: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category) var transactions: [Transaction]? = []

    init(name: String, icon: String = "tag", color: Int = 0) {
        self.name = name
        self.icon = icon
        self.color = color
    }
}

/// A money movement on one account. `amount` is SIGNED from the account's
/// point of view: negative = money out (expense, purchase, card charge),
/// positive = money in (income, refund).
@Model
final class Transaction {
    var id: UUID = UUID()
    var amount: Decimal = 0
    var currency: String = ""
    var date: Date = Date()
    var merchant: String = ""
    var notes: String = ""
    var account: Account?
    var category: Category?
    /// Set by auto-categorization (#154); user edits clear it.
    var categoryIsAuto: Bool = false
    /// Id of an `Attachment` (Storage.swift) holding the receipt/PDF.
    var attachmentID: UUID?
    var source: TransactionSource = TransactionSource.manual
    /// Amount in the home currency at the transaction date's FX rate. Filled by #34; nil until then.
    var homeAmount: Decimal?

    init(amount: Decimal, currency: String, date: Date) {
        self.amount = amount
        self.currency = currency
        self.date = date
    }
}

/// Money moved between two own accounts. `amount` (positive) leaves `from` in
/// its currency; `toAmount` (positive) arrives in `to` in its currency — equal
/// for same-currency, different for cross-currency (#36). A credit-card payment
/// is a Transfer from debit/cash to the credit account. Transfers are a separate
/// model, so they never count as spending.
@Model
final class Transfer {
    var id: UUID = UUID()
    var from: Account?
    var to: Account?
    var amount: Decimal = 0
    var toAmount: Decimal = 0
    var date: Date = Date()
    var notes: String = ""

    init(amount: Decimal, toAmount: Decimal, date: Date) {
        self.amount = amount
        self.toAmount = toAmount
        self.date = date
    }
}

enum Finance {
    /// Opening balance + own-currency transactions − transfers out + transfers in.
    /// Credit accounts go negative when owed.
    static func balance(of account: Account) -> Decimal {
        // ponytail: transactions in another currency than the account are skipped until #34/#36 decide how foreign charges convert to account currency.
        let transactions = (account.transactions ?? []).filter { $0.currency == account.currency }.reduce(Decimal(0)) { $0 + $1.amount }
        let outgoing = (account.outgoingTransfers ?? []).reduce(Decimal(0)) { $0 + $1.amount }
        let incoming = (account.incomingTransfers ?? []).reduce(Decimal(0)) { $0 + $1.toAmount }
        return account.openingBalance + transactions - outgoing + incoming
    }

    /// Outflows in `range` (half-open: start <= date < end), as positive totals per currency code.
    // ponytail: refunds don't reduce spend; net them out if budgets need it.
    static func spend(_ transactions: [Transaction], in range: DateInterval) -> [String: Decimal] {
        transactions
            .filter { $0.amount < 0 && range.start <= $0.date && $0.date < range.end }
            .reduce(into: [:]) { $0[$1.currency, default: 0] -= $1.amount }
    }
}
