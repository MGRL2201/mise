import SwiftUI
import SwiftData
import RegexBuilder

/// Money tab home: net worth, accounts by type, archived accounts (#35).
struct FinanceView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @State private var rates = FXRates()
    @State private var isAdding = false
    @State private var askHome = false
    @AppStorage(FX.homeKey) private var home = FX.home()
    @AppStorage("finance.homeConfirmed") private var confirmed = false

    var body: some View {
        Group {
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No accounts", systemImage: "banknote")
                } description: {
                    Text("Add an account to start tracking balances.")
                } actions: {
                    Button("Add Account") { isAdding = true }
                }
            } else {
                list
            }
        }
        .navigationTitle("Money")
        .themedBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Account", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) { AccountEditor(account: nil) }
        .sheet(isPresented: $askHome, onDismiss: { confirmed = true }) { HomeCurrencySheet() }
        .onAppear {
            if accounts.isEmpty && !confirmed { askHome = true }
        }
        .task {
            rates = .load()
            await FX.refresh(context: modelContext)
            rates = .load()
        }
    }

    private var list: some View {
        let archived = accounts.filter(\.archived)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let worth = Accounts.netWorth(
            accounts.map { (amount: Finance.balance(of: $0, rates: rates), currency: $0.currency) },
            rates: rates, home: home
        )
        return Form {
            Section("Net worth") {
                Text(worth.total, format: .currency(code: home)).font(.title2)
                ForEach(worth.unconverted.filter { $0.value != 0 }.sorted { $0.key < $1.key }, id: \.key) { code, amount in
                    Text("\(amount.formatted(.currency(code: code))) (no rate)").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color(theme.surface))
            ForEach(Accounts.grouped(accounts), id: \.type) { group in
                Section(group.type.rawValue.capitalized) {
                    ForEach(group.accounts, content: row)
                }
                .listRowBackground(Color(theme.surface))
            }
            if !archived.isEmpty {
                Section {
                    DisclosureGroup("Archived (\(archived.count))") {
                        ForEach(archived, content: row)
                    }
                }
                .listRowBackground(Color(theme.surface))
            }
        }
    }

    private func row(_ account: Account) -> some View {
        NavigationLink {
            AccountDetailView(account: account, rates: rates)
        } label: {
            LabeledContent(account.name) {
                Text(Finance.balance(of: account, rates: rates), format: .currency(code: account.currency))
            }
        }
    }
}

/// One-time prompt before the first account: which currency totals use.
private struct HomeCurrencySheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FX.homeKey) private var home = FX.home()
    @State private var picked = FX.home()

    var body: some View {
        NavigationStack {
            Form {
                Text("Totals are shown in this currency.")
                CurrencyPicker(title: "Home currency", selection: $picked)
                Button("Confirm") {
                    if picked != home {
                        home = picked
                        Task { await FX.rebase(context: modelContext) }
                    }
                    dismiss()
                }
            }
            .navigationTitle("Home currency")
            .themedBackground()
        }
        .presentationDetents([.medium])
    }
}

struct CurrencyPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Locale.commonISOCurrencyCodes, id: \.self) { code in
                Text("\(code) – \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
            }
        }
    }
}

/// New or existing account. Delete only while nothing references it; otherwise archive.
struct AccountEditor: View {
    let account: Account?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var type: AccountType
    @State private var currency: String
    @State private var opening: String
    @State private var archived: Bool
    @State private var confirmingDelete = false

    init(account: Account?) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _type = State(initialValue: account?.type ?? .cash)
        _currency = State(initialValue: account?.currency ?? FX.home())
        _opening = State(initialValue: account.map { $0.openingBalance.formatted(.number.grouping(.never)) } ?? "")
        _archived = State(initialValue: account?.archived ?? false)
    }

    /// nil once deleted: the sheet still renders during dismissal and must not read a dead model.
    private var live: Account? {
        guard let account, !account.isDeleted, account.modelContext != nil else { return nil }
        return account
    }

    /// nil = unparseable; empty = 0. Whole-match so "12abc" / "1.2.3" are rejected, not truncated
    /// (Decimal(string:) and Decimal(_:format:) both silently parse a prefix).
    private var openingValue: Decimal? {
        let text = opening.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        return try? Regex { Capture(Decimal.FormatStyle(locale: .current)) }.wholeMatch(in: text)?.1
    }

    private var canDelete: Bool {
        guard let account = live else { return false }
        return (account.transactions ?? []).isEmpty
            && (account.outgoingTransfers ?? []).isEmpty
            && (account.incomingTransfers ?? []).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    CurrencyPicker(title: "Currency", selection: $currency)
                        .disabled(live != nil && !canDelete)
                    TextField("Opening balance", text: $opening)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                } footer: {
                    if type == .credit { Text("Enter money owed as a negative amount.") }
                }
                if let account = live {
                    Section {
                        Toggle("Archived", isOn: $archived)
                        if canDelete {
                            Button("Delete Account", role: .destructive) { confirmingDelete = true }
                                .confirmationDialog("Delete \(account.name)?", isPresented: $confirmingDelete) {
                                    Button("Delete", role: .destructive) {
                                        modelContext.delete(account)
                                        try? modelContext.save()
                                        dismiss()
                                    }
                                }
                        }
                    } footer: {
                        if !canDelete { Text("Accounts with transactions can be archived, not deleted.") }
                    }
                }
            }
            .navigationTitle(account == nil ? "New Account" : "Edit Account")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || openingValue == nil)
                }
            }
        }
    }

    private func save() {
        guard let openingValue else { return }
        let target = account ?? Account(name: "", type: type, currency: currency)
        if account == nil { modelContext.insert(target) }
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.type = type
        target.currency = currency
        target.openingBalance = openingValue
        target.archived = archived
        try? modelContext.save()
        dismiss()
    }
}

/// Read-only account: balance and transactions by day.
struct AccountDetailView: View {
    let account: Account
    let rates: FXRates
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    var body: some View {
        Group {
            // Deleted from the editor: pop instead of reading a dead model.
            if account.isDeleted || account.modelContext == nil {
                Color.clear
            } else {
                form
            }
        }
        .themedBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing, onDismiss: {
            if account.isDeleted || account.modelContext == nil { dismiss() }
        }) { AccountEditor(account: account) }
    }

    private var form: some View {
        let days = Accounts.days(account.transactions ?? [])
        return Form {
            Section {
                LabeledContent("Balance") {
                    Text(Finance.balance(of: account, rates: rates), format: .currency(code: account.currency))
                }
            }
            .listRowBackground(Color(theme.surface))
            if days.isEmpty {
                Section { Text("No transactions yet").foregroundStyle(.secondary) }
                    .listRowBackground(Color(theme.surface))
            }
            ForEach(days, id: \.day) { day in
                Section(day.day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(day.transactions) { transaction in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(transaction.merchant.isEmpty ? "Transaction" : transaction.merchant)
                                if let category = transaction.category {
                                    Text(category.name).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(transaction.amount, format: .currency(code: transaction.currency))
                                .foregroundStyle(transaction.amount > 0 ? .green : .primary)
                        }
                    }
                }
                .listRowBackground(Color(theme.surface))
            }
        }
        .navigationTitle(account.name)
    }
}
