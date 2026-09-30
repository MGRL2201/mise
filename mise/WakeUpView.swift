import SwiftUI
import SwiftData
#if os(iOS)
import AlarmKit
import UserNotifications
#endif

/// Wake-up alarms (iPhone) and the out-of-bed history (#132).
struct WakeUpView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Query(sort: [SortDescriptor(\WakeAlarm.hour), SortDescriptor(\WakeAlarm.minute)]) private var alarms: [WakeAlarm]
    @Query(WakeUpView.recentLogs) private var logs: [WakeLog]
    #if os(iOS)
    @Environment(\.openURL) private var openURL
    @State private var auth = AlarmManager.shared.authorizationState
    @State private var editing: WakeAlarm?
    @State private var isAdding = false
    @State private var errorMessage: String?
    @AppStorage(WakePhrase.key) private var phrase = WakePhrase.standard
    #endif

    private static var recentLogs: FetchDescriptor<WakeLog> {
        var descriptor = FetchDescriptor<WakeLog>(sortBy: [SortDescriptor(\.day, order: .reverse)])
        descriptor.fetchLimit = 30
        return descriptor
    }

    var body: some View {
        Form {
            #if os(iOS)
            if WakePending.current() != nil {
                Section { Button("Confirm you're up") { WakePrompt.shared.show() } }
                    .listRowBackground(Color(theme.surface))
            }
            if auth != .authorized { authorizationSection }
            alarmsSection
            Section("Wake-up phrase") {
                TextField(WakePhrase.standard, text: $phrase)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .listRowBackground(Color(theme.surface))
            #else
            Section { Text("Wake-up alarms ring on iPhone.").foregroundStyle(.secondary) }
                .listRowBackground(Color(theme.surface))
            #endif
            historySection
        }
        .navigationTitle("Wake-up")
        .themedBackground()
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Alarm", systemImage: "plus") {
                    Task {
                        if auth == .notDetermined { await requestAuthorization() }
                        _ = await LocalNotifications.authorized()
                        isAdding = true
                    }
                }
            }
        }
        .sheet(item: $editing) { WakeAlarmEditor(alarm: $0) }
        .sheet(isPresented: $isAdding) { WakeAlarmEditor(alarm: nil) }
        .scheduleErrorAlert($errorMessage)
        .onChange(of: auth) { if auth == .authorized { Task { await WakeAlarms.sync(alarms) } } }
        .task {
            await WakeAlarms.sync(alarms)
            for await state in AlarmManager.shared.authorizationUpdates { auth = state }
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder private var authorizationSection: some View {
        Section {
            if auth == .denied {
                Text("Alarm access is off, so wake-up alarms can't ring.")
                Button("Open Settings") {
                    if let url = privacySettingsURL(macAnchor: "") { openURL(url) }
                }
            } else {
                Button("Allow alarms") { Task { await requestAuthorization() } }
            }
        }
        .listRowBackground(Color(theme.surface))
    }

    private func requestAuthorization() async {
        if let state = try? await AlarmManager.shared.requestAuthorization() { auth = state }
    }

    private var alarmsSection: some View {
        Section {
            ForEach(alarms, content: row)
                .onDelete { offsets in
                    for alarm in offsets.map({ alarms[$0] }) {
                        WakeAlarms.cancel(alarm.id)
                        modelContext.delete(alarm)
                    }
                    try? modelContext.save()
                }
        } header: {
            Text("Alarms")
        } footer: {
            Text("Stop rings again in 5 minutes, up to 12 times, until you type your phrase in mise.")
        }
        .listRowBackground(Color(theme.surface))
    }

    private func row(_ alarm: WakeAlarm) -> some View {
        HStack {
            Button { editing = alarm } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.time(hour: alarm.hour, minute: alarm.minute)).font(.title2)
                    Text(Self.weekdayOrder().filter(alarm.weekdays.contains)
                        .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if alarm.isOn, let next = WakeSchedule.nextFire(hour: alarm.hour, minute: alarm.minute, weekdays: alarm.weekdays,
                                                                      after: .now, calendar: .current) {
                        Text("Next: \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("On", isOn: Binding { alarm.isOn } set: {
                alarm.isOn = $0
                try? modelContext.save()
                Task {
                    do {
                        try await WakeAlarms.schedule(alarm)
                    } catch {
                        alarm.isOn = false
                        try? modelContext.save()
                        errorMessage = WakeAlarms.message(for: error)
                    }
                }
            })
            .labelsHidden()
        }
    }
    #endif

    private var historySection: some View {
        Section("History") {
            if logs.isEmpty {
                Text("No mornings logged yet").foregroundStyle(.secondary)
            } else {
                if let average = WakeSchedule.averageOutOfBed(logs, calendar: .current) {
                    LabeledContent("Average out of bed", value: Self.time(hour: average / 60, minute: average % 60))
                }
                ForEach(logs) { log in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.day.formatted(.dateTime.weekday(.abbreviated).month().day()))
                        Text(Self.summary(log)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listRowBackground(Color(theme.surface))
    }

    /// "Rang 6:30 · 3 re-rings · Up 6:47".
    private static func summary(_ log: WakeLog) -> String {
        let rang = log.firstRing.formatted(date: .omitted, time: .shortened)
        let count = min(log.reRings, WakeSchedule.maxReRings)  // a tap on the last ring still counts one
        let reRings = count == 1 ? "1 re-ring" : "\(count) re-rings"
        let up = log.outOfBed.map { "Up " + $0.formatted(date: .omitted, time: .shortened) } ?? "Not up yet"
        return "Rang \(rang) · \(reRings) · \(up)"
    }

    static func time(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Calendar weekday numbers (1 = Sunday) starting at the locale's first weekday.
    static func weekdayOrder(_ calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }
}

#if os(iOS)
/// Full-screen prompt after Stop: typing the phrase logs out of bed and cancels the pending re-ring (#157).
struct WakeConfirmView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WakePhrase.key) private var phrase = WakePhrase.standard
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                Text("Type “\(phrase)” to stop the next alarm.")
                TextField("Phrase", text: Binding { typed } set: { if WakePhrase.isTyped(old: typed, new: $0) { typed = $0 } })
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(confirm)
                Button("Confirm", action: confirm)
            }
            .navigationTitle("Confirm you're up")
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } }
            }
        }
    }

    private func confirm() {
        guard let pending = try? WakeFlow.confirm(typed, phrase: phrase, now: .now, context: modelContext, defaults: .standard) else { return }
        if let id = pending.reRingID { WakeAlarms.cancel(id) }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [WakePrompt.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [WakePrompt.notificationID])
        dismiss()
    }
}

