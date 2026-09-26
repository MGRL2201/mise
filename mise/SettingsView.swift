import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var editingDark = false
    @State private var stockAPIKeyInput = ""
    @State private var stockAPIKeySaved = Keychain.get(Keychain.stockAPIKey) != nil
    @State private var stockAPIKeyError: OSStatus?

    var body: some View {
        Form {
            Section("Finance") {
                SecureField("Stock price API key", text: $stockAPIKeyInput)
                Text(stockAPIKeySaved ? "A key is stored." : "No key stored.")
                    .foregroundStyle(.secondary)
                if let stockAPIKeyError {
                    Text("Couldn't save key (OSStatus \(stockAPIKeyError))")
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Save") {
                        do {
                            try Keychain.set(stockAPIKeyInput, for: Keychain.stockAPIKey)
                            stockAPIKeyInput = ""
                            stockAPIKeySaved = true
                            stockAPIKeyError = nil
                        } catch let error as Keychain.Error {
                            stockAPIKeyError = error.status
                        } catch {
                            stockAPIKeyError = -1
                        }
                    }
                    .disabled(stockAPIKeyInput.isEmpty)
                    Button("Clear", role: .destructive) {
                        do {
                            try Keychain.delete(Keychain.stockAPIKey)
                            stockAPIKeyInput = ""
                            stockAPIKeySaved = false
                            stockAPIKeyError = nil
                        } catch let error as Keychain.Error {
                            stockAPIKeyError = error.status
                        } catch {
                            stockAPIKeyError = -1
                        }
                    }
                    .disabled(!stockAPIKeySaved)
                }
            }
            .listRowBackground(Color(theme.surface))

            Section("Theme") {
                Picker("Variant", selection: $editingDark) {
                    Text("Light").tag(false)
                    Text("Dark").tag(true)
                }
                .pickerStyle(.segmented)
                colorPicker("Accent", \.accent)
                colorPicker("Background", \.background)
                colorPicker("Surface", \.surface)
                colorPicker("Text", \.text)
                ForEach(editingVariant.contrastWarnings, id: \.pair) { warning in
                    Label(
                        "\(warning.pair) contrast is \(warning.ratio, format: .number.precision(.fractionLength(1))):1",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .listRowBackground(Color(theme.surface))

            Section("Modules") {
                ForEach(Destination.allCases.filter { $0 != .settings }) { destination in
                    colorPicker(destination.title, \.[module: destination])
                }
            }
            .listRowBackground(Color(theme.surface))

            Section("Presets") {
                ForEach(Palette.presets, id: \.name) { preset in
                    Button(preset.name) { store.palette = preset.palette }
                }
                Button("Reset to default", role: .destructive) { store.reset() }
            }
            .listRowBackground(Color(theme.surface))
        }
        .navigationTitle("Settings")
        .themedBackground()
    }

    private var editingVariant: Palette.Variant {
        editingDark ? store.palette.dark : store.palette.light
    }

    private func colorPicker(
        _ title: String, _ role: WritableKeyPath<Palette.Variant, Color.Resolved>
    ) -> some View {
        let path = (editingDark ? \Palette.dark : \Palette.light).appending(path: role)
        return ColorPicker(title, selection: Binding {
            Color(store.palette[keyPath: path])
        } set: {
            store.palette[keyPath: path] = $0.resolve(in: EnvironmentValues())
        }, supportsOpacity: false)
    }
}
