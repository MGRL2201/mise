import SwiftUI
import SwiftData
@preconcurrency import EventKit
import CoreLocation

// ponytail: custom = frequency + "every N" only; specific weekdays and occurrence-count ends aren't editable yet
// (existing ones survive untouched). End dates are editable via TaskDraft.repeatEnd.
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
        return a.frequency == b.frequency && a.interval == b.interval && (b.recurrenceEnd?.occurrenceCount ?? 0) == 0
            && days(a) == days(b) && extras(b)
    }
}

/// A geofence alarm: notify on arriving at (or leaving) a place.
struct LocationReminder: Equatable {
    var title: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var leaving: Bool
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
    var repeatEnd: Date?
    var url = ""
    /// Seconds before due (positive).
    var earlyReminder: TimeInterval?
    var location: LocationReminder?

    static let earlyReminderOptions: [TimeInterval] = [300, 900, 1800, 3600, 7200, 86400, 2 * 86400, 7 * 86400, 30 * 86400]

    private static func isEarly(_ alarm: EKAlarm) -> Bool {
        alarm.absoluteDate == nil && alarm.proximity == .none && alarm.relativeOffset < 0
    }

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
        repeatEnd = rule?.recurrenceEnd?.endDate
        url = reminder.url?.absoluteString ?? ""
        let alarms = reminder.alarms ?? []
        earlyReminder = alarms.first(where: Self.isEarly).map { -$0.relativeOffset }
        if let alarm = alarms.first(where: { $0.structuredLocation != nil && $0.proximity != .none }),
           let place = alarm.structuredLocation {
            location = LocationReminder(
                title: place.title ?? "", latitude: place.geoLocation?.coordinate.latitude ?? 0,
                longitude: place.geoLocation?.coordinate.longitude ?? 0, radius: place.radius, leaving: alarm.proximity == .leave)
        }
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
            // Timed dues notify at the due time like Reminders.app: drop the old due's alarm, keep others.
            let oldDue = before.hasDueDate && before.includesTime ? before.dueDate : nil
            reminder.alarms = (reminder.alarms ?? []).filter { alarm in
                if let date = alarm.absoluteDate { return date != oldDue }
                // Early reminders need a timed due; on a date-only due they'd fire relative to midnight.
                if !(hasDueDate && includesTime) && Self.isEarly(alarm) { return false }
                return alarm.proximity != .none || alarm.relativeOffset != 0
            } + (hasDueDate && includesTime ? [EKAlarm(relativeOffset: 0)] : [])
        }
        if hasDueDate {
            // Only rewrite recurrence the user changed, so rules we can't represent survive.
            let ruleChanged = recurrence != before.recurrence
                || (recurrence == .custom && (customFrequency, customInterval) != (before.customFrequency, before.customInterval))
            if ruleChanged {
                let rule = recurrence == .custom
                    ? EKRecurrenceRule(recurrenceWith: customFrequency, interval: customInterval, end: nil)
                    : recurrence.rule
                rule?.recurrenceEnd = repeatEnd.map { EKRecurrenceEnd(end: $0) }
                reminder.recurrenceRules = rule.map { [$0] }
            } else if repeatEnd != before.repeatEnd, let rule = reminder.recurrenceRules?.first {
                rule.recurrenceEnd = repeatEnd.map { EKRecurrenceEnd(end: $0) }  // end-only edit keeps weekdays etc.
                reminder.recurrenceRules = [rule]
            }
        } else {
            reminder.recurrenceRules = nil  // EventKit requires a due date for recurrence
        }
        if url != before.url {
            reminder.url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if earlyReminder != before.earlyReminder {
            reminder.alarms = (reminder.alarms ?? []).filter { !Self.isEarly($0) }
                + (hasDueDate && includesTime ? earlyReminder.map { [EKAlarm(relativeOffset: -$0)] } ?? [] : [])
        }
        if location != before.location {
            let old = (reminder.alarms ?? []).first { $0.structuredLocation != nil && $0.proximity != .none }
            reminder.alarms = (reminder.alarms ?? []).filter { $0.proximity == .none }
                + (location.map { location in
                    var place = EKStructuredLocation(title: location.title)
                    place.geoLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
                    // Same place: copy the original (it may lack geoLocation, which reads as 0,0).
                    if let b = before.location, (b.title, b.latitude, b.longitude) == (location.title, location.latitude, location.longitude),
                       let copy = old?.structuredLocation?.copy() as? EKStructuredLocation {
                        place = copy
                    }
                    place.radius = location.radius
                    let alarm = EKAlarm()
                    alarm.structuredLocation = place
                    alarm.proximity = location.leaving ? .leave : .enter
                    return [alarm]
                } ?? [])
        }
    }
}

