import SwiftUI
import SwiftData
@preconcurrency import EventKit
import UserNotifications

/// Daily "Plan your day" notification (#31). Tapping it opens PlanningView.
enum DailyPlanning {
    static let enabledKey = "planning.daily"
    static let timeKey = "planning.dailyTime"
    /// Minutes after midnight.
    static let defaultTime = 8 * 60
    nonisolated static let identifier = "daily-planning"
    private static var last: Task<Void, Never>?

    /// Hour and minute of a daily repeating trigger.
    static func components(minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60)
    }

    /// Schedules or removes the daily notification to match the settings. `prompt: false` never asks for permission.
    /// Serialized, so a run waiting on the permission prompt can't re-add a reminder a later run removed.
    static func sync(prompt: Bool) async {
        let prev = last
        let task = Task { await prev?.value; await apply(prompt: prompt) }
        last = task
        await task.value
    }

    private static func apply(prompt: Bool) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey), await LocalNotifications.authorized(prompt: prompt) else {
            return await LocalNotifications.replace(prefix: identifier, with: [])
        }
        let content = UNMutableNotificationContent()
        content.title = "Plan your day"
        content.body = "Pick today's tasks and block time for them."
        content.sound = .default
        let time = defaults.object(forKey: timeKey) as? Int ?? defaultTime
        let trigger = UNCalendarNotificationTrigger(dateMatching: components(minutes: time), repeats: true)
        await LocalNotifications.replace(prefix: identifier, with: [UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)])
    }

    /// Open, unblocked tasks that are overdue or due today (`week`: or in the next 7 days), overdue first, then earliest due.
    static func tasks(_ reminders: [EKReminder], week: Bool = false, now: Date, calendar: Calendar = .current,
                      isLinked: (EKReminder) -> Bool) -> [EKReminder] {
        reminders
            .filter { !$0.isCompleted && !isLinked($0)
                && TaskGrouping.dueBucket($0.dueDateComponents, now: now, calendar: calendar).map { week || $0 != .upcoming } == true }
            .compactMap { reminder in reminder.dueDateComponents.flatMap(calendar.date(from:)).map { (reminder, $0) } }
            .sorted { lhs, rhs in
                let lhsOverdue = TaskGrouping.dueBucket(lhs.0.dueDateComponents, now: now, calendar: calendar) == .overdue
                let rhsOverdue = TaskGrouping.dueBucket(rhs.0.dueDateComponents, now: now, calendar: calendar) == .overdue
                if lhsOverdue != rhsOverdue { return lhsOverdue }
                return lhs.1 < rhs.1
            }
            .map(\.0)
    }
}

/// Whether the planning sheet is showing; set by a notification tap, the Tasks toolbar, or a debug launch arg.
@Observable final class PlanningPrompt {
    static let shared = PlanningPrompt()
    var isPresented = false
    var isWeeklyReviewPresented = false
    /// The two sheets hang off one view, so only one may be requested at a time.
    func showDaily() { isWeeklyReviewPresented = false; isPresented = true }
    func showWeekly() { isPresented = false; isWeeklyReviewPresented = true }
}

