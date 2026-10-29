import SwiftUI
import SwiftData

/// One month at a glance: income vs spend, budgets, top merchants (#41). Opened from the month-end notification.
struct MonthSummaryView: View {
    @Environment(\.theme) private var theme
    @Query private var categories: [Category]
    @Query private var transactions: [Transaction]
    @State private var rates = FXRates()
    @State private var month: Date
    @AppStorage(FX.homeKey) private var home = FX.home()

    init(month: Date) {
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: month)!.start)
    }

    var body: some View {
        let interval = Calendar.current.dateInterval(of: .month, for: month)!
        let income = Finance.homeIncome(transactions, in: interval, rates: rates, home: home)
        let spend = Finance.homeSpend(transactions, in: interval, rates: rates, home: home)
        let net = income.total - spend.total
        let unconverted = income.unconverted.merging(spend.unconverted.mapValues { -$0 }, uniquingKeysWith: +)
        let lines = MonthSummary.categoryLines(Budgets.spent(transactions, in: interval, rates: rates, home: home),
                                               categories: categories)
        let merchants = MonthSummary.topMerchants(transactions, in: interval, rates: rates, home: home)
        Form {
            Section {
                MonthSwitcher(month: $month)
                LabeledContent("Income") {
                    Text(income.total, format: .currency(code: home)).foregroundStyle(.green)
                }
                LabeledContent("Spend", value: spend.total, format: .currency(code: home))
                LabeledContent("Net") {
                    Text(net, format: .currency(code: home)).foregroundStyle(net < 0 ? .red : .primary)
                }
                ForEach(unconverted.filter { $0.value != 0 }.sorted { $0.key < $1.key }, id: \.key) { code, amount in
                    Text("\(amount.formatted(.currency(code: code))) (no rate)").foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color(theme.surface))
            Section("Budgets") {
                if lines.isEmpty {
                    Text("No spending this month.").foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(line.spent, format: .currency(code: home)).foregroundStyle(line.isOver ? .red : .primary)
                            if let budget = line.budget, budget > 0 {
                                Text("of \(budget.formatted(.currency(code: home)))").font(.subheadline)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "circle.fill").foregroundStyle(Category.tint(line.color)).font(.caption)
                            Text(line.name)
                            if line.isOver {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                    .accessibilityLabel("Over budget")
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color(theme.surface))
            if !merchants.isEmpty {
                Section("Top merchants") {
                    ForEach(merchants, id: \.name) { merchant in
                        LabeledContent(merchant.name, value: merchant.amount, format: .currency(code: home))
                    }
                }
                .listRowBackground(Color(theme.surface))
            }
            Section {
                NavigationLink("Reports") { ReportsView() }
            }
            .listRowBackground(Color(theme.surface))
        }
        .navigationTitle("Month Summary")
        .themedBackground()
        .task { rates = .load() }
    }
}
