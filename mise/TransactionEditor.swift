import SwiftUI
import SwiftData

/// Non-archived accounts by name, plus `keeping` (current selections) even if archived.
private func choices(_ accounts: [Account], keeping: [Account?]) -> [Account] {
    accounts.filter { account in !account.archived || keeping.contains { $0 == account } }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// New or existing transaction (#36).
struct TransactionEditor: View {
    let transaction: Transaction?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @Query private var transactions: [Transaction]
    @State private var income: Bool
    @State private var amount: String
    @State private var account: Account?
    @State private var currency: String
    @State private var charged: String
    @State private var date: Date
    @State private var merchant: String
    @State private var category: Category?
    @State private var newCategory = ""
    @State private var notes: String
    @State private var confirmingDelete = false

    init(transaction: Transaction?, account: Account? = nil) {
        self.transaction = transaction
        let account = account ?? transaction?.account
        _income = State(initialValue: (transaction?.amount ?? 0) > 0)
        _amount = State(initialValue: transaction.map { Accounts.plain(abs($0.amount)) } ?? "")
        _account = State(initialValue: account)
        _currency = State(initialValue: transaction?.currency ?? account?.currency ?? FX.home())
        _charged = State(initialValue: transaction?.accountAmount.map { Accounts.plain(abs($0)) } ?? "")
        _date = State(initialValue: transaction?.date ?? .now)
        _merchant = State(initialValue: transaction?.merchant ?? "")
        _category = State(initialValue: transaction?.category)
        _notes = State(initialValue: transaction?.notes ?? "")
    }

    /// nil once deleted: the sheet still renders during dismissal and must not read a dead model.
    private var live: Transaction? {
        guard let transaction, !transaction.isDeleted, transaction.modelContext != nil else { return nil }
        return transaction
    }

    private var foreign: Bool { account.map { $0.currency != currency } ?? false }
    private var amountValue: Decimal? { Accounts.parseAmount(amount).flatMap { $0 == 0 ? nil : $0 } }
    /// 0 = no charged amount (hidden or empty); nil = unparseable.
    private var chargedValue: Decimal? { foreign ? Accounts.parseAmount(charged) : 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $income) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Amount", text: $amount)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    Picker("Account", selection: $account) {
                        Text("Choose").tag(Account?.none)
                        ForEach(choices(accounts, keeping: [account]), id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    CurrencyPicker(title: "Currency", selection: $currency)
                    if let account, foreign {
                        TextField("Charged in \(account.currency)", text: $charged)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    DatePicker("Date", selection: $date)
                } footer: {
                    if choices(accounts, keeping: [account]).isEmpty { Text("Add an account first") }
                    if foreign { Text("Optional. Used for the account balance instead of the FX rate.") }
                }
                Section {
                    TextField("Merchant", text: $merchant)
                    ForEach(TransactionEntry.merchantSuggestions(merchant, from: transactions.map(\.merchant)), id: \.self) { suggestion in
                        Button(suggestion) { merchant = suggestion }
                    }
                }
                Section {
                    Picker("Category", selection: $category) {
                        Text("None").tag(Category?.none)
                        ForEach(categories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.self) {
                            Text($0.name).tag(Optional($0))
                        }
                    }
                    HStack {
                        TextField("New category", text: $newCategory)
                            .onSubmit(addCategory)
                        Button("Add", action: addCategory)
                            .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if let transaction = live {
                    Section {
                        Button("Delete Transaction", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete this transaction?", isPresented: $confirmingDelete) {
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(transaction)
                                    try? modelContext.save()
                                    dismiss()
                                }
                            }
                    }
                }
            }
            .navigationTitle(transaction == nil ? "New Transaction" : "Edit Transaction")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(amountValue == nil || chargedValue == nil || account == nil)
                }
            }
            .onAppear {
                if account == nil && transaction == nil { account = choices(accounts, keeping: []).first }
            }
            .onChange(of: account) { old, new in
                if old?.currency != new?.currency { charged = "" }
                // Follow the account's currency unless the user picked a different one;
                // a new transaction with no account yet takes the first account's.
                if let new, currency == old?.currency || (old == nil && transaction == nil) { currency = new.currency }
            }
        }
    }

    // ponytail: inserted immediately, so Cancel keeps a new category; full management is #37.
    private func addCategory() {
        let name = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            category = existing
        } else {
            let created = Category(name: name)
            modelContext.insert(created)
            category = created
        }
        newCategory = ""
    }

    private func save() {
        guard let value = amountValue, let chargedValue, let account else { return }
        let target = transaction ?? Transaction(amount: 0, currency: currency, date: date)
        if transaction == nil { modelContext.insert(target) }
        target.amount = TransactionEntry.signed(value, income: income)
        target.currency = currency
        target.date = date
        target.merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.account = account
        if target.category != category { target.categoryIsAuto = false }
        target.category = category
        // Also clears a stale charge when the account or currency changed.
        target.accountAmount = chargedValue == 0 ? nil : TransactionEntry.signed(chargedValue, income: income)
        target.homeAmount = nil // FX.refresh refills it for the new amount/currency/date.
        try? modelContext.save()
        let context = modelContext
        Task { await FX.refresh(context: context) }
        dismiss()
    }
}

