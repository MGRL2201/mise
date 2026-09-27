import SwiftUI
import SwiftData
@preconcurrency import EventKit

// ponytail: custom = frequency + "every N" only; end dates and specific weekdays aren't editable yet (existing ones survive untouched).
enum RecurrencePreset: String, CaseIterable {
    case none = "Never", daily = "Daily", weekdays = "Weekdays", weekly = "Weekly", biweekly = "Every 2 Weeks"
    case monthly = "Monthly", yearly = "Yearly", custom = "Custom"

    init(_ rule: EKRecurrenceRule?) {
        guard let rule else { self = .none; return }
        self = Self.allCases.first { $0.rule.map { Self.matches($0, rule) } ?? false } ?? .custom
    }

    var rule: EKRecurrenceRule? {
        switch self {
        case .none, .custom: nil
        case .daily: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekdays:
            EKRecurrenceRule(
                recurrenceWith: .weekly, interval: 1,
                daysOfTheWeek: [.monday, .tuesday, .wednesday, .thursday, .friday].map { EKRecurrenceDayOfWeek($0) },
                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil
            )
        case .weekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .biweekly: EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly: EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly: EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        }
    }

    private static func matches(_ a: EKRecurrenceRule, _ b: EKRecurrenceRule) -> Bool {
        let days = { (r: EKRecurrenceRule) in Set((r.daysOfTheWeek ?? []).map { [$0.dayOfTheWeek.rawValue, $0.weekNumber] }) }
        let extras = { (r: EKRecurrenceRule) in
            [r.daysOfTheMonth, r.monthsOfTheYear, r.weeksOfTheYear, r.daysOfTheYear, r.setPositions].allSatisfy { ($0 ?? []).isEmpty }
        }
        return a.frequency == b.frequency && a.interval == b.interval && b.recurrenceEnd == nil
            && days(a) == days(b) && extras(b)
    }
}

/// Plain editable copy of a reminder; nothing touches EventKit until `apply`.
struct TaskDraft: Equatable {
    var title = ""
    var notes = ""
    var hasDueDate = false
    var dueDate = Date()
    var includesTime = false
    var priority = 0
    var listID: String?
    var recurrence = RecurrencePreset.none
    var customFrequency = EKRecurrenceFrequency.daily
    var customInterval = 1
    var alarms: [Date] = []

    init(_ reminder: EKReminder) {
        title = reminder.title ?? ""
        notes = reminder.notes ?? ""
        if let due = reminder.dueDateComponents, let date = Calendar.current.date(from: due) {
            hasDueDate = true
            dueDate = date
            includesTime = due.hour != nil
        }
        priority = reminder.priority
        listID = reminder.calendar?.calendarIdentifier
        let rule = reminder.recurrenceRules?.first
        recurrence = RecurrencePreset(rule)
        if recurrence == .custom, let rule {
            customFrequency = rule.frequency
            customInterval = rule.interval
        }
        alarms = (reminder.alarms ?? []).compactMap(\.absoluteDate)
    }

    /// Picker-facing priority; setting the bucket the raw value already falls in keeps it (e.g. 3 stays 3).
    var priorityBucket: TaskGrouping.Priority {
        get { TaskGrouping.priorityBucket(priority) }
        set {
            guard newValue != priorityBucket else { return }
            priority = switch newValue { case .high: 1; case .medium: 5; case .low: 9; case .none: 0 }
        }
    }

    func apply(to reminder: EKReminder, lists: [EKCalendar]) {
        let before = TaskDraft(reminder)
        reminder.title = title
        reminder.notes = notes.isEmpty ? nil : notes
        reminder.priority = priority
        if let list = lists.first(where: { $0.calendarIdentifier == listID }) {
            reminder.calendar = list
        }
        // Only rewrite a changed due date, so timeZone/seconds set elsewhere survive. Start follows due
        // in Reminders.app; a moved or cleared due must not leave a stale start behind.
        if hasDueDate != before.hasDueDate
            || hasDueDate && (dueDate, includesTime) != (before.dueDate, before.includesTime) {
            let fields: Set<Calendar.Component> = includesTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = hasDueDate ? Calendar.current.dateComponents(fields, from: dueDate) : nil
            reminder.startDateComponents = nil
        }
        if hasDueDate {
            // Only rewrite recurrence the user changed, so rules we can't represent survive.
            if recurrence != before.recurrence
                || (recurrence == .custom && (customFrequency, customInterval) != (before.customFrequency, before.customInterval)) {
                let rule = recurrence == .custom
                    ? EKRecurrenceRule(recurrenceWith: customFrequency, interval: customInterval, end: nil)
                    : recurrence.rule
                reminder.recurrenceRules = rule.map { [$0] }
            }
        } else {
            reminder.recurrenceRules = nil  // EventKit requires a due date for recurrence
        }
        if alarms != before.alarms {
            let kept = (reminder.alarms ?? []).filter { $0.absoluteDate == nil }
            reminder.alarms = kept + alarms.map { EKAlarm(absoluteDate: $0) }
        }
    }
}

