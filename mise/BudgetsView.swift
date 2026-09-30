import SwiftUI
import SwiftData

extension Category {
    var tint: Color { Self.tint(color) }

    /// 0xRRGGBB → Color.
    static func tint(_ hex: Int) -> Color { Color(Color.Resolved(UInt32(hex))) }
}

/// Month-by-month spend per category against its budget (#37).
struct BudgetsView: View {
    @Environment(\.theme) private var theme
    @Query private var categories: [Category]
    @Query private var transactions: [Transaction]
    @State private var rates = FXRates()
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start
    @State private var editing: Category?
    @State private var isAdding = false
    @AppStorage(FX.homeKey) private var home = FX.home()

    var body: some View {
        let interval = Calendar.current.dateInterval(of: .month, for: month)!
        let spent = Budgets.spent(transactions, in: interval, rates: rates, home: home)
        let ordered = Budgets.ordered(categories)
        let budgeted = ordered.filter { $0.budget != nil }
        Form {
            Section {
                HStack {
                    Button("Previous Month", systemImage: "chevron.left") { shift(-1) }
                    Spacer()
                    Text(month, format: .dateTime.month(.wide).year()).font(.headline)
                    Spacer()
                    Button("Next Month", systemImage: "chevron.right") { shift(1) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .listRowBackground(Color(theme.surface))
            Section("Total") {
                LabeledContent("Spent", value: spent.byCategory.values.reduce(spent.uncategorized, +),
                               format: .currency(code: home))
                // Bar: budgeted categories only, so unbudgeted spend can't push it red.
                if !budgeted.isEmpty {
                    amounts(budgeted.reduce(0) { $0 + (spent.byCategory[$1.id] ?? 0) },
                            budget: budgeted.compactMap(\.budget).reduce(0, +))
                }
                ForEach(spent.unconverted.filter { $0.value != 0 }.sorted { $0.key < $1.key }, id: \.key) { code, amount in
                    Text("\(amount.formatted(.currency(code: code))) (no rate)").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color(theme.surface))
            Section("Categories") {
                ForEach(ordered) { category in
                    Button { editing = category } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text(category.name)
                            } icon: {
                                Image(systemName: category.icon).foregroundStyle(category.tint)
                            }
                            amounts(spent.byCategory[category.id] ?? 0, budget: category.budget)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Uncategorized", systemImage: "questionmark.circle")
                    amounts(spent.uncategorized, budget: nil)
                }
            }
            .listRowBackground(Color(theme.surface))
        }
        .navigationTitle("Budgets")
        .themedBackground()
        .toolbar {
            // Task 3 (#37): NavigationLink("Categories") { CategoriesView() } goes here.
            ToolbarItem(placement: .primaryAction) {
                Button("New Category", systemImage: "plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) { CategoryEditor(category: nil) }
        .sheet(item: $editing) { CategoryEditor(category: $0) }
        .task { rates = .load() }
    }

    private func shift(_ months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }

    /// "S$123 of S$500" with a green / orange (80%) / red (100%) bar, or just the spend without a budget.
    @ViewBuilder
    private func amounts(_ spent: Decimal, budget: Decimal?) -> some View {
        if let budget, budget > 0 {
            Text("\(spent.formatted(.currency(code: home))) of \(budget.formatted(.currency(code: home)))")
                .foregroundStyle(.secondary)
            ProgressView(value: min(NSDecimalNumber(decimal: spent / budget).doubleValue, 1))
                .tint([Color.green, .orange, .red][Budgets.thresholds(spent: spent, budget: budget).count])
        } else {
            Text(spent, format: .currency(code: home)).foregroundStyle(.secondary)
        }
    }
}

/// New or existing category: name, icon, color, monthly budget. Delete lives in CategoriesView (task 3).
struct CategoryEditor: View {
    let category: Category?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [Category]
    @AppStorage(FX.homeKey) private var home = FX.home()
    @State private var name: String
    @State private var icon: String
    @State private var color: Int
    @State private var budget: String

    static let icons = Budgets.starter.map(\.icon) + [
        "tag", "gift", "book", "pawprint", "gamecontroller", "graduationcap", "wrench", "tshirt", "phone", "creditcard",
    ]
    static let palette: [(name: String, color: Int)] = [
        ("Green", 0x34C759), ("Orange", 0xFF9500), ("Blue", 0x007AFF), ("Brown", 0x8E6E53),
        ("Yellow", 0xFFCC00), ("Pink", 0xFF2D55), ("Red", 0xFF3B30), ("Purple", 0xAF52DE),
        ("Sky", 0x5AC8FA), ("Indigo", 0x5856D6), ("Gray", 0x8E8E93),
    ]

    init(category: Category?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _icon = State(initialValue: category?.icon ?? "tag")
        _color = State(initialValue: category?.color ?? 0x8E8E93)
        _budget = State(initialValue: category?.budget.map(Accounts.plain) ?? "")
    }

    /// nil once deleted (backup restore, task 3 delete): the sheet must not read or write a dead model.
    private var live: Category? {
        guard let category, !category.isDeleted, category.modelContext != nil else { return nil }
        return category
    }

    /// .some(nil) = no budget (empty or 0); nil = invalid (negative / unparseable).
    private var budgetValue: Decimal?? {
        if budget.trimmingCharacters(in: .whitespaces).isEmpty { return .some(nil) }
        guard let value = Accounts.parseAmount(budget), value >= 0 else { return nil }
        return value == 0 ? .some(nil) : value
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var duplicate: Bool {
        Budgets.named(trimmed, in: categories.filter { $0.id != live?.id }) != nil
    }

    var body: some View {
        // Keep an off-list icon/color (e.g. seeded data) selectable.
        let icons = Self.icons.contains(icon) ? Self.icons : [icon] + Self.icons
        let palette = Self.palette.contains { $0.color == color } ? Self.palette : [("Custom", color)] + Self.palette
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Icon", selection: $icon) {
                        ForEach(icons, id: \.self) { Label($0, systemImage: $0).tag($0) }
                    }
                    Picker("Color", selection: $color) {
                        ForEach(palette, id: \.color) { item in
                            Label {
                                Text(item.name)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(Category.tint(item.color))
                            }
                            .tag(item.color)
                        }
                    }
                    TextField("Monthly budget (\(home))", text: $budget)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                } footer: {
                    if duplicate { Text("A category with this name already exists.") }
                }
            }
            .navigationTitle(category == nil ? "New Category" : "Edit Category")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmed.isEmpty || duplicate || budgetValue == nil || (category != nil && live == nil))
                }
            }
        }
    }

    private func save() {
        guard let budgetValue, category == nil || live != nil else { return dismiss() }
        let target = live ?? Category(name: "")
        if category == nil {
            target.sortOrder = (categories.map(\.sortOrder).max() ?? -1) + 1
            modelContext.insert(target)
        }
        target.name = trimmed
        target.icon = icon
        target.color = color
        target.budget = budgetValue
        try? modelContext.save()
        dismiss()
    }
}
