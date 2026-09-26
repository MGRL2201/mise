import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(\.theme) private var theme
    @State private var editingDark = false
    @State private var stockAPIKeyInput = ""
    @State private var stockAPIKeySaved = Keychain.get(Keychain.stockAPIKey) != nil
    @State private var stockAPIKeyError: OSStatus?
    @State private var lockUnavailableMessage: String?
    @Environment(\.modelContext) private var modelContext
    @State private var exportDocument: BackupDocument?
    @State private var isImporting = false
    @State private var restoreURL: URL?
    @State private var backupError: String?

    var body: some View {
        @Bindable var lock = lock
        Form {
            Section("Security") {
                Picker("App lock", selection: $lock.mode) {
                    ForEach(LockMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: lock.mode) { _, mode in
                    guard mode != .off, !AppLock.isAvailable else {
                        lockUnavailableMessage = nil
                        return
                    }
                    lock.mode = .off
                    lockUnavailableMessage = "Set a device passcode to enable the lock."
                }
                if let lockUnavailableMessage {
                    Text(lockUnavailableMessage).foregroundStyle(.red)
                }
                Picker("Require unlock", selection: $lock.graceSeconds) {
                    ForEach(AppLock.graceOptions, id: \.seconds) { Text($0.title).tag($0.seconds) }
                }
                .disabled(lock.mode == .off)
            }
            .listRowBackground(Color(theme.surface))

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

            Section {
                Button("Export backup…") {
                    do {
                        exportDocument = BackupDocument(data: try BackupService.export(
                            context: modelContext, files: AttachmentFileStore(), defaults: .standard))
                    } catch {
                        backupError = error.localizedDescription
                    }
                }
                Button("Restore from backup…") { isImporting = true }
            } header: {
                Text("Backup")
            } footer: {
                Text("API keys are not included.")
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
        .fileExporter(
            isPresented: Binding { exportDocument != nil } set: { if !$0 { exportDocument = nil } },
            document: exportDocument, contentType: .json, defaultFilename: BackupDocument.defaultFilename
        ) { result in
            if case .failure(let error) = result { backupError = error.localizedDescription }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): restoreURL = url
            case .failure(let error): backupError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Replace all data?",
            isPresented: Binding { restoreURL != nil } set: { if !$0 { restoreURL = nil } },
            presenting: restoreURL
        ) { url in
            Button("Replace", role: .destructive) { restore(from: url) }
        } message: { _ in
            Text("Everything in mise is replaced with the backup's contents.")
        }
        .alert(
            "Backup failed",
            isPresented: Binding { backupError != nil } set: { if !$0 { backupError = nil } }
        ) {} message: {
            Text(backupError ?? "")
        }
    }

    private func restore(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try BackupService.restore(
                Data(contentsOf: url), context: modelContext, files: AttachmentFileStore(), defaults: .standard)
            store.reload()
            lock.reload()
        } catch {
            backupError = error.localizedDescription
        }
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
