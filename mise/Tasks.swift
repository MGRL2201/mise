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
        // Refetched EKReminders are == the old ones (isEqual) even after an
        // external edit, so a plain assignment skips @Observable's notify (#126).
        withMutation(keyPath: \.reminders) {
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
        if let event = linkedEvent(for: reminder) {
            event.title = TimeBlock.title(event.title ?? "", done: done)
            // Best effort: the reminder is already saved; a stale event title isn't worth failing it.
            do { try eventStore.save(event, span: .thisEvent, commit: true) } catch { event.rollback() }
        }
    }

    func delete(_ reminder: EKReminder, deletingEvent: Bool = false) throws {
        let event = deletingEvent ? linkedEvent(for: reminder) : nil
        try eventStore.remove(reminder, commit: true)
        reminders.removeAll { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
        // Best effort: the task is already gone; don't report an error for it.
        if let event { try? eventStore.remove(event, span: .thisEvent, commit: true) }
    }

    /// The time-block event linked via TaskExtras; nil without a context or link.
    func linkedEvent(for reminder: EKReminder) -> EKEvent? {
        guard let context,
              let rows = try? context.fetch(FetchDescriptor<TaskExtras>()),
              let eventID = TaskExtras.match(rows, id: reminder.calendarItemIdentifier,
                                             externalID: reminder.calendarItemExternalIdentifier)?.eventID
        else { return nil }
        return eventStore.event(withIdentifier: eventID)
    }

    /// Deletes the linked time-block event (if any) and clears the link.
    func removeTimeBlock(for reminder: EKReminder) throws {
        guard let context else { return }
        if let event = linkedEvent(for: reminder) { try eventStore.remove(event, span: .thisEvent, commit: true) }
        try TaskExtras.setEventID(nil, in: context, reminderID: reminder.calendarItemIdentifier,
                                  externalID: reminder.calendarItemExternalIdentifier)
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
    case today = "Today", upcoming = "Upcoming", lists = "Lists", priority = "Priority", completed = "Done"

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
    @Environment(\.modelContext) private var context
    @State private var errorMessage: String?
    @State private var mode = TaskViewMode.today
    @State private var editing: EditingReminder?
    @State private var filterTag: String?
    @State private var quickText = ""
    @State private var parsing = false
    @State private var dictation = Dictation()
    @State private var showingGuide = false
    @State private var visible = false
    @State private var deleting: EKReminder?
    // Unknown `#list` prompts; separate so "No" can hand off to `creating` without the dismiss setter clobbering it.
    @State private var suggesting: Suggestion?
    @State private var creating: QuickAdd?
    @State private var expanded: Set<String> = []  // calendarItemIdentifiers showing subtasks
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query private var extras: [TaskExtras]

    private struct EditingReminder: Identifiable {
        let reminder: EKReminder
        var id: String { reminder.calendarItemIdentifier }
    }

    private struct Suggestion {
        let quick: QuickAdd
        let list: String
    }

    var body: some View {
        quickAddPrompts(mainView)
            .onChange(of: dictation.transcript) { if dictation.isRecording { quickText = $1 } }
            .sheet(isPresented: $showingGuide) { QuickAddGuide() }
            .alert("Can't dictate", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } }),
                   presenting: dictation.error) { message in
                if message == Dictation.micDenied {
                    Button("Open Settings") {
                        if let url = privacySettingsURL(macAnchor: "Privacy_Microphone") { openURL(url) }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { Text($0) }
    }

    private var mainView: some View {
        content
            .navigationTitle("Tasks")
            .themedBackground()
            .toolbar {
                if store.hasAccess && !tags.isEmpty {
                    Menu("Tag", systemImage: activeTag == nil ? "tag" : "tag.fill") {
                        Picker("Tag", selection: $filterTag) {
                            Text("All Tags").tag(String?.none)
                            ForEach(tags.map(\.name), id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    }
                }
                if store.hasAccess {
                    Button("Plan Day", systemImage: "sun.horizon") { PlanningPrompt.shared.isPresented = true }
                    Button("New Task", systemImage: "plus") { editing = EditingReminder(reminder: store.newReminder()) }
                        .disabled(parsing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if store.hasAccess {
                    HStack {
                        TextField("Quick add", text: $quickText, prompt: Text("Quick add: pay rent every 1st 9am !high"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(quickAdd)
                            .disabled(parsing)
                        if parsing { ProgressView().controlSize(.small) }
                        Button(dictation.isRecording ? "Stop dictation" : "Dictate task",
                               systemImage: dictation.isRecording ? "stop.circle.fill" : "mic", action: toggleDictation)
                            .labelStyle(.iconOnly)
                            .disabled(parsing || dictation.busy)
                        Button("Quick add guide", systemImage: "questionmark.circle") { showingGuide = true }
                            .labelStyle(.iconOnly)
                    }
                    .padding()
                }
            }
            .sheet(item: $editing) { TaskEditor(reminder: $0.reminder) }
            .confirmationDialog("Delete this task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                presenting: deleting) { reminder in
                Button("Delete Task and Event", role: .destructive) { mutate { try store.delete(reminder, deletingEvent: true) } }
                Button("Delete Task Only", role: .destructive) { mutate { try store.delete(reminder) } }
            }
            .task {
                await store.refresh()
                #if DEBUG
                // Screenshot hook: `-miseTab tasks -miseSuggest 1` opens the first open task with free-slot suggestions.
                if UserDefaults.standard.bool(forKey: "miseSuggest"), let first = store.reminders.first(where: { !$0.isCompleted }) {
                    editing = EditingReminder(reminder: first)
                }
                #endif
            }
            .onAppear { visible = true }
            .onDisappear { visible = false; if dictation.isRecording { Task { _ = await dictation.stop() } } }
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

    /// Parsed fields land in the editor sheet for confirmation; nothing is saved until the user saves there.
    private func quickAdd() {
        let text = quickText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parsing = true
        Task {
            // ponytail: two writable lists with the same title resolve to the first; user confirms in editor.
            let writable = store.lists.filter(\.allowsContentModifications)
            let q = await QuickAdd.parseSmart(text, lists: writable.map(\.title))
            quickText = ""
            parsing = false
            if q.listName == nil, let name = q.unknownList {
                if let list = QuickAdd.closeMatch(name, in: writable.map(\.title)) {
                    suggesting = Suggestion(quick: q, list: list)
                } else {
                    creating = q
                }
            } else {
                openEditor(q)
            }
        }
    }

    /// Tap to start; tap again to stop and send the transcript through `quickAdd()`.
    private func toggleDictation() {
        Task {
            if dictation.isRecording {
                quickText = QuickAdd.fromSpeech(await dictation.stop())
                if dictation.error == nil { quickAdd() }
            } else {
                quickText = ""
                await dictation.start()
                if !visible { _ = await dictation.stop() }  // left while start() awaited permission/model
            }
        }
    }

    /// Unknown `#list` prompts. Button actions run before the dismiss setter, so a non-nil value there means dismissed without a choice.
    private func quickAddPrompts(_ view: some View) -> some View {
        view
            .confirmationDialog(Text(suggesting.map { "Did you mean \($0.list)?" } ?? ""),
                                isPresented: Binding(get: { suggesting != nil }, set: { if !$0, let s = suggesting { suggesting = nil; creating = s.quick } }),
                                titleVisibility: .visible, presenting: suggesting) { s in
                Button("Use \(s.list)") {
                    var q = s.quick
                    q.listName = s.list
                    suggesting = nil
                    openEditor(q)
                }
                Button("No", role: .cancel) {}  // dismiss setter moves on to the create prompt
            }
            .alert(Text(creating.map { "Create list \"\($0.unknownList ?? "")\"?" } ?? ""),
                   isPresented: Binding(get: { creating != nil }, set: { if !$0, let q = creating { creating = nil; openEditor(q) } }),
                   presenting: creating) { q in
                Button("Create") {
                    creating = nil
                    var q = q
                    if let name = q.unknownList {
                        // ponytail: failure is silent (editor shows the default list); upgrade = open editor from the error alert's OK.
                        q.listName = try? store.newList(title: name).title
                    }
                    openEditor(q)
                }
                Button("Use Default List", role: .cancel) { creating = nil; openEditor(q) }
            }
    }

    private func openEditor(_ q: QuickAdd) {
        let r = store.newReminder()
        q.apply(to: r, lists: store.lists.filter(\.allowsContentModifications))
        editing = EditingReminder(reminder: r)
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

    /// The filter tag, if it still exists: a tag removed elsewhere (restore) stops
    /// filtering instead of hiding everything.
    private var activeTag: String? {
        filterTag.flatMap { name in tags.contains { $0.name == name } ? name : nil }
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
        guard let activeTag else { return result.filter { !$0.items.isEmpty } }
        let tagged = { (r: EKReminder) in
            TaskExtras.match(extras, id: r.calendarItemIdentifier, externalID: r.calendarItemExternalIdentifier)?
                .tags?.contains { $0.name == activeTag } ?? false
        }
        return result.map { ($0.title, $0.items.filter(tagged)) }.filter { !$0.items.isEmpty }
    }

    @ViewBuilder
    private var remindersList: some View {
        let sections = sections
        if sections.isEmpty {
            ContentUnavailableView(activeTag.map { "No Tasks Tagged \($0)" } ?? mode.emptyTitle, systemImage: "checklist")
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

    @ViewBuilder
    private func row(for reminder: EKReminder) -> some View {
        let id = reminder.calendarItemIdentifier
        // ponytail: O(rows x extras) linear match per row; build a [reminderID: TaskExtras] dict per body pass if lists get large.
        let extra = TaskExtras.match(extras, id: id, externalID: reminder.calendarItemExternalIdentifier)
        let subtasks = extra?.subtasks ?? []
        let isExpanded = expanded.contains(id)
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
                    let tagNames = (extra?.tags ?? []).map(\.name).sorted()
                    if !tagNames.isEmpty {
                        // ponytail: one HStack line; many long tags clip instead of wrapping.
                        HStack(spacing: 4) {
                            ForEach(tagNames, id: \.self) { name in
                                Text(name).font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if extra?.flagged == true {
                Image(systemName: "flag.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Flagged")
            }
            if !subtasks.isEmpty {
                let done = subtasks.filter(\.done).count
                Text("\(done)/\(subtasks.count)").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("\(done) of \(subtasks.count) subtasks done")
                // Custom chevron, not DisclosureGroup: its label tap would steal the row's tap-to-edit.
                Button {
                    withAnimation { if isExpanded { expanded.remove(id) } else { expanded.insert(id) } }
                } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Hide subtasks" : "Show subtasks")
            }
        }
        .swipeActions {
            // No .destructive role: it animates the row out before the linked-event dialog shows.
            Button("Delete") { delete(reminder) }.tint(.red)
        }
        .contextMenu {
            Button("Delete", role: .destructive) { delete(reminder) }
        }
        if isExpanded, let extra {
            ForEach(subtasks) { subtask in
                Button {
                    mutate { try TaskExtras.toggleSubtask(subtask.id, in: extra, context: context) }
                } label: {
                    HStack {
                        Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                        Text(subtask.title).strikethrough(subtask.done)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(subtask.done ? .isSelected : [])
                .padding(.leading, 28)
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

    /// Asks whether to take the linked time-block event along; plain tasks go immediately.
    private func delete(_ reminder: EKReminder) {
        if store.linkedEvent(for: reminder) != nil {
            deleting = reminder
        } else {
            mutate { try store.delete(reminder) }
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
