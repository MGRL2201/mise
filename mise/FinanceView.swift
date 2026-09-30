import SwiftUI
import SwiftData

/// Money tab home: net worth, accounts by type, archived accounts (#35).
struct FinanceView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @State private var rates = FXRates()
    @State private var isAdding = false
    @State private var newTransaction = false
    @State private var newTransfer = false
    @State private var askHome = false
    #if DEBUG
    @State private var debugOpened = false
    @State private var showingAll = false
    @State private var showingBudgets = false
    #endif
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
                Menu("Add", systemImage: "plus") {
                    Group {
                        Button("New Transaction", systemImage: "list.bullet.rectangle") { newTransaction = true }
                        Button("New Transfer", systemImage: "arrow.left.arrow.right") { newTransfer = true }
                    }
                    .disabled(!accounts.contains { !$0.archived })
                    Button("New Account", systemImage: "banknote") { isAdding = true }
                }
            }
        }
        #if DEBUG
        .navigationDestination(isPresented: $showingAll) { AllTransactionsView() }
        .navigationDestination(isPresented: $showingBudgets) { BudgetsView() }
        #endif
        .sheet(isPresented: $isAdding) { AccountEditor(account: nil) }
        .sheet(isPresented: $newTransaction) { TransactionEditor(transaction: nil) }
        .sheet(isPresented: $newTransfer) { TransferEditor(transfer: nil) }
        .sheet(isPresented: $askHome, onDismiss: { confirmed = true }) { HomeCurrencySheet() }
        .onAppear {
            if accounts.isEmpty && !confirmed { askHome = true }
            #if DEBUG
            // Screenshot hook: `-miseMoney transaction|transfer|all|budgets`, once per launch.
            if !debugOpened {
                debugOpened = true
                switch UserDefaults.standard.string(forKey: "miseMoney") {
                case "transaction": newTransaction = true
                case "transfer": newTransfer = true
                case "all": showingAll = true
                case "budgets": showingBudgets = true
                default: break
                }
            }
            #endif
        }
        .task {
            if !Storage.inMemory { Budgets.addStarterCategories(context: modelContext) }
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
            Section {
                NavigationLink("All Transactions") { AllTransactionsView() }
                NavigationLink("Budgets") { BudgetsView() }
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
        _opening = State(initialValue: account.map { Accounts.plain($0.openingBalance) } ?? "")
        _archived = State(initialValue: account?.archived ?? false)
    }

    /// nil once deleted: the sheet still renders during dismissal and must not read a dead model.
    private var live: Account? {
        guard let account, !account.isDeleted, account.modelContext != nil else { return nil }
        return account
    }

    private var openingValue: Decimal? { Accounts.parseAmount(opening) }

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

/// Account: balance, transactions by day, transfers; rows open their editors.
struct AccountDetailView: View {
    let account: Account
    @State private var rates: FXRates
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var editing = false
    @State private var newTransaction = false
    @State private var newTransfer = false
    @State private var payingCard = false
    @State private var editingTransaction: Transaction?
    @State private var editingTransfer: Transfer?

    init(account: Account, rates: FXRates) {
        self.account = account
        _rates = State(initialValue: rates)
    }

    /// Editors start FX.refresh on save without awaiting it; await one here, then pick up the rates.
    private func reloadRates() {
        Task {
            await FX.refresh(context: modelContext)
            rates = .load()
        }
    }

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
            ToolbarItem(placement: .primaryAction) {
                Menu("Add", systemImage: "plus") {
                    Button("New Transaction", systemImage: "list.bullet.rectangle") { newTransaction = true }
                    Button("New Transfer", systemImage: "arrow.left.arrow.right") { newTransfer = true }
                    if account.type == .credit {
                        Button("Pay Card", systemImage: "creditcard") { payingCard = true }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing, onDismiss: {
            if account.isDeleted || account.modelContext == nil { dismiss() }
        }) { AccountEditor(account: account) }
        .sheet(isPresented: $newTransaction, onDismiss: reloadRates) { TransactionEditor(transaction: nil, account: account) }
        .sheet(isPresented: $newTransfer, onDismiss: reloadRates) { TransferEditor(transfer: nil, from: account) }
        .sheet(isPresented: $payingCard, onDismiss: reloadRates) { TransferEditor(transfer: nil, to: account) }
        .sheet(item: $editingTransaction, onDismiss: reloadRates) { TransactionEditor(transaction: $0) }
        .sheet(item: $editingTransfer, onDismiss: reloadRates) { TransferEditor(transfer: $0) }
    }

    private var form: some View {
        let days = Accounts.days(account.transactions ?? [])
        let transfers = ((account.outgoingTransfers ?? []) + (account.incomingTransfers ?? [])).sorted { $0.date > $1.date }
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
                    ForEach(day.transactions) { TransactionRow(transaction: $0, editing: $editingTransaction) }
                }
                .listRowBackground(Color(theme.surface))
            }
            if !transfers.isEmpty {
                Section("Transfers") {
                    ForEach(transfers, content: transferRow)
                }
                .listRowBackground(Color(theme.surface))
            }
        }
        .navigationTitle(account.name)
    }

    private func transferRow(_ transfer: Transfer) -> some View {
        let outgoing = transfer.from == account
        return Button { editingTransfer = transfer } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(outgoing ? "To \(transfer.to?.name ?? "Unknown")" : "From \(transfer.from?.name ?? "Unknown")")
                    Text(transfer.date, format: .dateTime.day().month().year()).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(outgoing ? -transfer.amount : transfer.toAmount, format: .currency(code: account.currency))
                    .foregroundStyle(outgoing ? Color.primary : .green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Merchant, category and amount; the charge in the account's currency when it differs. Tap to edit.
struct TransactionRow: View {
    let transaction: Transaction
    @Binding var editing: Transaction?

    var body: some View {
        Button { editing = transaction } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transaction.merchant.isEmpty ? "Transaction" : transaction.merchant)
                    if let category = transaction.category {
                        Text(category.name).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(transaction.amount, format: .currency(code: transaction.currency))
                        .foregroundStyle(transaction.amount > 0 ? .green : .primary)
                    if let charged = transaction.accountAmount, let currency = transaction.account?.currency {
                        Text(charged, format: .currency(code: currency)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Every transaction by day, with search and account/category/month filters (#36).
struct AllTransactionsView: View {
    @Environment(\.theme) private var theme
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @State private var search = ""
    @State private var account: Account?
    @State private var category: Category?
    @State private var month: Date?
    @State private var editing: Transaction?

    var body: some View {
        let shown = transactions.filter {
            TransactionEntry.matches($0, search: search, account: account, category: category, month: month)
        }
        let filtered = account != nil || category != nil || month != nil
            || !search.trimmingCharacters(in: .whitespaces).isEmpty
        Group {
            if shown.isEmpty {
                if filtered {
                    ContentUnavailableView {
                        Label("No matching transactions", systemImage: "line.3.horizontal.decrease")
                    } actions: {
                        Button("Clear Filters") {
                            search = ""
                            account = nil
                            category = nil
                            month = nil
                        }
                    }
                } else {
                    ContentUnavailableView("No transactions", systemImage: "list.bullet.rectangle")
                }
            } else {
                Form {
                    ForEach(Accounts.days(shown), id: \.day) { day in
                        Section(day.day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(day.transactions) { TransactionRow(transaction: $0, editing: $editing) }
                        }
                        .listRowBackground(Color(theme.surface))
                    }
                }
            }
        }
        .navigationTitle("All Transactions")
        .themedBackground()
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Filter", systemImage: "line.3.horizontal.decrease") {
                    Picker("Account", selection: $account) {
                        Text("All").tag(Account?.none)
                        ForEach(accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.self) {
                            Text($0.name).tag(Optional($0))
                        }
                    }
                    Picker("Category", selection: $category) {
                        Text("All").tag(Category?.none)
                        ForEach(Budgets.ordered(categories), id: \.self) {
                            Text($0.name).tag(Optional($0))
                        }
                    }
                    Picker("Month", selection: $month) {
                        Text("All").tag(Date?.none)
                        ForEach(TransactionEntry.months(transactions), id: \.self) {
                            Text($0, format: .dateTime.month(.wide).year()).tag(Optional($0))
                        }
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .sheet(item: $editing) { TransactionEditor(transaction: $0) }
    }
}
