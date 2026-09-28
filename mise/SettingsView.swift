import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ThemeStore.self) private var store
    @Environment(AppLock.self) private var lock
    @Environment(CalendarStore.self) private var calendars
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
    @AppStorage(AutoBackup.enabledKey) private var autoBackupEnabled = false
    @AppStorage(AutoBackup.keepKey) private var autoBackupKeep = 4
    @AppStorage(AutoBackup.lastKey) private var autoBackupLast: Date?
    @AppStorage(AutoBackup.lastErrorKey) private var autoBackupError: String?
    @State private var autoBackupFolder = AutoBackup.folderURL()?.lastPathComponent
    @State private var isPickingFolder = false
    @State private var showingCalendarSettings = false
    @AppStorage(TravelTime.transportKey) private var travelTransport = TravelTime.Transport.driving
    @AppStorage(TravelTime.bufferKey) private var travelBuffer = 10
    @AppStorage(WorkingHours.startKey) private var workStart = WorkingHours.standard.start
    @AppStorage(WorkingHours.endKey) private var workEnd = WorkingHours.standard.end
    @AppStorage(WorkingHours.daysKey) private var workDays = WorkingHours.digits(WorkingHours.standard.weekdays)

    /// Minutes after midnight as a time of day today.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        } set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private var weekdayOrder: [Int] { (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 } }

    private func workday(_ day: Int) -> Binding<Bool> {
        Binding {
            WorkingHours.weekdays(from: workDays).contains(day)
        } set: { on in
            var days = WorkingHours.weekdays(from: workDays)
            if on { days.insert(day) } else { days.remove(day) }
            workDays = WorkingHours.digits(days)
        }
    }

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

            Section("Calendar") {
                #if os(iOS)
                NavigationLink("Calendars") { CalendarSettingsView() }
                #else
                // Mac detail column has no NavigationStack to push onto.
                Button("Calendars…") { showingCalendarSettings = true }
                    .sheet(isPresented: $showingCalendarSettings) { CalendarSettingsSheet() }
                #endif
            }
            .listRowBackground(Color(theme.surface))

            Section {
                Picker("Travel by", selection: $travelTransport) {
                    ForEach(TravelTime.Transport.allCases, id: \.self) { Text($0.title) }
                }
                Stepper("Leave \(travelBuffer) min early", value: $travelBuffer, in: 0...120, step: 5)
            } header: {
                Text("Leave-now alerts")
            } footer: {
                Text("Travel time is refreshed when the app opens and when iOS runs background refresh, so it can be out of date.")
            }
            .onChange(of: travelTransport) { Task { await TravelTime.refresh(store: calendars, prompt: false) } }
            .onChange(of: travelBuffer) { Task { await TravelTime.refresh(store: calendars, prompt: false) } }
            .listRowBackground(Color(theme.surface))

            Section {
                DatePicker("Start", selection: time($workStart), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: time($workEnd), displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(weekdayOrder, id: \.self) { day in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: workday(day))
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                            .frame(maxWidth: .infinity)
                    }
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)  // separate tap targets inside a Form row
                if workEnd <= workStart {
                    Text("End must be after start, so no slots will be suggested.").foregroundStyle(.red)
                }
            } header: {
                Text("Working hours")
            } footer: {
                Text("Used to suggest free slots for tasks.")
            }
            .listRowBackground(Color(theme.surface))

            Section("On-device AI") {
                Text(OnDeviceAI.unavailableReason ?? "Available").foregroundStyle(.secondary)
            }
            .listRowBackground(Color(theme.surface))

            #if os(iOS)
            // ponytail: spike row, replaced by Finance import later
            Section("Spike: shared inbox") {
                let inbox = SharedInbox.files
                LabeledContent("Files", value: "\(inbox.count)")
                Text(inbox.first?.lastPathComponent ?? "Empty").foregroundStyle(.secondary)
            }
            .listRowBackground(Color(theme.surface))
            #endif

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
                Toggle("Weekly automatic backup", isOn: $autoBackupEnabled)
                Button("Choose folder…") { isPickingFolder = true }
                    .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                        do {
                            let url = try result.get()
                            let accessing = url.startAccessingSecurityScopedResource()
                            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                            try AutoBackup.setFolder(url)
                            autoBackupFolder = url.lastPathComponent
                            AutoBackup.run(context: modelContext)
                        } catch {
                            backupError = error.localizedDescription
                        }
                    }
                Text(autoBackupFolder.map { "Folder: \($0)" } ?? "No folder chosen.")
                    .foregroundStyle(.secondary)
                Stepper("Keep last \(autoBackupKeep)", value: $autoBackupKeep, in: 1...20)
                if let autoBackupLast {
                    Text("Last automatic backup: \(autoBackupLast.formatted())").foregroundStyle(.secondary)
                }
                if let autoBackupError {
                    Text(autoBackupError).foregroundStyle(.red)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("API keys are not included.")
            }
            .listRowBackground(Color(theme.surface))

            #if os(iOS)
            Section("Appearance") {
                NavigationLink("App icon") { AppIconPicker() }
            }
            .listRowBackground(Color(theme.surface))
            #endif

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
            calendars.reloadSettings()
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