/// New or existing transfer between own accounts (#36).
struct TransferEditor: View {
    let transfer: Transfer?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @State private var from: Account?
    @State private var to: Account?
    @State private var amount: String
    @State private var received: String
    @State private var date: Date
    @State private var notes: String
    @State private var confirmingDelete = false

    init(transfer: Transfer?, from: Account? = nil, to: Account? = nil) {
        self.transfer = transfer
        _from = State(initialValue: transfer?.from ?? from)
        _to = State(initialValue: transfer?.to ?? to)
        _amount = State(initialValue: transfer.map { Accounts.plain($0.amount) } ?? "")
        _received = State(initialValue: transfer.map { $0.from?.currency != $0.to?.currency ? Accounts.plain($0.toAmount) : "" } ?? "")
        _date = State(initialValue: transfer?.date ?? .now)
        _notes = State(initialValue: transfer?.notes ?? "")
    }

    private var live: Transfer? {
        guard let transfer, !transfer.isDeleted, transfer.modelContext != nil else { return nil }
        return transfer
    }

    private var crossCurrency: Bool {
        guard let from, let to else { return false }
        return from.currency != to.currency
    }

    private var error: String? {
        TransactionEntry.transferError(
            from: from, to: to, amount: Accounts.parseAmount(amount), toAmount: Accounts.parseAmount(received)
        )
    }

    var body: some View {
        let options = choices(accounts, keeping: [from, to])
        NavigationStack {
            Form {
                Section {
                    Picker("From", selection: $from) {
                        Text("Choose").tag(Account?.none)
                        ForEach(options, id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    Picker("To", selection: $to) {
                        Text("Choose").tag(Account?.none)
                        ForEach(options, id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    TextField("Amount \(from?.currency ?? "")", text: $amount)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    if crossCurrency, let to {
                        TextField("Received \(to.currency)", text: $received)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    DatePicker("Date", selection: $date)
                    TextField("Notes", text: $notes, axis: .vertical)
                } footer: {
                    VStack(alignment: .leading) {
                        if let error { Text(error) }
                        Text("Paying a credit card? Transfer to the card account.")
                    }
                }
                if let transfer = live {
                    Section {
                        Button("Delete Transfer", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete this transfer?", isPresented: $confirmingDelete) {
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(transfer)
                                    try? modelContext.save()
                                    dismiss()
                                }
                            }
                    }
                }
            }
            .navigationTitle(transfer == nil ? "New Transfer" : "Edit Transfer")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(error != nil)
                }
            }
            .onAppear {
                if transfer == nil && from == nil { from = options.first { $0 != to } }
            }
            .onChange(of: from?.currency) { old, new in if old != new { received = "" } }
            .onChange(of: to?.currency) { old, new in if old != new { received = "" } }
        }
    }

    private func save() {
        guard error == nil, let value = Accounts.parseAmount(amount) else { return }
        let target = transfer ?? Transfer(amount: 0, toAmount: 0, date: date)
        if transfer == nil { modelContext.insert(target) }
        target.amount = value
        target.toAmount = crossCurrency ? Accounts.parseAmount(received) ?? 0 : value
        target.from = from
        target.to = to
        target.date = date
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        dismiss()
    }
}
