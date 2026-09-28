import SwiftUI
import EventKit

/// Per-calendar visibility and color, plus the default calendar for new events (#27).
struct CalendarSettingsView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if store.hasAccess {
                form
            } else {
                ContentUnavailableView("No Calendar Access", systemImage: "calendar",
                                       description: Text("Allow access from the Calendar tab."))
            }
        }
        .navigationTitle("Calendars")
        .themedBackground()
        .task { if store.calendars.isEmpty { await store.refresh() } }
    }

    private var form: some View {
        // Stale or unset defaultCalendarID shows the effective default.
        // Choosing a hidden calendar as default un-hides it, else new events vanish after saving.
        let defaultID = Binding { store.defaultCalendar?.calendarIdentifier } set: {
            store.defaultCalendarID = $0
            if let id = $0 { store.hiddenCalendarIDs.remove(id) }
        }
        let sources = Dictionary(grouping: store.calendars) { $0.source?.sourceIdentifier ?? "" }
            .map { (key: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { ($0.calendars[0].source?.title ?? "", $0.key) < ($1.calendars[0].source?.title ?? "", $1.key) }
        return Form {
            Section {
                Picker("Default Calendar", selection: defaultID) {
                    if store.defaultCalendar == nil { Text("None").tag(String?.none) }
                    ForEach(store.calendars.filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                        Text(calendar.title).tag(Optional(calendar.calendarIdentifier))
                    }
                }
            } footer: {
                Text("Used for new events and time blocks.")
            }
            .listRowBackground(Color(theme.surface))

            ForEach(sources, id: \.key) { source in
                Section(source.calendars[0].source?.title ?? "Other") {
                    ForEach(source.calendars, id: \.calendarIdentifier, content: row)
                }
                .listRowBackground(Color(theme.surface))
            }
        }
    }

    private func row(_ calendar: EKCalendar) -> some View {
        let id = calendar.calendarIdentifier
        return HStack(spacing: 12) {
            ColorPicker("\(calendar.title) color", selection: Binding { store.color(for: calendar) } set: {
                store.colorOverrides[id] = $0.resolve(in: EnvironmentValues())
            }, supportsOpacity: false)
            .labelsHidden()
            Toggle(calendar.title, isOn: Binding { !store.hiddenCalendarIDs.contains(id) } set: {
                if $0 { store.hiddenCalendarIDs.remove(id) } else { store.hiddenCalendarIDs.insert(id) }
            })
            .disabled(id == store.defaultCalendar?.calendarIdentifier)  // hiding the default would hide new events
        }
        .contextMenu {
            if store.colorOverrides[id] != nil {
                Button("Reset Color") { store.colorOverrides[id] = nil }
            }
        }
    }
}

/// CalendarSettingsView in a sheet, for hosts without a NavigationStack to push onto.
struct CalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CalendarSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