struct TaskEditor: View {
    let reminder: EKReminder
    @Environment(RemindersStore.self) private var store
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var draft: TaskDraft
    @State private var subtasks: [Subtask] = []
    @State private var tagNames: [String] = []
    @State private var newSubtask = ""
    @State private var newTag = ""
    @State private var loadedExtras = false
    @State private var flagged = false
    @State private var loadedFlagged = false
    @State private var loadedSubtasks: [Subtask] = []
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var timeBlocked = false
    @State private var blockStart = Date()
    @State private var blockMinutes = 30
    @State private var blockCalendarID: String?
    @State private var loadedBlock: (start: Date, minutes: Int, calendarID: String?)?

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
                    TextField("URL", text: $draft.url)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }
                Section {
                    Toggle(isOn: Binding(get: { draft.hasDueDate }, set: {
                        draft.hasDueDate = $0
                        if !$0 { draft.includesTime = false }
                    })) { Label("Date", systemImage: "calendar") }
                    if draft.hasDueDate {
                        DatePicker("Date", selection: $draft.dueDate, displayedComponents: .date)
                    }
                    Toggle(isOn: Binding(get: { draft.hasDueDate && draft.includesTime }, set: {
                        let wasDated = draft.hasDueDate
                        draft.includesTime = $0
                        if $0 {
                            draft.hasDueDate = true
                            let calendar = Calendar.current
                            let comps = calendar.dateComponents([.hour, .minute], from: draft.dueDate)
                            if !wasDated || comps.hour == 0 && comps.minute == 0 {
                                let isToday = calendar.isDateInToday(draft.dueDate)
                                let hour = isToday ? calendar.component(.hour, from: .now) + 1 : 9
                                draft.dueDate = calendar.date(bySettingHour: min(hour, 23), minute: 0, second: 0, of: draft.dueDate) ?? draft.dueDate
                            }
                        }
                    })) { Label("Time", systemImage: "clock") }
                    if draft.hasDueDate && draft.includesTime {
                        DatePicker("Time", selection: $draft.dueDate, displayedComponents: .hourAndMinute)
                    }
                    if draft.hasDueDate {
                        Picker(selection: $draft.recurrence) {
                            ForEach(RecurrencePreset.allCases, id: \.self) { Text($0.rawValue) }
                        } label: { Label("Repeat", systemImage: "repeat") }
                        if draft.recurrence == .custom {
                            Picker("Frequency", selection: $draft.customFrequency) {
                                Text("Daily").tag(EKRecurrenceFrequency.daily)
                                Text("Weekly").tag(EKRecurrenceFrequency.weekly)
                                Text("Monthly").tag(EKRecurrenceFrequency.monthly)
                                Text("Yearly").tag(EKRecurrenceFrequency.yearly)
                            }
                            Stepper("Every \(draft.customInterval)", value: $draft.customInterval, in: 1...99)
                        }
                        if draft.recurrence != .none {
                            Picker("End Repeat", selection: Binding(get: { draft.repeatEnd != nil }, set: {
                                draft.repeatEnd = $0 ? Calendar.current.date(byAdding: .month, value: 1, to: draft.dueDate) : nil
                            })) {
                                Text("Never").tag(false)
                                Text("On Date").tag(true)
                            }
                            if let end = draft.repeatEnd {
                                DatePicker("End Date", selection: Binding(get: { end }, set: { draft.repeatEnd = $0 }),
                                           in: draft.dueDate..., displayedComponents: .date)
                            }
                        }
                    }
                    if draft.hasDueDate && draft.includesTime {
                        Picker(selection: $draft.earlyReminder) {
                            Text("None").tag(TimeInterval?.none)
                            let options = TaskDraft.earlyReminderOptions
                            ForEach(options + (draft.earlyReminder.map { options.contains($0) ? [] : [$0] } ?? []), id: \.self) { seconds in
                                Text(Self.earlyLabel(seconds)).tag(Optional(seconds))
                            }
                        } label: { Label("Early Reminder", systemImage: "bell") }
                    }
                }
                Section("Time Block") {
                    if calendarStore.hasAccess {
                        Toggle("Time Block", isOn: $timeBlocked)
                        if timeBlocked {
                            DatePicker("Start", selection: $blockStart, displayedComponents: [.date, .hourAndMinute])
                            Stepper("Duration: \(Duration.seconds(blockMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))",
                                    value: $blockMinutes, in: 15...720, step: 15)
                            Picker("Calendar", selection: $blockCalendarID) {
                                Text("Default").tag(String?.none)
                                ForEach(calendarStore.calendars.filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                                    Text(calendar.title).tag(Optional(calendar.calendarIdentifier))
                                }
                            }
                        }
                    } else if calendarStore.status == .notDetermined {
                        Button("Allow Calendar Access") { Task { await calendarStore.requestAccess() } }
                    } else {
                        Text("Calendar access is off. Turn it on in Settings to time-block tasks.")
                            .foregroundStyle(.secondary)
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
                Section {
                    NavigationLink {
                        LocationSearchView(location: $draft.location)
                    } label: {
                        LabeledContent {
                            Text(draft.location?.title ?? "None")
                        } label: { Label("Location", systemImage: "location") }
                    }
                    if let location = draft.location {
                        Picker("Location", selection: Binding(get: { location.leaving }, set: { draft.location?.leaving = $0 })) {
                            Text("Arriving").tag(false)
                            Text("Leaving").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Button("Remove Location", role: .destructive) { draft.location = nil }
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle(isOn: $flagged) {
                        Label { Text("Flag") } icon: { Image(systemName: "flag.fill").foregroundStyle(.orange) }
                    }
                    .tint(.orange)
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
                if !isNew {
                    Section {
                        Button("Delete Task", role: .destructive) { confirmingDelete = true }
                            .foregroundStyle(.red)
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
                                                 subtasks: subtasks, tagNames: tagNames,
                                                 flagged: flagged != loadedFlagged ? flagged : nil, base: loadedSubtasks)
                            if timeBlocked {
                                if loadedBlock.map({ ($0.start, $0.minutes, $0.calendarID) != (blockStart, blockMinutes, blockCalendarID) }) ?? true {
                                    try createTimeBlock(for: reminder, start: blockStart, duration: TimeInterval(blockMinutes * 60),
                                                        calendar: calendarStore.calendars.first { $0.calendarIdentifier == blockCalendarID },
                                                        calendarStore: calendarStore, context: modelContext)
                                }
                            } else if loadedBlock != nil {
                                try store.removeTimeBlock(for: reminder)
                            }
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
                loadedSubtasks = subtasks
                flagged = extras?.flagged ?? false
                loadedFlagged = flagged
                tagNames = (extras?.tags ?? []).map(\.name).sorted()
                if let event = store.linkedEvent(for: reminder) {
                    timeBlocked = true
                    blockStart = event.startDate
                    blockMinutes = min(720, max(15, Int(event.endDate.timeIntervalSince(event.startDate) / 60)))
                    // Read-only calendar isn't a Picker option; show Default (nil keeps the event where it is on save).
                    blockCalendarID = event.calendar.flatMap { $0.allowsContentModifications ? $0.calendarIdentifier : nil }
                    loadedBlock = (blockStart, blockMinutes, blockCalendarID)
                } else {
                    blockStart = draft.hasDueDate && draft.includesTime ? draft.dueDate
                        : Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
                    blockCalendarID = calendarStore.defaultCalendar?.calendarIdentifier
                }
            }
            .task {
                if calendarStore.hasAccess && calendarStore.calendars.isEmpty { await calendarStore.refresh() }
            }
            .confirmationDialog("Delete this task?", isPresented: $confirmingDelete) {
                if loadedBlock != nil {
                    Button("Delete Task and Event", role: .destructive) { mutate { try store.delete(reminder, deletingEvent: true) } }
                    Button("Delete Task Only", role: .destructive) { mutate { try store.delete(reminder) } }
                } else {
                    Button("Delete Task", role: .destructive) { mutate { try store.delete(reminder) } }
                }
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

    static func earlyLabel(_ seconds: TimeInterval) -> String {
        seconds == 30 * 86400 ? "1 month before"
            : Duration.seconds(seconds).formatted(.units(allowed: [.weeks, .days, .hours, .minutes], width: .wide)) + " before"
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
