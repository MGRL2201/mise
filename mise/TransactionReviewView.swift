import SwiftUI
import SwiftData
import QuickLook
import QuickLookThumbnailing
import ImageIO
import UniformTypeIdentifiers

/// Shared review step for imports (#43): pick, fix and import extracted drafts with their source file.
struct TransactionReviewView: View {
    let source: ReviewSource?
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @State private var drafts: [DraftTransaction]
    @State private var duplicates: Set<UUID> = []
    /// Drafts whose category the user picked; suggestions never overwrite them.
    @State private var picked: Set<UUID> = []
    @State private var editing: DraftTransaction?
    @State private var prepared = false
    @State private var error: String?

    init(drafts: [DraftTransaction], source: ReviewSource?) {
        self.source = source
        _drafts = State(initialValue: drafts)
    }

    private var importCount: Int { drafts.filter { $0.selected && TransactionReview.isValid($0) }.count }
    private var invalidCount: Int { drafts.filter { $0.selected && !TransactionReview.isValid($0) }.count }

    var body: some View {
        NavigationStack {
            List {
                if let source {
                    Section("Source") { AttachmentPreview(data: source.data, filename: source.filename) }
                        .listRowBackground(Color(theme.surface))
                }
                Section {
                    ForEach($drafts) { $draft in row($draft) }
                } footer: {
                    if invalidCount > 0 {
                        Text("\(invalidCount) selected need an account or amount and won't be imported")
                    }
                }
                .listRowBackground(Color(theme.surface))
            }
            .navigationTitle("Review")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(importCount)", action: importDrafts).disabled(importCount == 0)
                }
            }
            .sheet(item: $editing) { draft in
                DraftEditor(draft: draft) { updated, pickedCategory in
                    guard let index = drafts.firstIndex(where: { $0.id == updated.id }) else { return }
                    var updated = updated
                    if pickedCategory {
                        picked.insert(updated.id)
                    } else if updated.amount < 0, drafts[index].category?.isIncome != true {
                        // A suggestion may have landed while the editor was open (never restore an income category).
                        updated.category = drafts[index].category
                        updated.categoryIsAuto = drafts[index].categoryIsAuto
                    }
                    drafts[index] = updated
                    if isDuplicate(updated) { duplicates.insert(updated.id) } else { duplicates.remove(updated.id) }
                }
            }
            .alert("Import failed", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            } message: {
                Text(error ?? "")
            }
            .task { await prepare() }
        }
    }

    private func row(_ draft: Binding<DraftTransaction>) -> some View {
        let value = draft.wrappedValue
        return HStack {
            Button { draft.wrappedValue.selected.toggle() } label: {
                Image(systemName: value.selected ? "checkmark.circle.fill" : "circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(value.selected ? "Exclude" : "Include")
            Button { editing = value } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.merchant.isEmpty ? "Transaction" : value.merchant)
                        Text(value.date, format: .dateTime.day().month().year())
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let category = value.category {
                            HStack(spacing: 4) {
                                Text(category.name)
                                if value.categoryIsAuto {
                                    Image(systemName: "sparkles").font(.caption).accessibilityLabel("Auto")
                                }
                            }
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if duplicates.contains(value.id) {
                            // Not Label: List rows reserve a wide icon column for it.
                            Text("\(Image(systemName: "exclamationmark.triangle")) Possible duplicate")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if value.account == nil { Text("Needs an account").font(.caption).foregroundStyle(.red) }
                        if value.amount == 0 { Text("Needs an amount").font(.caption).foregroundStyle(.red) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(value.amount, format: .currency(code: value.currency))
                            .foregroundStyle(value.amount > 0 ? .green : .primary)
                        if let charged = value.accountAmount, let currency = value.account?.currency {
                            Text(charged, format: .currency(code: currency)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Once: default account, flag + deselect duplicates, then suggest categories for outflows one by one.
    private func prepare() async {
        guard !prepared else { return }
        prepared = true
        let fallback = choices(accounts, keeping: []).first
        for index in drafts.indices where drafts[index].account == nil { drafts[index].account = fallback }

        for index in drafts.indices where isDuplicate(drafts[index]) {
            duplicates.insert(drafts[index].id)
            drafts[index].selected = false
        }

        for draft in drafts where draft.amount < 0 && draft.category == nil {
            let result = await Categorizer.suggest(merchant: draft.merchant, amount: draft.amount, categories: categories)
            // The user may have edited the draft or picked a category meanwhile.
            guard let index = drafts.firstIndex(where: { $0.id == draft.id }), drafts[index].category == nil,
                  drafts[index].amount < 0, drafts[index].merchant == draft.merchant, !picked.contains(draft.id)
            else { continue }
            drafts[index].category = result
            drafts[index].categoryIsAuto = result != nil
        }
    }

    /// Fetches only the draft's ±1 day window; TransactionReview.isDuplicate does the matching.
    private func isDuplicate(_ draft: DraftTransaction) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: draft.date)
        guard let start = calendar.date(byAdding: .day, value: -1, to: day),
              let end = calendar.date(byAdding: .day, value: 2, to: day) else { return false }
        let nearby = (try? modelContext.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        return TransactionReview.isDuplicate(draft, in: nearby)
    }

    private func importDrafts() {
        do {
            let inserted = try TransactionReview.commit(drafts, source: source, context: modelContext)
            var seen = Set<String>()
            let alerts = inserted.compactMap { transaction -> (Category, Date)? in
                guard let category = transaction.category,
                      let month = Calendar.current.dateInterval(of: .month, for: transaction.date)?.start,
                      seen.insert("\(category.id)|\(month)").inserted
                else { return nil }
                return (category, transaction.date)
            }
            let context = modelContext
            Task {
                await FX.refresh(context: context)
                for (category, date) in alerts { await Budgets.checkAlerts(for: category, on: date, context: context) }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Edit one draft; mirrors TransactionEditor's fields. Nothing is saved to the store.
private struct DraftEditor: View {
    let draft: DraftTransaction
    /// Bool: the user picked the category here.
    let onSave: (DraftTransaction, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @Query private var categories: [Category]
    @State private var income: Bool
    @State private var amount: String
    @State private var account: Account?
    @State private var currency: String
    @State private var charged: String
    @State private var date: Date
    @State private var merchant: String
    @State private var category: Category?
    @State private var categoryIsAuto: Bool
    @State private var notes: String
    @State private var picked = false

    init(draft: DraftTransaction, onSave: @escaping (DraftTransaction, Bool) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _income = State(initialValue: draft.amount > 0)
        _amount = State(initialValue: draft.amount == 0 ? "" : Accounts.plain(abs(draft.amount)))
        _account = State(initialValue: draft.account)
        _currency = State(initialValue: draft.currency)
        _charged = State(initialValue: draft.accountAmount.map { Accounts.plain(abs($0)) } ?? "")
        _date = State(initialValue: draft.date)
        _merchant = State(initialValue: draft.merchant)
        _category = State(initialValue: draft.category)
        _categoryIsAuto = State(initialValue: draft.categoryIsAuto)
        _notes = State(initialValue: draft.notes)
    }

    private var foreign: Bool { account.map { $0.currency != currency } ?? false }
    private var amountValue: Decimal? { Accounts.parseAmount(amount).flatMap { $0 == 0 ? nil : $0 } }
    /// 0 = no charged amount (hidden or empty); nil = unparseable.
    private var chargedValue: Decimal? { foreign ? Accounts.parseAmount(charged) : 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $income) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Amount", text: $amount)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    Picker("Account", selection: $account) {
                        Text("Choose").tag(Account?.none)
                        ForEach(choices(accounts, keeping: [account]), id: \.self) { Text($0.name).tag(Optional($0)) }
                    }
                    CurrencyPicker(title: "Currency", selection: $currency)
                    if let account, foreign {
                        TextField("Charged in \(account.currency)", text: $charged)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    DatePicker("Date", selection: $date)
                } footer: {
                    if foreign { Text("Optional. Used for the account balance instead of the FX rate.") }
                }
                Section {
                    TextField("Merchant", text: $merchant)
                }
                Section {
                    Picker("Category", selection: Binding(get: { category }, set: {
                        category = $0
                        categoryIsAuto = false
                        picked = true
                    })) {
                        Text("None").tag(Category?.none)
                        ForEach(Budgets.ordered(categories.filter { $0.isIncome == income || $0 == category }), id: \.self) {
                            Text($0.name).tag(Optional($0))
                        }
                    }
                } footer: {
                    if categoryIsAuto && category != nil {
                        Label("Suggested automatically — pick another to correct it.", systemImage: "sparkles")
                    }
                }
                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle("Edit Transaction")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save).disabled(amountValue == nil || chargedValue == nil)
                }
            }
            .onChange(of: income) {
                if let category, category.isIncome != income { self.category = nil; categoryIsAuto = false }
            }
            .onChange(of: account) { old, new in
                if old?.currency != new?.currency { charged = "" }
            }
        }
    }

    private func save() {
        guard let value = amountValue, let chargedValue else { return }
        var updated = draft
        updated.amount = TransactionEntry.signed(value, income: income)
        updated.currency = currency
        updated.account = account
        updated.accountAmount = chargedValue == 0 ? nil : TransactionEntry.signed(chargedValue, income: income)
        updated.date = date
        updated.merchant = merchant
        updated.category = category
        updated.categoryIsAuto = categoryIsAuto && category != nil
        updated.notes = notes
        onSave(updated, picked)
        dismiss()
    }
}

/// Thumbnail + filename of an attachment; tap opens Quick Look. Images and PDFs on both platforms.
struct AttachmentPreview: View {
    let data: Data
    let filename: String
    @Environment(\.displayScale) private var displayScale
    @State private var file: URL?
    @State private var thumbnail: CGImage?
    @State private var url: URL?

    var body: some View {
        Button { url = file } label: {
            HStack {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: displayScale).resizable().scaledToFit()
                    } else {
                        Image(systemName: "doc").font(.title).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 80)
                Text(filename).lineLimit(1)
                Spacer()
                Text("View").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View source file")
        .quickLookPreview($url)
        .task { await load() }
    }

    // ponytail: temp copies are left for the OS to purge; delete on disappear if tmp ever grows.
    private func load() async {
        guard file == nil else { return }
        // The extension tells Quick Look the type; lastPathComponent keeps a stray "/" from escaping the folder.
        let name = URL(fileURLWithPath: filename.isEmpty ? "file" : filename).lastPathComponent
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentPreview").appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let written = folder.appendingPathComponent(name)
            try data.write(to: written)
            file = written
            let request = QLThumbnailGenerator.Request(fileAt: written, size: CGSize(width: 120, height: 160),
                                                       scale: displayScale, representationTypes: .all)
            thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        } catch {}  // no thumbnail: the doc icon stays
    }
}

#if DEBUG
extension TransactionReview {
    /// Screenshot drafts for `-miseMoney review` on top of `-miseSeedFinance YES`; Cold Storage duplicates a seed row.
    static func sampleDrafts(accounts: [Account]) -> [DraftTransaction] {
        let account = accounts.first { $0.name == "DBS Multiplier" } ?? accounts.first { !$0.archived }
        let day: TimeInterval = 86_400
        func draft(_ merchant: String, _ amount: String, _ currency: String, _ date: Date, charged: String? = nil) -> DraftTransaction {
            DraftTransaction(amount: Decimal(string: amount)!, currency: currency, date: date, merchant: merchant,
                             account: account, accountAmount: charged.flatMap { Decimal(string: $0) })
        }
        return [
            draft("Cold Storage", "-46.20", "SGD", .now - 10_800),
            draft("Toast Box", "-7.40", "SGD", .now - 3_600),
            draft("Uniqlo", "-59.90", "SGD", .now - day),
            draft("Amazon", "-24.99", "USD", .now - day, charged: "-33.70"),
        ]
    }

    /// A rendered receipt PNG standing in for a scanned photo.
    @MainActor
    static func sampleSource() -> ReviewSource? {
        let items = [("Kaya Toast Set", "4.60"), ("Kopi C", "1.80"), ("Soft-boiled Eggs", "1.00")]
        let receipt = VStack(alignment: .leading, spacing: 6) {
            Text("TOAST BOX").font(.system(.headline, design: .monospaced)).frame(maxWidth: .infinity)
            Text("Raffles Place").frame(maxWidth: .infinity)
            Divider()
            ForEach(items, id: \.0) { item in
                HStack { Text(item.0); Spacer(); Text(item.1) }
            }
            Divider()
            HStack { Text("TOTAL").bold(); Spacer(); Text("7.40").bold() }
        }
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(.black)
        .padding()
        .frame(width: 220)
        .background(.white)
        let renderer = ImageRenderer(content: receipt)
        renderer.scale = 2
        let data = NSMutableData()
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? ReviewSource(data: data as Data, filename: "receipt.png") : nil
    }

    /// OCR-style receipt text for `-miseMoney extract`.
    static let sampleReceiptText = """
    TOAST BOX
    Raffles Place
    GST Reg No: 200012345K
    25/10/2026 08:14
    Kaya Toast Set        4.60
    Kopi C                1.80
    Soft-boiled Eggs      1.00
    SUBTOTAL              6.79
    GST 9%                0.61
    TOTAL            S$ 7.40
    VISA ****1234
    """
}
#endif
