import SwiftUI
@preconcurrency import EventKit

/// Plain editable copy of an event; nothing touches EventKit until `apply`.
struct EventDraft: Equatable {
    var title = ""
    var location = ""
    var isAllDay = false
    var startDate = Date()
    var endDate = Date()
    var calendarID: String?
    var recurrence = RecurrencePreset.none
    var customFrequency = EKRecurrenceFrequency.daily
    var customInterval = 1
    var repeatEnd: Date?
    /// Seconds before start (>= 0), at most two, smallest first.
    var alerts: [TimeInterval] = []
    var url = ""
    var notes = ""

    private static func isAlert(_ alarm: EKAlarm) -> Bool {
        alarm.absoluteDate == nil && alarm.proximity == .none && alarm.relativeOffset <= 0
    }

    init(_ event: EKEvent) {
        title = event.title ?? ""
        location = event.location ?? ""
        isAllDay = event.isAllDay
        startDate = event.startDate ?? Date()
        endDate = event.endDate ?? startDate
        calendarID = event.calendar?.calendarIdentifier
        let rule = event.recurrenceRules?.first
        recurrence = RecurrencePreset(rule)
        if recurrence == .custom, let rule {
            customFrequency = rule.frequency
            customInterval = rule.interval
        }
        repeatEnd = rule?.recurrenceEnd?.endDate
        // Sorted: event.alarms order isn't stable across reads.
        // ponytail: 2-alert limit, a 3rd+ relative alert is dropped once alerts are edited; lift the cap if anyone uses more.
        alerts = Array((event.alarms ?? []).filter(Self.isAlert).map { -$0.relativeOffset }.sorted().prefix(2))
        url = event.url?.absoluteString ?? ""
        notes = event.notes ?? ""
    }

    /// Moving the start keeps the duration, like Calendar.app.
    mutating func setStart(_ date: Date) {
        endDate = date.addingTimeInterval(endDate.timeIntervalSince(startDate))
        startDate = date
    }

    /// Repeat or calendar changed: both only make sense for the series.
    func seriesChanged(from before: EventDraft) -> Bool {
        ruleChanged(from: before) || repeatEnd != before.repeatEnd || calendarID != before.calendarID
    }

    private func ruleChanged(from before: EventDraft) -> Bool {
        recurrence != before.recurrence
            || (recurrence == .custom && (customFrequency, customInterval) != (before.customFrequency, before.customInterval))
    }

    /// Spans the save prompt offers; one choice means save without asking.
    /// A changed repeat or calendar can't apply to a single occurrence (Calendar.app agrees).
    static func spanChoices(recurring: Bool, seriesChanged: Bool) -> [EKSpan] {
        if !recurring { return [.thisEvent] }
        return seriesChanged ? [.futureEvents] : [.thisEvent, .futureEvents]
    }

