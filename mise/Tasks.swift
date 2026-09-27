import SwiftUI
import SwiftData
@preconcurrency import EventKit
#if !os(macOS)
import UIKit
#endif

/// Reminders layer: one `EKEventStore`, full-access only (SPEC §6.2). Callers
/// set EKReminder properties (title, notes, priority, dueDateComponents,
/// recurrenceRules, alarms, calendar) directly, then `save`.
@Observable final class RemindersStore {
    let eventStore: EKEventStore
    var status: EKAuthorizationStatus
    var reminders: [EKReminder] = []
    var lists: [EKCalendar] = []
    private var refreshGeneration = 0
    /// SwiftData context for TaskExtras cleanup after each refresh; nil skips it.
    private let context: ModelContext?

    var hasAccess: Bool { status == .fullAccess }

    init(eventStore: EKEventStore = EKEventStore(), context: ModelContext? = nil) {
        self.eventStore = eventStore
        self.context = context
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
        guard let context else { return }
        let store = eventStore
        // Best-effort orphan cleanup; `exists` covers reminders outside the fetch window.
        try? TaskExtras.reconcile(context, reminders: reminders.map { ($0.calendarItemIdentifier, $0.calendarItemExternalIdentifier) }) {
            store.calendarItem(withIdentifier: $0.reminderID) != nil
                || ($0.externalID.map { !$0.isEmpty && !store.calendarItems(withExternalIdentifier: $0).isEmpty } ?? false)
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
        // ponytail: completed log shows the last 30 days; longer history needs a paged fetch.
        let monthAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        return await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
            + fetch(store.predicateForCompletedReminders(withCompletionDateStarting: monthAgo, ending: nil, calendars: nil))
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

/// Pure grouping rules for the task views; no EventKit.
enum TaskGrouping {
    enum DueBucket { case overdue, today, upcoming }
    enum Priority: String, CaseIterable { case high = "High", medium = "Medium", low = "Low", none = "None" }

    /// nil = no due date or beyond today+7. Timed reminders go overdue at their
    /// time; all-day ones only once their day has passed.
    static func dueBucket(_ due: DateComponents?, now: Date, calendar: Calendar) -> DueBucket? {
        guard let due, let date = calendar.date(from: due) else { return nil }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if due.hour != nil ? date < now : day < today { return .overdue }
        switch calendar.dateComponents([.day], from: today, to: day).day ?? 0 {
        case 0: return .today
        case 1...7: return .upcoming
        default: return nil
        }
    }

    /// Groups by start of day, ascending; items without a date are dropped.
    static func dayGroups<T>(_ items: [T], calendar: Calendar, date: (T) -> Date?) -> [(day: Date, items: [T])] {
        let dated = items.compactMap { item in date(item).map { (calendar.startOfDay(for: $0), item) } }
        return Dictionary(grouping: dated, by: \.0)
            .map { (day: $0.key, items: $0.value.map(\.1)) }
            .sorted { $0.day < $1.day }
    }

    /// EventKit priority: 1-4 high, 5 medium, 6-9 low, 0 none.
    static func priorityBucket(_ priority: Int) -> Priority {
        switch priority {
        case 1...4: .high
        case 5: .medium
        case 6...9: .low
        default: .none
        }
    }
}

enum TaskViewMode: String, CaseIterable {
    case today = "Today", upcoming = "Upcoming", lists = "Lists", priority = "Priority", completed = "Completed"

    var emptyTitle: String {
        switch self {
        case .today: "Nothing Due Today"
        case .upcoming: "Nothing Upcoming"
        case .lists, .priority: "No Open Reminders"
        case .completed: "No Completed Reminders"
        }
    }
}

struct TasksView: View {
    @Environment(RemindersStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var errorMessage: String?
    @State private var mode = TaskViewMode.today
    @State private var editing: EditingReminder?

    private struct EditingReminder: Identifiable {
        let reminder: EKReminder
        var id: String { reminder.calendarItemIdentifier }
    }

    var body: some View {
        content
            .navigationTitle("Tasks")
            .themedBackground()
            .toolbar {
                if store.hasAccess {
                    Button("New Task", systemImage: "plus") { editing = EditingReminder(reminder: store.newReminder()) }
                }
            }
            .sheet(item: $editing) { TaskEditor(reminder: $0.reminder) }
            .task { await store.refresh() }
            // ponytail: day rollover only; timed reminders passing their due time mid-day don't turn red until the next re-render.
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in Task { await store.refresh() } }
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
                    .safeAreaInset(edge: .top) {
                        Picker("View", selection: $mode) {
                            ForEach(TaskViewMode.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal)
                    }
            }
        default:
            ContentUnavailableView {
                Label("Full Access Needed", systemImage: "lock")
            } description: {
                Text("mise needs full access to Reminders. Enable it in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = privacySettingsURL(macAnchor: "Privacy_Reminders") { openURL(url) }
                }
            }
        }
    }

    private var sections: [(title: String, items: [EKReminder])] {
        let calendar = Calendar.current
        let now = Date.now
        // Open views keep today's completions so a just-checked row can be unchecked.
        let open = store.reminders.filter { !$0.isCompleted || $0.completionDate.map(calendar.isDateInToday) == true }
        let bucket = { (r: EKReminder) in TaskGrouping.dueBucket(r.dueDateComponents, now: now, calendar: calendar) }
        let dayTitle = { (day: Date) in day.formatted(.dateTime.weekday(.wide).month().day()) }
        let result: [(title: String, items: [EKReminder])]
        switch mode {
        case .today:
            result = [("Overdue", open.filter { bucket($0) == .overdue }), ("Today", open.filter { bucket($0) == .today })]
        case .upcoming:
            result = TaskGrouping.dayGroups(open.filter { bucket($0) == .upcoming }, calendar: calendar) { $0.dueDate }
                .map { (dayTitle($0.day), $0.items) }
        case .lists:
            result = store.lists.map { list in
                (list.title, open.filter { $0.calendar?.calendarIdentifier == list.calendarIdentifier })
            }
        case .priority:
            result = TaskGrouping.Priority.allCases.map { p in
                (p.rawValue, open.filter { TaskGrouping.priorityBucket($0.priority) == p })
            }
        case .completed:
            let completed = store.reminders.filter(\.isCompleted)
                .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
            result = TaskGrouping.dayGroups(completed, calendar: calendar) { $0.completionDate }
                .reversed()
                .map { (dayTitle($0.day), $0.items) }
        }
        return result.filter { !$0.items.isEmpty }
    }

    @ViewBuilder
    private var remindersList: some View {
        let sections = sections
        if sections.isEmpty {
            ContentUnavailableView(mode.emptyTitle, systemImage: "checklist")
        } else {
            List {
                ForEach(sections.indices, id: \.self) { index in
                    Section(sections[index].title) {
                        ForEach(sections[index].items, id: \.calendarItemIdentifier) { reminder in
                            row(for: reminder)
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private func row(for reminder: EKReminder) -> some View {
        HStack {
            Button {
                mutate { try store.setCompleted(reminder, !reminder.isCompleted) }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            Button {
                editing = EditingReminder(reminder: reminder)
            } label: {
                VStack(alignment: .leading) {
                    Text(reminder.title ?? "").strikethrough(reminder.isCompleted)
                    if let date = reminder.dueDate {
                        let overdue = !reminder.isCompleted
                            && TaskGrouping.dueBucket(reminder.dueDateComponents, now: .now, calendar: .current) == .overdue
                        Text(date, style: .date).font(.caption).foregroundStyle(overdue ? Color.red : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
}

/// App settings on iOS; the given Privacy pane (e.g. "Privacy_Calendars") on macOS.
func privacySettingsURL(macAnchor: String) -> URL? {
    #if os(macOS)
    URL(string: "x-apple.systempreferences:com.apple.preference.security?\(macAnchor)")
    #else
    URL(string: UIApplication.openSettingsURLString)
    #endif
}