struct TaskEditor: View {
    let reminder: EKReminder
    @Environment(RemindersStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var draft: TaskDraft
    @State private var subtasks: [Subtask] = []
    @State private var tagNames: [String] = []
    @State private var newSubtask = ""
    @State private var newTag = ""
    @State private var loadedExtras = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

    init(reminder: EKReminder) {
        self.reminder = reminder
        _draft = State(initialValue: TaskDraft(reminder))
    }

    private var isNew: Bool {
        !store.reminders.contains { $0.calendarItemIdentifier == reminder.calendarItemIdentifier }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                }
                Section {
                    Toggle("Due Date", isOn: $draft.hasDueDate)
                    if draft.hasDueDate {
                        Toggle("Include Time", isOn: $draft.includesTime)
                        DatePicker("Due", selection: $draft.dueDate,
                                   displayedComponents: draft.includesTime ? [.date, .hourAndMinute] : .date)
                        Picker("Repeat", selection: $draft.recurrence) {
                            ForEach(RecurrencePreset.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        if draft.recurrence == .custom {
                            Picker("Frequency", selection: $draft.customFrequency) {
                                Text("Daily").tag(EKRecurrenceFrequency.daily)
                                Text("Weekly").tag(EKRecurrenceFrequency.weekly)
                                Text("Monthly").tag(EKRecurrenceFrequency.monthly)
                                Text("Yearly").tag(EKRecurrenceFrequency.yearly)
                            }
                            Stepper("Every \(draft.customInterval)", value: $draft.customInterval, in: 1...99)
                        }
                    }
                }
                Section {
                    Picker("Priority", selection: $draft.priorityBucket) {
                        ForEach(TaskGrouping.Priority.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    Picker("List", selection: $draft.listID) {
                        ForEach(store.lists.filter(\.allowsContentModifications), id: \.calendarIdentifier) { list in
                            Text(list.title).tag(Optional(list.calendarIdentifier))
                        }
                    }
                }
                Section("Alarms") {
                    ForEach(Array(draft.alarms.enumerated()), id: \.offset) { index, alarm in
                        HStack {
                            DatePicker("Alarm", selection: Binding(
                                get: { alarm },
                                set: { if draft.alarms.indices.contains(index) { draft.alarms[index] = $0 } }
                            ))
                            Button("Remove Alarm", systemImage: "minus.circle.fill") { draft.alarms.remove(at: index) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Alarm") {
                        draft.alarms.append(draft.hasDueDate ? draft.dueDate : .now.addingTimeInterval(3600))
                    }
                }
                Section {
                    ForEach($subtasks) { $subtask in
                        HStack {
                            Button(subtask.title.isEmpty ? "Subtask" : subtask.title,
                                   systemImage: subtask.done ? "checkmark.circle.fill" : "circle") { subtask.done.toggle() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .accessibilityValue(subtask.done ? "Complete" : "Incomplete")
                            TextField("Subtask", text: $subtask.title)
                            Button("Remove Subtask", systemImage: "minus.circle.fill") {
                                subtasks.removeAll { $0.id == subtask.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        #if os(macOS)
                        .contextMenu {
                            let index = subtasks.firstIndex { $0.id == subtask.id } ?? 0
                            Button("Move Up") { subtasks.swapAt(index, index - 1) }
                                .disabled(index == 0)
                            Button("Move Down") { subtasks.swapAt(index, index + 1) }
                                .disabled(index == subtasks.count - 1)
                        }
                        #endif
                    }
                    .onDelete { subtasks.remove(atOffsets: $0) }
                    .onMove { subtasks.move(fromOffsets: $0, toOffset: $1) }
                    TextField("New Subtask", text: $newSubtask)
                        .onSubmit(addSubtask)
                } header: {
                    HStack {
                        Text("Subtasks")
                        #if os(iOS)
                        Spacer()
                        EditButton()
                        #endif
                    }
                }
                Section("Tags") {
                    ForEach(tagNames, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Remove Tag \(name)", systemImage: "minus.circle.fill") { tagNames.removeAll { $0 == name } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    TextField("Add Tag", text: $newTag)
                        .onSubmit {
                            addTag(newTag)
                            newTag = ""
                        }
                    let available = allTags.map(\.name).filter { !hasTag($0) }
                    if !available.isEmpty {
                        Menu("Existing Tags") {
                            ForEach(available, id: \.self) { name in Button(name) { addTag(name) } }
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete Task", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "New Task" : "Edit Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        addSubtask()
                        addTag(newTag)
                        newTag = ""
                        mutate {
                            draft.apply(to: reminder, lists: store.lists)
                            try store.save(reminder)
                            try TaskExtras.write(in: modelContext, reminderID: reminder.calendarItemIdentifier,
                                                 externalID: reminder.calendarItemExternalIdentifier,
                                                 subtasks: subtasks, tagNames: tagNames)
                        }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                guard !loadedExtras else { return }
                loadedExtras = true
                let extras = TaskExtras.match((try? modelContext.fetch(FetchDescriptor<TaskExtras>())) ?? [], id: reminder.calendarItemIdentifier,
                                              externalID: reminder.calendarItemExternalIdentifier)
                subtasks = extras?.subtasks ?? []
                tagNames = (extras?.tags ?? []).map(\.name).sorted()
            }
            .confirmationDialog("Delete this task?", isPresented: $confirmingDelete) {
                Button("Delete Task", role: .destructive) { mutate { try store.delete(reminder) } }
            }
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
    }

    private func hasTag(_ name: String) -> Bool {
        tagNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func addSubtask() {
        let title = newSubtask.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { subtasks.append(Subtask(title: title)) }
        newSubtask = ""
    }

    private func addTag(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && !hasTag(name) { tagNames.append(name) }
    }

    /// Runs the action and dismisses; on failure stays open with an alert.
    private func mutate(_ action: () throws -> Void) {
        do {
            try action()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