    /// Only rewrites what changed, so fields we can't represent survive.
    func apply(to event: EKEvent, calendars: [EKCalendar]) {
        let before = EventDraft(event)
        // Copies: toggling isAllDay rewrites alarms in place to EventKit's default.
        let alarms = (event.alarms ?? []).map { $0.copy() as! EKAlarm }
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = notes.isEmpty ? nil : notes
        event.location = location.isEmpty ? nil : location
        if isAllDay != before.isAllDay { event.isAllDay = isAllDay }
        if startDate != before.startDate { event.startDate = startDate }
        if endDate != before.endDate { event.endDate = endDate }
        if calendarID != before.calendarID,
           let calendar = calendars.first(where: { $0.calendarIdentifier == calendarID }), calendar.allowsContentModifications {
            event.calendar = calendar
        }
        if ruleChanged(from: before) {
            let rule = recurrence == .custom
                ? EKRecurrenceRule(recurrenceWith: customFrequency, interval: customInterval, end: nil)
                : recurrence.rule
            rule?.recurrenceEnd = repeatEnd.map { EKRecurrenceEnd(end: $0) }
            event.recurrenceRules = rule.map { [$0] }
        } else if repeatEnd != before.repeatEnd, let rule = event.recurrenceRules?.first {
            rule.recurrenceEnd = repeatEnd.map { EKRecurrenceEnd(end: $0) }  // end-only edit keeps weekdays etc.
            event.recurrenceRules = [rule]
        }
        if url != before.url {
            event.url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if alerts != before.alerts || isAllDay != before.isAllDay {
            // Relative offsets mean different things all-day vs timed (+9h = 9 AM on the day),
            // so a toggle keeps only absolute and location alarms.
            let keep: (EKAlarm) -> Bool = isAllDay != before.isAllDay
                ? { $0.absoluteDate != nil || $0.proximity != .none }
                : { !Self.isAlert($0) }
            event.alarms = alarms.filter(keep) + alerts.map { EKAlarm(relativeOffset: -$0) }
        }
    }
}

/// New/edit event sheet, laid out like Calendar.app's.
struct EventEditor: View {
    let event: EKEvent
    /// Set when opened from EventDetailView: Cancel/Save go back to the details instead of closing the sheet.
    var onClose: (() -> Void)?
    @Environment(CalendarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft
    @State private var spanChoices: [EKSpan] = []
    @State private var confirmingDelete = false
    @State private var errorMessage: String?
    private let isNew: Bool

    init(event: EKEvent, onClose: (() -> Void)? = nil) {
        self.event = event
        self.onClose = onClose
        _draft = State(initialValue: EventDraft(event))
        isNew = event.eventIdentifier?.isEmpty ?? true
    }

    var body: some View {
        let dateParts: DatePickerComponents = draft.isAllDay ? .date : [.date, .hourAndMinute]
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title)
                    TextField("Location", text: $draft.location)
                }
                Section {
                    // Offsets mean different things all-day vs timed, so a flip clears alerts (Calendar.app does too).
                    Toggle("All-day", isOn: Binding(get: { draft.isAllDay }, set: {
                        draft.isAllDay = $0
                        draft.alerts = []
                    }))
                    DatePicker("Starts", selection: Binding(get: { draft.startDate }, set: { draft.setStart($0) }),
                               displayedComponents: dateParts)
                    DatePicker("Ends", selection: $draft.endDate, in: draft.startDate..., displayedComponents: dateParts)
                }
                Section {
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
                    if draft.recurrence != .none {
                        Picker("End Repeat", selection: Binding(get: { draft.repeatEnd != nil }, set: {
                            draft.repeatEnd = $0 ? Calendar.current.date(byAdding: .month, value: 1, to: draft.startDate) : nil
                        })) {
                            Text("Never").tag(false)
                            Text("On Date").tag(true)
                        }
                        if let end = draft.repeatEnd {
                            DatePicker("End Date", selection: Binding(get: { end }, set: { draft.repeatEnd = $0 }),
                                       in: draft.startDate..., displayedComponents: .date)
                        }
                    }
                }
                Section {
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(store.calendars.filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                            HStack {
                                Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 10, height: 10)
                                Text(calendar.title)
                            }
                            .tag(Optional(calendar.calendarIdentifier))
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.navigationLink)  // menus drop the color dots
                    #endif
                }
                Section {
                    alertPicker("Alert", 0)
                    if !draft.alerts.isEmpty { alertPicker("Second Alert", 1) }
                }
                Section {
                    TextField("URL", text: $draft.url)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                }
                if !isNew {
                    Section {
                        Button("Delete Event", role: .destructive) { confirmingDelete = true }
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "New Event" : "Edit Event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        // Read before apply: a new repeat rule doesn't make this a prompt-worthy series yet.
                        let choices = EventDraft.spanChoices(recurring: event.hasRecurrenceRules,
                                                             seriesChanged: draft.seriesChanged(from: EventDraft(event)))
                        if choices == [.thisEvent] { save(.thisEvent) } else { spanChoices = choices }
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("This is a repeating event.",
                                isPresented: Binding(get: { !spanChoices.isEmpty }, set: { if !$0 { spanChoices = [] } }),
                                titleVisibility: .visible) {
                ForEach(spanChoices, id: \.rawValue) { span in
                    Button(span == .thisEvent ? "Save for This Event Only" : "Save for Future Events") { save(span) }
                }
            }
            .confirmationDialog(event.hasRecurrenceRules ? "This is a repeating event." : "Delete this event?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                if event.hasRecurrenceRules {
                    Button("Delete This Event Only", role: .destructive) { delete(.thisEvent) }
                    Button("Delete All Future Events", role: .destructive) { delete(.futureEvents) }
                } else {
                    Button("Delete Event", role: .destructive) { delete(.thisEvent) }
                }
            }
            .alert(
                "Couldn't save event",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                presenting: errorMessage
            ) { _ in
                Button("OK") { errorMessage = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    /// Alert slot `index`; lists the current value even when it isn't a standard option, so opening the editor keeps it.
    private func alertPicker(_ title: String, _ index: Int) -> some View {
        let value = Binding<TimeInterval?>(
            get: { draft.alerts.indices.contains(index) ? draft.alerts[index] : nil },
            set: { new in
                if let new {
                    if draft.alerts.indices.contains(index) { draft.alerts[index] = new } else { draft.alerts.append(new) }
                } else if draft.alerts.indices.contains(index) {
                    draft.alerts.remove(at: index)
                }
            }
        )
        let options = [0] + TaskDraft.earlyReminderOptions
        // ponytail: timed-style options for all-day events too; Calendar.app's "(9 AM)" all-day presets if asked.
        return Picker(title, selection: value) {
            Text("None").tag(TimeInterval?.none)
            ForEach(options + (value.wrappedValue.map { options.contains($0) ? [] : [$0] } ?? []), id: \.self) { seconds in
                Text(seconds == 0 ? "At time of event" : TaskEditor.earlyLabel(seconds)).tag(Optional(seconds))
            }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func save(_ span: EKSpan) {
        mutate(then: close) {
            draft.apply(to: event, calendars: store.calendars)
            try store.save(event, span: span)  // rolls the event back on failure
        }
    }

    private func delete(_ span: EKSpan) {
        mutate(then: { dismiss() }) { try store.delete(event, span: span) }
    }

    /// Runs the action, then `then`; on failure stays open with an alert.
    private func mutate(then: () -> Void, _ action: () throws -> Void) {
        do {
            try action()
            then()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