/// Pick today's (or, with `week`, the next 7 days') tasks and block time for each from the free-slot suggestions.
struct PlanningView: View {
    var week = false
    @Environment(RemindersStore.self) private var reminders
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var extras: [TaskExtras]
    @State private var picked: Set<String> = []
    /// Blocked this session; kept listed although they are now linked.
    @State private var scheduled: [String: DateInterval] = [:]
    @State private var suggestions: [String: [DateInterval]] = [:]
    @State private var failed = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(week ? "Plan Your Week" : "Plan Your Day")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .themedBackground()
                .alert("Couldn't schedule this task.", isPresented: $failed) {}
                .task { await reminders.refresh() }  // opened from a notification before Tasks ever loaded
        }
    }

    @ViewBuilder private var content: some View {
        // Read so a deleted linked event (refresh replaces events) lists its task again.
        let _ = calendarStore.events
        let tasks = DailyPlanning.tasks(reminders.reminders, week: week, now: .now) { reminder in
            scheduled[reminder.calendarItemIdentifier] == nil && extra(reminder)?.eventID
                .flatMap { calendarStore.eventStore.event(withIdentifier: $0) } != nil
        }
        if !reminders.hasAccess {
            ContentUnavailableView("No Reminders Access", systemImage: "checklist",
                                   description: Text("Allow mise to access Reminders in Settings to plan your \(week ? "week" : "day")."))
        } else if tasks.isEmpty {
            ContentUnavailableView("Nothing to plan", systemImage: "checkmark.circle",
                                   description: Text(week ? "No overdue or due-this-week tasks without a time block."
                                                         : "No overdue or due-today tasks without a time block."))
        } else {
            List(tasks, id: \.calendarItemIdentifier, rowContent: row)
        }
    }

    private func row(_ reminder: EKReminder) -> some View {
        let id = reminder.calendarItemIdentifier
        let slot = scheduled[id]
        return VStack(alignment: .leading, spacing: 8) {
            Button { toggle(reminder) } label: {
                HStack {
                    Image(systemName: picked.contains(id) || slot != nil ? "checkmark.circle.fill" : "circle")
                    VStack(alignment: .leading) {
                        Text(reminder.title ?? "")
                        Self.due(reminder, week: week).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(slot != nil)
            if let slot {
                Label("Scheduled \(describe(slot))", systemImage: "checkmark").font(.subheadline).foregroundStyle(.secondary)
            } else if picked.contains(id) {
                if !calendarStore.hasAccess {
                    Text("Calendar access is off.").font(.subheadline).foregroundStyle(.secondary)
                } else if let slots = suggestions[id], let first = slots.first {
                    HStack {
                        Button("Schedule \(describe(first))") { accept(reminder, first) }
                            .buttonStyle(.borderedProminent)
                        if slots.count > 1 {
                            Menu("Other Times") {
                                ForEach(slots.dropFirst(), id: \.start) { other in
                                    Button(describe(other)) { accept(reminder, other) }
                                }
                            }
                            .fixedSize()
                        }
                    }
                } else {
                    Text("No free slot in your working hours in the next 7 days.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func due(_ reminder: EKReminder, week: Bool) -> Text {
        guard let components = reminder.dueDateComponents else { return Text("") }
        if TaskGrouping.dueBucket(components, now: .now, calendar: .current) == .overdue {
            return Text("Overdue").foregroundStyle(.red)
        }
        if week, let date = Calendar.current.date(from: components), !Calendar.current.isDateInToday(date) {
            let format: Date.FormatStyle = components.hour == nil ? .dateTime.weekday(.wide) : .dateTime.weekday(.abbreviated).hour().minute()
            return Text(date.formatted(format)).foregroundStyle(.secondary)
        }
        guard components.hour != nil, let date = Calendar.current.date(from: components) else {
            return Text("Today").foregroundStyle(.secondary)
        }
        return Text(date, style: .time).foregroundStyle(.secondary)
    }

    /// "10:00–10:30", with the weekday when not today.
    private func describe(_ slot: DateInterval) -> String {
        let day = Calendar.current.isDateInToday(slot.start) ? "" : slot.start.formatted(.dateTime.weekday(.abbreviated)) + " "
        return day + slot.start.formatted(date: .omitted, time: .shortened) + "–" + slot.end.formatted(date: .omitted, time: .shortened)
    }

    private func extra(_ reminder: EKReminder) -> TaskExtras? {
        TaskExtras.match(extras, id: reminder.calendarItemIdentifier, externalID: reminder.calendarItemExternalIdentifier)
    }

    /// The task's estimate, else the default block length (as when dropping on the timeline).
    private func duration(_ reminder: EKReminder) -> TimeInterval {
        let minutes = extra(reminder)?.estimateMinutes ?? 0
        return minutes > 0 ? TimeInterval(minutes * 60) : TimeBlock.defaultDuration
    }

    private func toggle(_ reminder: EKReminder) {
        let id = reminder.calendarItemIdentifier
        if picked.remove(id) == nil {
            picked.insert(id)
            suggest(reminder)
        }
    }

    private func suggest(_ reminder: EKReminder) {
        suggestions[reminder.calendarItemIdentifier] = calendarStore.hasAccess
            ? suggestFreeSlots(duration: duration(reminder), calendarStore: calendarStore, context: modelContext) : []
    }

    private func accept(_ reminder: EKReminder, _ slot: DateInterval) {
        guard (try? createTimeBlock(for: reminder, start: slot.start, duration: slot.duration, calendar: nil,
                                    calendarStore: calendarStore, context: modelContext)) != nil
        else { return failed = true }
        scheduled[reminder.calendarItemIdentifier] = slot
        // The new block is busy now, so the other picked tasks need fresh suggestions.
        for other in reminders.reminders where picked.contains(other.calendarItemIdentifier)
            && scheduled[other.calendarItemIdentifier] == nil {
            suggest(other)
        }
        Task { await calendarStore.refresh() }  // show the new block now
    }
}
