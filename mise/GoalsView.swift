import SwiftUI
import SwiftData

/// Savings goals: progress from contributions or a linked account's balance (#39).
struct GoalsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Goal.createdAt) private var goals: [Goal]
    @State private var rates = FXRates()
    @State private var editing: Goal?
    @State private var isAdding = false

    var body: some View {
        Group {
            if goals.isEmpty {
                ContentUnavailableView {
                    Label("No goals", systemImage: "target")
                } actions: {
                    Button("Add Goal") { isAdding = true }
                }
            } else {
                Form {
                    Section { ForEach(goals, content: row) }
                        .listRowBackground(Color(theme.surface))
                }
            }
        }
        .navigationTitle("Goals")
        .themedBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Goal", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) { GoalEditor(goal: nil) }
        .sheet(item: $editing) { GoalEditor(goal: $0) }
        .task { rates = .load() }
    }

    private func row(_ goal: Goal) -> some View {
        let saved = Goals.saved(goal, rates: rates)
        let reached = saved >= goal.target
        var caption: [String] = []
        if reached {
            caption.append("Reached")
        } else if let date = goal.targetDate,
                  let monthly = Goals.monthlyNeeded(saved: saved, target: goal.target, by: date) {
            caption.append("By \(date.formatted(.dateTime.day().month().year())) · \(monthly.formatted(.currency(code: goal.currency)))/month")
        }
        if let account = goal.account { caption.append("From \(account.name)") }
        return Button { editing = goal } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(goal.name)
                Text("\(saved.formatted(.currency(code: goal.currency))) of \(goal.target.formatted(.currency(code: goal.currency)))")
                    .font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: Goals.fraction(saved: saved, target: goal.target))
                    .tint(reached ? Color.green : nil)
                if !caption.isEmpty {
                    Text(caption.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(goal) }
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(goal) }
        }
    }

    private func delete(_ goal: Goal) {
        modelContext.delete(goal)
        try? modelContext.save()
    }
}

/// New or existing goal (#39). Contributions are edited locally and written on Save.
struct GoalEditor: View {
    let goal: Goal?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @State private var name: String
    @State private var target: String
    @State private var currency: String
    @State private var hasDate: Bool
    @State private var targetDate: Date
    @State private var account: Account?
    @State private var contributions: [GoalContribution]
    @State private var newAmount = ""
    @State private var newDate = Date.now
    @State private var confirmingDelete = false

    init(goal: Goal?) {
        self.goal = goal
        _name = State(initialValue: goal?.name ?? "")
        _target = State(initialValue: goal.map { Accounts.plain($0.target) } ?? "")
        _currency = State(initialValue: goal?.currency ?? FX.home())
        _hasDate = State(initialValue: goal?.targetDate != nil)
        _targetDate = State(initialValue: goal?.targetDate ?? Calendar.current.date(byAdding: .year, value: 1, to: .now)!)
        _account = State(initialValue: goal?.account)
        _contributions = State(initialValue: goal?.contributions ?? [])
    }

    /// nil once deleted: the sheet still renders during dismissal and must not read a dead model.
    private var live: Goal? {
        guard let goal, !goal.isDeleted, goal.modelContext != nil else { return nil }
        return goal
    }

    private var targetValue: Decimal? { Accounts.parseAmount(target).flatMap { $0 > 0 ? $0 : nil } }
    private var newValue: Decimal? { Accounts.parseAmount(newAmount).flatMap { $0 != 0 ? $0 : nil } }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Target", text: $target)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    CurrencyPicker(title: "Currency", selection: $currency)
                        .disabled(account != nil)
                    Toggle("Target date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $targetDate, displayedComponents: .date)
                    }
                    Picker("Linked account", selection: $account) {
                        Text("None").tag(Account?.none)
                        ForEach(choices(accounts, keeping: [account]), id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                } footer: {
                    if account != nil { Text("Progress follows the account balance.") }
                }
                if account == nil {
                    Section("Contributions") {
                        TextField("Amount", text: $newAmount)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                        DatePicker("Date", selection: $newDate, displayedComponents: .date)
                        Button("Add") {
                            guard let value = newValue else { return }
                            contributions.append(GoalContribution(amount: value, date: newDate))
                            newAmount = ""
                        }
                        .disabled(newValue == nil)
                        ForEach(contributions.sorted { $0.date > $1.date }) { contribution in
                            LabeledContent(contribution.date.formatted(.dateTime.day().month().year())) {
                                Text(contribution.amount, format: .currency(code: currency))
                                    .foregroundStyle(contribution.amount < 0 ? .red : .primary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    contributions.removeAll { $0.id == contribution.id }
                                }
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    contributions.removeAll { $0.id == contribution.id }
                                }
                            }
                        }
                    }
                }
                if let goal = live {
                    Section {
                        Button("Delete Goal", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete \(goal.name)?", isPresented: $confirmingDelete) {
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(goal)
                                    try? modelContext.save()
                                    dismiss()
                                }
                            }
                    }
                }
            }
            .navigationTitle(goal == nil ? "New Goal" : "Edit Goal")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmed.isEmpty || targetValue == nil || (goal != nil && live == nil))
                }
            }
            .onChange(of: account) { _, new in
                if let new { currency = new.currency }
            }
        }
    }

    private func save() {
        guard let value = targetValue, goal == nil || live != nil else { return dismiss() }
        let saved = live ?? Goal(name: "", target: 0, currency: currency)
        if goal == nil { modelContext.insert(saved) }
        saved.name = trimmed
        saved.target = value
        saved.currency = account?.currency ?? currency
        saved.targetDate = hasDate ? targetDate : nil
        saved.account = account
        saved.contributions = contributions
        try? modelContext.save()
        dismiss()
    }
}
