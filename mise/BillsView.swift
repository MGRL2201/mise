import SwiftUI
import SwiftData

/// Deletes a bill and drops its reminders.
private func deleteBill(_ bill: Bill, context: ModelContext) {
    context.delete(bill)
    try? context.save()
    Task { await Bills.sync(context: context, prompt: false) }
}

/// Recurring bills and subscriptions: monthly total, upcoming by due date, paused (#38).
struct BillsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Bill.nextDue) private var bills: [Bill]
    @State private var rates = FXRates()
    @State private var editing: Bill?
    @State private var isAdding = false
    @AppStorage(FX.homeKey) private var home = FX.home()

    var body: some View {
        let active = bills.filter(\.active)
        let paused = bills.filter { !$0.active }
        let total = Accounts.netWorth(
            active.map { (amount: Bills.monthlyAmount($0.amount, cadence: $0.cadence, interval: $0.interval), currency: $0.currency) },
            rates: rates, home: home
        )
        Group {
            if bills.isEmpty {
                ContentUnavailableView {
                    Label("No bills", systemImage: "calendar.badge.clock")
                } actions: {
                    Button("Add Bill") { isAdding = true }
                }
            } else {
                Form {
                    Section("Monthly total") {
                        Text(total.total, format: .currency(code: home)).font(.title2)
                        ForEach(total.unconverted.filter { $0.value != 0 }.sorted { $0.key < $1.key }, id: \.key) { code, amount in
                            Text("\(amount.formatted(.currency(code: code))) (no rate)").foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color(theme.surface))
                    if !active.isEmpty {
                        Section("Upcoming") { ForEach(active, content: row) }
                            .listRowBackground(Color(theme.surface))
                    }
                    if !paused.isEmpty {
                        Section("Paused") { ForEach(paused, content: row) }
                            .listRowBackground(Color(theme.surface))
                    }
                }
            }
        }
        .navigationTitle("Bills")
        .themedBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Bill", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) { BillEditor(bill: nil) }
        .sheet(item: $editing) { BillEditor(bill: $0) }
        .task { rates = .load() }
    }

    private func row(_ bill: Bill) -> some View {
        let overdue = bill.active && Bills.isOverdue(bill.nextDue, now: .now)
        let due = bill.nextDue.formatted(.dateTime.day().month().year())
        return Button { editing = bill } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.name)
                    Text(Bills.cadenceLabel(bill.cadence, interval: bill.interval))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(bill.amount, format: .currency(code: bill.currency))
                    Text(overdue ? "Overdue · \(due)" : due)
                        .font(.subheadline).foregroundStyle(overdue ? Color.red : .secondary)
                }
            }
            .foregroundStyle(bill.active ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button("Paid", systemImage: "checkmark") { markPaid(bill) }
                .tint(.green)
                .disabled(bill.account == nil)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleteBill(bill, context: modelContext) }
        }
        .contextMenu {
            Button("Mark Paid", systemImage: "checkmark") { markPaid(bill) }
                .disabled(bill.account == nil)
            Button("Delete", systemImage: "trash", role: .destructive) { deleteBill(bill, context: modelContext) }
        }
    }

    private func markPaid(_ bill: Bill) {
        guard bill.account != nil else { return }
        let context = modelContext
        let category = bill.category
        let date = Bills.markPaid(bill, context: context).date
        Task {
            await FX.refresh(context: context)
            await Budgets.checkAlerts(for: category, on: date, context: context)
            await Bills.sync(context: context, prompt: false)
        }
    }
}

/// New or existing bill (#38).
struct BillEditor: View {
    let bill: Bill?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @State private var name: String
    @State private var amount: String
    @State private var account: Account?
    @State private var currency: String
    @State private var category: Category?
    @State private var cadence: BillCadence
    @State private var interval: Int
    @State private var nextDue: Date
    @State private var remindDays: Int
    @State private var active: Bool
    @State private var confirmingDelete = false

    init(bill: Bill?) {
        self.bill = bill
        _name = State(initialValue: bill?.name ?? "")
        _amount = State(initialValue: bill.map { Accounts.plain($0.amount) } ?? "")
        _account = State(initialValue: bill?.account)
        _currency = State(initialValue: bill?.currency ?? FX.home())
        _category = State(initialValue: bill?.category)
        _cadence = State(initialValue: bill?.cadence ?? .monthly)
        _interval = State(initialValue: bill?.interval ?? 1)
        _nextDue = State(initialValue: bill?.nextDue ?? .now)
        _remindDays = State(initialValue: bill?.remindDays ?? 3)
        _active = State(initialValue: bill?.active ?? true)
    }

    /// nil once deleted: the sheet still renders during dismissal and must not read a dead model.
    private var live: Bill? {
        guard let bill, !bill.isDeleted, bill.modelContext != nil else { return nil }
        return bill
    }

    private var amountValue: Decimal? { Accounts.parseAmount(amount).flatMap { $0 > 0 ? $0 : nil } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Amount", text: $amount)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Picker("Account", selection: $account) {
                        Text("Choose").tag(Account?.none)
                        ForEach(choices(accounts, keeping: [account]), id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    CurrencyPicker(title: "Currency", selection: $currency)
                    Picker("Category", selection: $category) {
                        Text("None").tag(Category?.none)
                        ForEach(Budgets.ordered(categories), id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                } footer: {
                    if choices(accounts, keeping: [account]).isEmpty { Text("Add an account first") }
                }
                Section {
                    Picker("Repeats", selection: $cadence) {
                        ForEach(BillCadence.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Stepper(value: $interval, in: 1...12) { Text(Bills.cadenceLabel(cadence, interval: interval)) }
                    DatePicker("Next due", selection: $nextDue, displayedComponents: .date)
                    Stepper(value: $remindDays, in: 0...30) {
                        LabeledContent("Remind", value: remindDays == 0 ? "On due date only"
                                       : remindDays == 1 ? "1 day before" : "\(remindDays) days before")
                    }
                    Toggle("Active", isOn: $active)
                }
                if let bill = live {
                    Section {
                        Button("Delete Bill", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete \(bill.name)?", isPresented: $confirmingDelete) {
                                Button("Delete", role: .destructive) {
                                    deleteBill(bill, context: modelContext)
                                    dismiss()
                                }
                            }
                    }
                }
            }
            .navigationTitle(bill == nil ? "New Bill" : "Edit Bill")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmed.isEmpty || amountValue == nil || account == nil || (bill != nil && live == nil))
                }
            }
            .onAppear {
                if account == nil && bill == nil { account = choices(accounts, keeping: []).first }
            }
            .onChange(of: account) { old, new in
                // Same rule as TransactionEditor: follow the account unless the user picked a different currency.
                if let new, currency == old?.currency || (old == nil && bill == nil) { currency = new.currency }
            }
        }
    }

    private func save() {
        guard let value = amountValue, let account, bill == nil || live != nil else { return dismiss() }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: nextDue)
        let target = live ?? Bill(name: "", amount: 0, currency: currency, nextDue: day)
        if bill == nil { modelContext.insert(target) }
        target.anchorDay = Bills.anchorDay(current: target.anchorDay, oldDue: target.nextDue, newDue: day,
                                           oldCadence: target.cadence, newCadence: cadence, calendar: calendar)
        target.nextDue = day
        target.name = trimmed
        target.amount = value
        target.currency = currency
        target.account = account
        target.category = category
        target.cadence = cadence
        target.interval = interval
        target.remindDays = remindDays
        target.active = active
        try? modelContext.save()
        let context = modelContext
        Task { await Bills.sync(context: context, prompt: true) }
        dismiss()
    }
}