/// New or existing alarm: time and repeat days. Weekdays are required (no one-off alarms).
private struct WakeAlarmEditor: View {
    let alarm: WakeAlarm?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var errorMessage: String?
    /// The new alarm once inserted, so retrying Save after an error doesn't insert another.
    @State private var inserted: WakeAlarm?

    init(alarm: WakeAlarm?) {
        self.alarm = alarm
        _time = State(initialValue: Calendar.current.date(bySettingHour: alarm?.hour ?? 7, minute: alarm?.minute ?? 0, second: 0, of: .now) ?? .now)
        _weekdays = State(initialValue: Set(alarm?.weekdays ?? [2, 3, 4, 5, 6]))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                Section("Repeat") {
                    HStack {
                        ForEach(WakeUpView.weekdayOrder(), id: \.self) { day in
                            let on = weekdays.contains(day)
                            Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                                if on { weekdays.remove(day) } else { weekdays.insert(day) }
                            }
                            .buttonStyle(.bordered)
                            .tint(on ? .accentColor : .secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Calendar.current.standaloneWeekdaySymbols[day - 1])
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                if let alarm {
                    Section {
                        Button("Delete Alarm", role: .destructive) {
                            WakeAlarms.cancel(alarm.id)
                            modelContext.delete(alarm)
                            try? modelContext.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(alarm == nil ? "New Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .themedBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(weekdays.isEmpty)
                }
            }
            .scheduleErrorAlert($errorMessage)
        }
    }

    private func save() async {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let target = alarm ?? inserted ?? WakeAlarm(hour: 7, minute: 0, weekdays: [])
        if alarm == nil && inserted == nil {
            modelContext.insert(target)
            inserted = target
        }
        target.hour = parts.hour ?? 7
        target.minute = parts.minute ?? 0
        target.weekdays = weekdays.sorted()
        if alarm == nil { target.isOn = true } // new alarm defaults on; editing keeps the user's on/off choice
        try? modelContext.save()
        do {
            try await WakeAlarms.schedule(target)
            dismiss()
        } catch {
            target.isOn = false
            try? modelContext.save()
            errorMessage = WakeAlarms.message(for: error)
        }
    }
}

private extension View {
    func scheduleErrorAlert(_ message: Binding<String?>) -> some View {
        alert("Couldn't schedule this alarm.", isPresented: Binding { message.wrappedValue != nil } set: { if !$0 { message.wrappedValue = nil } }) {
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
#endif
