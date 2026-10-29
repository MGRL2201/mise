import SwiftUI
import SwiftData
import Charts

/// Spending by category, monthly income vs spend, and net worth over time (#40).
struct ReportsView: View {
    @Environment(\.theme) private var theme
    @Query private var categories: [Category]
    @Query private var transactions: [Transaction]
    @Query private var snapshots: [NetWorthSnapshot]
    @State private var rates = FXRates()
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start
    @State private var months = 6
    @State private var range = Reports.NetWorthRange.quarter
    @AppStorage(FX.homeKey) private var home = FX.home()

    var body: some View {
        Form {
            spending
            trends
            netWorth
        }
        .navigationTitle("Reports")
        .themedBackground()
        .task { rates = .load() }
    }

    private func currency(_ amount: Decimal) -> String { amount.formatted(.currency(code: home)) }

    private var axisCurrency: FloatingPointFormatStyle<Double>.Currency {
        .currency(code: home).precision(.fractionLength(0))
    }

    private var spending: some View {
        let spent = Budgets.spent(transactions, in: Calendar.current.dateInterval(of: .month, for: month)!,
                                  rates: rates, home: home)
        let totals = Reports.categoryTotals(spent, categories: categories)
        return Section("Spending by category") {
            MonthSwitcher(month: $month)
            if totals.isEmpty {
                Text("No spending this month.").foregroundStyle(.secondary)
            } else {
                Chart(totals) { row in
                    BarMark(x: .value("Amount", row.amount), y: .value("Category", row.name))
                        .foregroundStyle(Category.tint(row.color))
                        .accessibilityLabel(row.name)
                        .accessibilityValue(currency(row.amount))
                }
                .chartXAxis { AxisMarks(format: axisCurrency) }
                .frame(height: CGFloat(totals.count) * 36 + 30)
                LabeledContent("Total", value: totals.reduce(0) { $0 + $1.amount }, format: .currency(code: home))
            }
            ForEach(spent.unconverted.filter { $0.value != 0 }.sorted { $0.key < $1.key }, id: \.key) { code, amount in
                Text("\(amount.formatted(.currency(code: code))) (no rate)").foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color(theme.surface))
    }

    private var trends: some View {
        let monthly = Reports.monthly(transactions, months: months, rates: rates, home: home)
        return Section {
            Picker("Months", selection: $months) {
                Text("6 months").tag(6)
                Text("12 months").tag(12)
            }
            .pickerStyle(.segmented)
            Chart(monthly.series) { total in
                ForEach([("Income", total.income), ("Spend", total.spend)], id: \.0) { kind, amount in
                    BarMark(x: .value("Month", total.month, unit: .month), y: .value("Amount", amount))
                        .foregroundStyle(by: .value("Type", kind))
                        .position(by: .value("Type", kind))
                        .accessibilityLabel("\(kind), \(total.month.formatted(.dateTime.month(.wide).year()))")
                        .accessibilityValue(currency(amount))
                }
            }
            .chartForegroundStyleScale(["Income": Color.green, "Spend": Color.orange])
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(months > 6 ? .narrow : .abbreviated), centered: true)
                }
            }
            .chartYAxis { AxisMarks(format: axisCurrency) }
            .frame(height: 220)
        } header: {
            Text("Monthly trends")
        } footer: {
            if !monthly.unconverted.isEmpty {
                Text("Amounts in \(monthly.unconverted.sorted().joined(separator: ", ")) without a rate are excluded.")
            }
        }
        .listRowBackground(Color(theme.surface))
    }

    private var netWorth: some View {
        let points = Reports.history(snapshots, range: range, home: home)
        return Section("Net worth") {
            Picker("Range", selection: $range) {
                ForEach(Reports.NetWorthRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if let latest = points.last {
                LabeledContent("Latest", value: latest.total, format: .currency(code: home))
            }
            if points.count < 2 {
                Text("Not enough history yet. Net worth is recorded once a day.").foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Net worth", point.total))
                        .interpolationMethod(.monotone)
                        .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(currency(point.total))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis { AxisMarks(format: axisCurrency) }
                .frame(height: 200)
            }
        }
        .listRowBackground(Color(theme.surface))
    }
}
