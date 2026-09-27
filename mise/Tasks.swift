import SwiftUI
@preconcurrency import EventKit
#if !os(macOS)
import UIKit
#endif

/// Reminders layer: one `EKEventStore`, full-access only (SPEC §6.2). Callers
/// set EKReminder properties (title, notes, priority, dueDateComponents,
/// recurrenceRules, alarms, calendar) directly, then `save`.
@Observable final class RemindersStore {
    let eventStore = EKEventStore()
    var status: EKAuthorizationStatus
    var reminders: [EKReminder] = []
    var lists: [EKCalendar] = []
    private var refreshGeneration = 0

    var hasAccess: Bool { status == .fullAccess }

    init() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        let store = eventStore
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged, object: store) {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToReminders()
        status = EKEventStore.authorizationStatus(for: .reminder)
        await refresh()
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        status = EKEventStore.authorizationStatus(for: .reminder)
        guard hasAccess else {
            lists = []
            reminders = []
            return
        }
        let newLists = eventStore.calendars(for: .reminder)
        let fetched = await fetchAllReminders()
        guard generation == refreshGeneration else { return }
        lists = newLists
        reminders = fetched.sorted { lhs, rhs in
            if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
            switch (lhs.dueDate, rhs.dueDate) {
            case (.some(let l), .some(let r)) where l != r: return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (lhs.title ?? "") < (rhs.title ?? "")
            }
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        let store = eventStore
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                nonisolated(unsafe) let reminders = reminders ?? []  // EKReminder isn't Sendable; handed straight back to the main actor
                continuation.resume(returning: reminders)
            }
        }
    }

    private func fetchAllReminders() async -> [EKReminder] {
        let store = eventStore
        // ponytail: 7-day completed window keeps a just-checked row visible;
        // the full completed log (#17) needs its own fetch.
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
            + fetch(store.predicateForCompletedReminders(withCompletionDateStarting: weekAgo, ending: nil, calendars: nil))
    }

    func newReminder(in list: EKCalendar? = nil) -> EKReminder {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = list ?? eventStore.defaultCalendarForNewReminders()
        return reminder
    }

    func save(_ reminder: EKReminder) throws {
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            reminder.rollback()
            throw error
        }
        if let index = reminders.firstIndex(where: { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }) {
            reminders[index] = reminder
        } else {
            reminders.append(reminder)
        }
    }

    func setCompleted(_ reminder: EKReminder, _ done: Bool) throws {
        reminder.isCompleted = done
        try save(reminder)
    }

    func delete(_ reminder: EKReminder) throws {
        try eventStore.remove(reminder, commit: true)
        reminders.removeAll { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
    }

    func newList(title: String) throws -> EKCalendar {
        let source = eventStore.defaultCalendarForNewReminders()?.source
            ?? eventStore.sources.first { !$0.calendars(for: .reminder).isEmpty }
        guard let source else {
            throw RemindersStoreError.noSourceAvailable
        }
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = title
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        lists.append(calendar)
        return calendar
    }

    func deleteList(_ list: EKCalendar) throws {
        try eventStore.removeCalendar(list, commit: true)
        lists.removeAll { $0.calendarIdentifier == list.calendarIdentifier }
        reminders.removeAll { $0.calendar?.calendarIdentifier == list.calendarIdentifier }
    }
}

enum RemindersStoreError: Error {
    case noSourceAvailable
}

// dueDateComponents built by hand (no calendar attached) don't produce a
// `.date` — resolve them against the current calendar instead.
extension EKReminder {
    fileprivate var dueDate: Date? {
        dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }
}

struct TasksView: View {
    @Environment(RemindersStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("Tasks")
            .themedBackground()
            .task { await store.refresh() }
            .alert(
                "Couldn't update reminder",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK") { errorMessage = nil }
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .notDetermined:
            ContentUnavailableView {
                Label("Tasks", systemImage: "checklist")
            } description: {
                Text("mise needs access to Reminders to show your tasks.")
            } actions: {
                Button("Allow Access") { Task { await store.requestAccess() } }
            }
        case .fullAccess:
            if store.reminders.isEmpty {
                ContentUnavailableView("No Reminders", systemImage: "checklist")
            } else {
                remindersList
            }
        default:
            ContentUnavailableView {
                Label("Full Access Needed", systemImage: "lock")
            } description: {
                Text("mise needs full access to Reminders. Enable it in Settings.")
            } actions: {
                Button("Open Settings") { openSettings() }
            }
        }
    }

    private var remindersList: some View {
        List {
            ForEach(store.lists, id: \.calendarIdentifier) { list in
                let items = store.reminders.filter { $0.calendar?.calendarIdentifier == list.calendarIdentifier }
                if !items.isEmpty {
                    Section(list.title) {
                        ForEach(items, id: \.calendarItemIdentifier) { reminder in
                            row(for: reminder)
                        }
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
    }

    private func row(for reminder: EKReminder) -> some View {
        HStack {
            Button {
                mutate { try store.setCompleted(reminder, !reminder.isCompleted) }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading) {
                Text(reminder.title ?? "").strikethrough(reminder.isCompleted)
                if let date = reminder.dueDate {
                    Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                mutate { try store.delete(reminder) }
            }
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                mutate { try store.delete(reminder) }
            }
        }
    }

    private func mutate(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            openURL(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
        #endif
    }
}
