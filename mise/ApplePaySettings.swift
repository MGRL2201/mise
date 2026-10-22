import SwiftUI
import SwiftData

/// Money › Apple Pay (#153): default account and per-card accounts for the Log Transaction automation.
struct ApplePaySettingsView: View {
    @Environment(\.theme) private var theme
    @Query private var accounts: [Account]
    // Seed mode keeps edits in @State only: seeded sample data must never write real settings.
    @State private var cards = Storage.inMemory ? [:] : UserDefaults.standard.dictionary(forKey: ApplePay.cardsKey) as? [String: String] ?? [:]
    @State private var defaultID = Storage.inMemory ? "" : UserDefaults.standard.string(forKey: ApplePay.defaultKey) ?? ""
    @State private var newCard = ""
    @State private var showingGuide = false

    var body: some View {
        let live = accounts.filter { !$0.archived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let names = cards.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // Archived/deleted picks show as unset, matching ApplePay.account(forCard:) fallback; stored value untouched.
        let shown = { (id: String?) in live.contains { $0.id.uuidString == id } ? id ?? "" : "" }
        let trimmed = newCard.trimmingCharacters(in: .whitespacesAndNewlines)
        Form {
            Section {
                Picker("Default account", selection: Binding(get: { shown(defaultID) }, set: { defaultID = $0 })) {
                    Text("None").tag("")
                    ForEach(live) { Text($0.name).tag($0.id.uuidString) }
                }
            } header: {
                Text("Default account")
            } footer: {
                Text("Taps from cards without their own account land here.")
            }
            .listRowBackground(Color(theme.surface))
            Section {
                ForEach(names, id: \.self) { name in
                    Picker(name, selection: Binding(get: { shown(cards[name]) }, set: { cards[name] = $0 })) {
                        Text("Default account").tag("")
                        ForEach(live) { Text($0.name).tag($0.id.uuidString) }
                    }
                }
                .onDelete { offsets in offsets.forEach { cards[names[$0]] = nil } }
                HStack {
                    TextField("Card name as shown in Wallet", text: $newCard)
                    Button("Add") {
                        cards[trimmed] = ""
                        newCard = ""
                    }
                    .disabled(trimmed.isEmpty || cards.keys.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
                }
            } header: {
                Text("Cards")
            } footer: {
                Text("Cards appear here after their first tap. Names must match Wallet.")
            }
            .listRowBackground(Color(theme.surface))
            Section {
                Button("Setup Guide") { showingGuide = true }
            }
            .listRowBackground(Color(theme.surface))
        }
        .navigationTitle("Apple Pay")
        .themedBackground()
        .sheet(isPresented: $showingGuide) { ApplePayGuide() }
        // ponytail: last write wins; a tap logged while this screen is open can lose its new card until the next tap.
        .onChange(of: cards) { if !Storage.inMemory { UserDefaults.standard.set(cards, forKey: ApplePay.cardsKey) } }
        .onChange(of: defaultID) { if !Storage.inMemory { UserDefaults.standard.set(defaultID, forKey: ApplePay.defaultKey) } }
    }
}

/// How to set up the Shortcuts Transaction automation. Static help.
struct ApplePayGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("mise can log each Apple Pay tap automatically using a Shortcuts automation. Set it up once:")
                }
                Section {
                    step(1, "Open Shortcuts and go to the Automation tab. Tap + (New Automation).")
                    step(2, "Choose Transaction. Under When I tap, select your cards. Choose Run Immediately, then tap Next.")
                    step(3, "Tap New Blank Automation, then Add Action. Search for mise and choose Log Transaction.")
                    step(4, "Fill in the action from the automation's Shortcut Input:")
                    example("Amount → Shortcut Input › Amount")
                    example("Merchant → Shortcut Input › Merchant")
                    example("Card → Shortcut Input › Card or Pass",
                            "Tap the field, choose Shortcut Input, then tap the inserted variable to pick the property. Leave Date empty to use the time of the tap.")
                    step(5, "Tap Done.")
                    step(6, "In mise, open Money › Apple Pay and pick a default account. After a card's first tap it appears under Cards, where you can give it its own account.")
                }
                Section("Good to know") {
                    Text("A repeat tap with the same amount, merchant and card within 5 minutes is ignored.")
                    Text("mise picks a category automatically; you can change it later.")
                    Text("If fields arrive empty, add a Show Result action with Shortcut Input to see what your iPhone sends.")
                }
            }
            .navigationTitle("Apple Pay Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        Text("\(number). \(text)")
    }

    private func example(_ text: String, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.body.monospaced())
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
