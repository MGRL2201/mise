import SwiftUI
import SwiftData

extension Holding {
    /// Symbol, or the name when there is none.
    var displayName: String { symbol.isEmpty ? name : symbol }
}

/// Amount field value, rejecting negatives (short positions out of scope). Empty parses as 0.
private func nonNegativeAmount(_ text: String) -> Decimal? {
    Accounts.parseAmount(text).flatMap { $0 >= 0 ? $0 : nil }
}

/// New or existing holding (#48). An empty price means unpriced (not in totals).
struct HoldingEditor: View {
    let holding: Holding?
    let account: Account
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var kind: HoldingKind
    @State private var symbol: String
    @State private var name: String
    @State private var quantity: String
    @State private var cost: String
    @State private var price: String
    @State private var priceDate: Date
    @State private var currency: String
    @State private var confirmingDelete = false
    @State private var coinID: String?
    @State private var query = ""
    @State private var results: [Coin] = []
    @State private var searchError: String?

    init(holding: Holding?, account: Account) {
        self.holding = holding
        self.account = account
        _kind = State(initialValue: holding?.kind ?? .stock)
        _symbol = State(initialValue: holding?.symbol ?? "")
        _name = State(initialValue: holding?.name ?? "")
        _quantity = State(initialValue: holding.map { Accounts.plain($0.quantity) } ?? "")
        _cost = State(initialValue: holding.map { Accounts.plain($0.costBasis) } ?? "")
        _price = State(initialValue: holding?.price.map(Accounts.plain) ?? "")
        _priceDate = State(initialValue: holding?.priceDate ?? .now)
        _currency = State(initialValue: holding?.currency ?? account.currency)
        _coinID = State(initialValue: holding?.coinID)
        #if DEBUG
        if holding == nil && UserDefaults.standard.string(forKey: "miseMoney") == "coins" {
            _kind = State(initialValue: .crypto)
            _query = State(initialValue: "eth")
        }
        #endif
    }

    /// nil once deleted: the sheet still renders during dismissal and must not read a dead model.
    private var live: Holding? {
        guard let holding, !holding.isDeleted, holding.modelContext != nil else { return nil }
        return holding
    }

    private var trimmedSymbol: String { symbol.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasPrice: Bool { !price.trimmingCharacters(in: .whitespaces).isEmpty }
    private var valid: Bool {
        !(trimmedSymbol.isEmpty && trimmedName.isEmpty)
            && !quantity.trimmingCharacters(in: .whitespaces).isEmpty
            && nonNegativeAmount(quantity) != nil && nonNegativeAmount(cost) != nil
            && (!hasPrice || nonNegativeAmount(price) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(HoldingKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Symbol", text: $symbol)
                    TextField("Name", text: $name)
                    TextField("Quantity", text: $quantity)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    TextField("Cost basis (0 if unknown)", text: $cost)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    TextField("Price", text: $price)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .onChange(of: price) { priceDate = .now }
                    if hasPrice {
                        DatePicker("Price date", selection: $priceDate, in: ...Date.now, displayedComponents: .date)
                    }
                    CurrencyPicker(title: "Currency", selection: $currency)
                } footer: {
                    if kind == .fund { Text("Valued as a whole? Use quantity 1 and enter the total value as the price.") }
                }
                if kind == .crypto {
                    Section {
                        if let coinID {
                            LabeledContent("Linked coin", value: coinID)
                            Button("Unlink") { self.coinID = nil }
                        }
                        TextField("Search coins", text: $query)
                            #if os(iOS)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            #endif
                            .task(id: query) {
                                try? await Task.sleep(for: .milliseconds(400))
                                guard !Task.isCancelled else { return }
                                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !trimmed.isEmpty else { results = []; searchError = nil; return }
                                do {
                                    let found = try await CoinGecko.search(trimmed)
                                    guard !Task.isCancelled else { return }
                                    results = found
                                    searchError = nil
                                } catch {
                                    guard !Task.isCancelled else { return }
                                    results = []
                                    searchError = "Search unavailable"
                                }
                            }
                        if let searchError { Text(searchError).foregroundStyle(.secondary) }
                        ForEach(results) { coin in
                            Button {
                                coinID = coin.id
                                symbol = coin.symbol.uppercased()
                                name = coin.name
                                query = ""
                                results = []
                            } label: {
                                LabeledContent(coin.name, value: coin.symbol.uppercased())
                            }
                        }
                    } header: {
                        Text("CoinGecko")
                    } footer: {
                        Text("Linked coins get their price from CoinGecko on refresh, overwriting manual prices.")
                    }
                }
                if let holding = live {
                    Section {
                        Button("Delete Holding", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("Delete \(holding.displayName)?", isPresented: $confirmingDelete) {
                                Button("Delete", role: .destructive) {
                                    modelContext.delete(holding)
                                    try? modelContext.save()
                                    dismiss()
                                }
                            }
                    }
                }
            }
            .navigationTitle(holding == nil ? "New Holding" : "Edit Holding")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!valid || (holding != nil && live == nil))
                }
            }
        }
    }

    private func save() {
        guard valid, let quantityValue = nonNegativeAmount(quantity), let costValue = nonNegativeAmount(cost),
              holding == nil || live != nil else { return dismiss() }
        let saved = live ?? Holding(symbol: "", name: "", kind: kind, quantity: 0, costBasis: 0, currency: currency)
        if holding == nil { modelContext.insert(saved) }
        saved.account = account
        saved.kind = kind
        saved.symbol = trimmedSymbol
        saved.name = trimmedName
        saved.quantity = quantityValue
        saved.costBasis = costValue
        saved.currency = currency
        saved.price = hasPrice ? nonNegativeAmount(price) : nil
        saved.priceDate = hasPrice ? priceDate : nil
        saved.coinID = kind == .crypto ? coinID : nil
        try? modelContext.save()
        dismiss()
    }
}

/// Quick price update. Writes the same `price`/`priceDate` the fetchers (#49/#50) will.
struct PriceEditor: View {
    let holding: Holding
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var price: String
    @State private var date = Date.now

    init(holding: Holding) {
        self.holding = holding
        _price = State(initialValue: holding.price.map(Accounts.plain) ?? "")
    }

    private var value: Decimal? {
        price.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nonNegativeAmount(price)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Price", text: $price)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                } footer: {
                    Text("Per unit, in \(holding.currency).")
                }
            }
            .navigationTitle(holding.displayName)
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard !holding.isDeleted, holding.modelContext != nil else { return dismiss() }
                        holding.price = value
                        holding.priceDate = date
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(value == nil || holding.isDeleted || holding.modelContext == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Symbol, name and quantity; value and gain/loss in the holding's currency ("—" unpriced). Tap to edit.
struct HoldingRow: View {
    let holding: Holding
    @Binding var editing: Holding?
    @Binding var pricing: Holding?

    var body: some View {
        let detail = [holding.symbol.isEmpty ? "" : holding.name, "Qty \(Accounts.plain(holding.quantity))"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        Button { editing = holding } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding.displayName)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let value = Holdings.value(holding), let gain = Holdings.gain(holding) {
                        Text(value, format: .currency(code: holding.currency))
                        Text(gain, format: .currency(code: holding.currency))
                            .font(.subheadline).foregroundStyle(gain < 0 ? .red : .green)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                    if let date = holding.priceDate {
                        Text(date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Update Price", systemImage: "tag") { pricing = holding }
        }
        .contextMenu {
            Button("Update Price", systemImage: "tag") { pricing = holding }
        }
    }
}
