import SwiftUI
import SwiftData

/// Bank CSV import (#47): pick the account and map columns, then hand drafts to the review sheet.
struct CSVImportView: View {
    let source: ReviewSource
    let onContinue: ([DraftTransaction]) -> Void
    private let rows: [[String]]
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Query private var allAccounts: [Account]
    @State private var account: Account?
    @State private var mapping = CSVMapping()

    init(source: ReviewSource, onContinue: @escaping ([DraftTransaction]) -> Void) {
        self.source = source
        self.onContinue = onContinue
        rows = CSVImport.rows(source.data)
    }

    private var accounts: [Account] {
        allAccounts.filter { !$0.archived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var dataRows: ArraySlice<[String]> { rows.dropFirst(mapping.hasHeader ? 1 : 0) }

    var body: some View {
        let result = account.map { CSVImport.drafts(rows, mapping: mapping, account: $0) }
        return NavigationStack {
            Group {
                if rows.isEmpty {
                    ContentUnavailableView("No rows found", systemImage: "tablecells")
                } else {
                    form(result)
                }
            }
            .navigationTitle("Import CSV")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        guard let account, let result else { return }
                        if !Storage.inMemory { mapping.save(for: account.id) }
                        onContinue(result.drafts)
                    }
                    .disabled(result?.drafts.isEmpty ?? true)
                }
            }
        }
        .onAppear { if account == nil { account = accounts.first } }
        .onChange(of: account) {
            if let account { mapping = CSVMapping.saved(for: account.id) ?? CSVImport.guess(header: rows.first ?? []) }
        }
    }

    private func form(_ result: (drafts: [DraftTransaction], skipped: Int)?) -> some View {
        // ponytail: every render re-parses all rows once; fine for a few thousand, cache if large statements lag.
        Form {
            Section("Account") {
                Picker("Account", selection: $account) {
                    ForEach(accounts, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
            }
            .listRowBackground(Color(theme.surface))
            Section {
                Toggle("First row is a header", isOn: $mapping.hasHeader)
                column("Date", $mapping.date)
                column("Amount", $mapping.amount)
                if mapping.amount == nil {
                    column("Debit", $mapping.debit)
                    column("Credit", $mapping.credit)
                }
                column("Description", $mapping.description)
                column("Currency", $mapping.currency)
            } header: {
                Text("Columns")
            } footer: {
                if mapping.amount == nil { Text("Pick Debit and Credit when the bank splits money out and in.") }
            }
            .listRowBackground(Color(theme.surface))
            Section("Format") {
                Picker("Date format", selection: $mapping.dateFormat) {
                    ForEach(CSVImport.dateFormats, id: \.self) { Text(example($0)).tag($0) }
                }
                Picker("Decimal", selection: $mapping.decimalComma) {
                    Text("1,234.56").tag(false)
                    Text("1.234,56").tag(true)
                }
                Toggle("Spending shown as positive", isOn: $mapping.negate)
            }
            .listRowBackground(Color(theme.surface))
            Section {
                if dataRows.isEmpty { Text("No rows found").foregroundStyle(.secondary) }
                ForEach(Array(dataRows.prefix(5).enumerated()), id: \.offset) { preview($0.element) }
            } header: {
                Text("Preview")
            } footer: {
                if let result {
                    Text("\(result.drafts.count) of \(dataRows.count) rows ready"
                         + (result.skipped > 0 ? ", \(result.skipped) will be skipped" : ""))
                }
            }
            .listRowBackground(Color(theme.surface))
        }
    }

    /// "None" plus one option per column: header text (or "Column N") and the first data row's value.
    private func column(_ title: String, _ selection: Binding<Int?>) -> some View {
        let header = mapping.hasHeader ? rows.first ?? [] : []
        let first = dataRows.first ?? []
        let count = rows.map(\.count).max() ?? 0
        return Picker(title, selection: selection) {
            Text("None").tag(Int?.none)
            ForEach(0..<count, id: \.self) { index in
                let name = header.indices.contains(index) && !header[index].isEmpty ? header[index] : "Column \(index + 1)"
                let value = first.indices.contains(index) ? first[index] : ""
                Text(value.isEmpty ? name : "\(name) — \(value)").tag(Optional(index))
            }
        }
    }

    private func example(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: DateComponents(calendar: .current, year: 2026, month: 10, day: 25).date!)
    }

    @ViewBuilder
    private func preview(_ fields: [String]) -> some View {
        if let account, let row = CSVImport.row(fields, mapping: mapping, fallbackCurrency: account.currency) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.merchant.isEmpty ? "Transaction" : row.merchant)
                    Text(row.date, format: .dateTime.day().month().year()).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.amount, format: .currency(code: row.currency))
                    .foregroundStyle(row.amount > 0 ? .green : .primary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(fields.joined(separator: " · ")).foregroundStyle(.red)
                Text("Can't read").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

#if DEBUG
extension CSVImport {
    /// `-miseMoney csv|csvreview`: quoted comma, salary inflow, a USD row, an exact repeat (Grab) and an unreadable closing line.
    static let sampleCSV = """
    Date,Description,Amount,Currency
    2026-10-20,Salary ACME Pte Ltd,5200.00,SGD
    2026-10-21,"Cold Storage, Raffles",-46.20,SGD
    2026-10-22,Toast Box,-7.40,SGD
    2026-10-24,Grab,-18.50,SGD
    2026-10-24,Grab,-18.50,SGD
    2026-10-26,Amazon,-24.99,USD
    2026-10-27,Uniqlo,-59.90,SGD
    Closing balance,,,
    """

    static func sampleCSVSource() -> ReviewSource { ReviewSource(data: Data(sampleCSV.utf8), filename: "statement.csv") }
}
#endif
