import SwiftUI

struct SettingsView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var editingDark = false

    var body: some View {
        Form {
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
