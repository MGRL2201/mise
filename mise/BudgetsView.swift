import SwiftUI
import SwiftData

extension Category {
    var tint: Color { Self.tint(color) }

    /// 0xRRGGBB → Color.
    static func tint(_ hex: Int) -> Color { Color(Color.Resolved(UInt32(hex))) }

    var label: some View {
        Label {
            Text(name)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
    }
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
                            category.label
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
            Section {
                NavigationLink("Categories") { CategoriesView() }
            }
            .listRowBackground(Color(theme.surface))
        }
        .navigationTitle("Budgets")
        .themedBackground()
        .toolbar {
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

/// Add, edit, reorder and delete categories (#37).
struct CategoriesView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Query private var categories: [Category]
    @State private var editing: Category?
    @State private var isAdding = false
    /// Name and count captured up front: the dialog must not read the model after it's deleted.
    @State private var deleting: (category: Category, name: String, count: Int)?
    @State private var moving: Category?

    var body: some View {
        let ordered = Budgets.ordered(categories)
        List {
            ForEach(ordered) { category in
                Button { editing = category } label: {
                    HStack {
                        category.label
                        Spacer()
                        Text("\(category.transactions?.count ?? 0)").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(category) }
                }
            }
            .onMove { offsets, destination in
                var reordered = ordered
                reordered.move(fromOffsets: offsets, toOffset: destination)
                for (index, category) in reordered.enumerated() { category.sortOrder = index }
                try? modelContext.save()
            }
            .onDelete { offsets in
                if let index = offsets.first { delete(ordered[index]) }
            }
            .listRowBackground(Color(theme.surface))
        }
        .navigationTitle("Categories")
        .themedBackground()
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .secondaryAction) { EditButton() }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button("New Category", systemImage: "plus") { isAdding = true }
            }
        }
        .confirmationDialog(Text("Delete \(deleting?.name ?? "")?"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Leave Uncategorized", role: .destructive) {
                Budgets.delete(item.category, reassigningTo: nil, context: modelContext)
            }
            if categories.count > 1 {
                Button("Move to…") { moving = item.category }
            }
        } message: { item in
            Text("\(item.count) transactions use this category.")
        }
        .sheet(isPresented: $isAdding) { CategoryEditor(category: nil) }
        .sheet(item: $editing) { CategoryEditor(category: $0) }
        .sheet(item: $moving) { category in
            NavigationStack {
                List(ordered.filter { $0.id != category.id }) { target in
                    Button {
                        moving = nil
                        Budgets.delete(category, reassigningTo: target, context: modelContext)
                    } label: {
                        target.label.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(theme.surface))
                }
                .navigationTitle("Move to")
                .themedBackground()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { moving = nil } }
                }
            }
        }
    }

    /// Delete outright when unused; otherwise ask where its transactions go.
    private func delete(_ category: Category) {
        let count = category.transactions?.count ?? 0
        if count == 0 {
            Budgets.delete(category, reassigningTo: nil, context: modelContext)
        } else {
            deleting = (category, category.name, count)
        }
    }
}

/// New or existing category: name, icon, color, monthly budget. Delete lives in CategoriesView.
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
        // Ask for notification permission once, when a budget is first set; checkAlerts never prompts.
        if budgetValue != nil, !Storage.inMemory { Task { _ = await LocalNotifications.authorized(prompt: true) } }
        dismiss()
    }
}
