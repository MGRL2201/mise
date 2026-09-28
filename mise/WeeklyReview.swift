import SwiftUI
@preconcurrency import EventKit
import UserNotifications

/// Weekly "Review your week" notification (#32). Tapping it opens WeeklyReviewView.
enum WeeklyReview {
    static let enabledKey = "planning.weekly"
    /// Calendar weekday, 1 = Sunday.
    static let dayKey = "planning.weeklyDay"
    static let defaultDay = 1
    /// Minutes after midnight.
    static let timeKey = "planning.weeklyTime"
    static let defaultTime = 18 * 60
    nonisolated static let identifier = "weekly-review"
    private static var last: Task<Void, Never>?

    /// Weekday, hour and minute of a weekly repeating trigger.
    static func components(weekday: Int, minutes: Int) -> DateComponents {
        DateComponents(hour: minutes / 60, minute: minutes % 60, weekday: weekday)
    }

    /// Schedules or removes the weekly notification to match the settings. `prompt: false` never asks for permission.
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
        content.title = "Weekly review"
        content.body = "See last week and plan the next one."
        content.sound = .default
        let day = defaults.object(forKey: dayKey) as? Int ?? defaultDay
        let time = defaults.object(forKey: timeKey) as? Int ?? defaultTime
        let trigger = UNCalendarNotificationTrigger(dateMatching: components(weekday: day, minutes: time), repeats: true)
        await LocalNotifications.replace(prefix: identifier, with: [UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)])
    }

    /// Busy time per calendar inside `window`; overlapping or touching intervals in one calendar count once.
    static func hoursByCalendar(_ items: [(calendarID: String, interval: DateInterval)],
                                within window: DateInterval) -> [String: TimeInterval] {
        let clipped = items.compactMap { item in
            window.intersection(with: item.interval).flatMap { $0.duration > 0 ? (item.calendarID, $0) : nil }
        }
        return Dictionary(grouping: clipped, by: \.0).mapValues { spans in
            var total: TimeInterval = 0
            var current: DateInterval?
            for span in spans.map(\.1).sorted(by: { $0.start < $1.start }) {
                if let merged = current, span.start <= merged.end {
                    current = DateInterval(start: merged.start, end: max(merged.end, span.end))
                } else {
                    total += current?.duration ?? 0
                    current = span
                }
            }
            return total + (current?.duration ?? 0)
        }
    }
}

/// The last 7 days (completed tasks, time per calendar) and the next 7 days' open tasks.
struct WeeklyReviewView: View {
    @Environment(RemindersStore.self) private var reminders
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(\.dismiss) private var dismiss
    @State private var planning = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Weekly Review")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .themedBackground()
                .sheet(isPresented: $planning) { PlanningView(week: true) }
                .task { await reminders.refresh() }  // opened from a notification before Tasks ever loaded
        }
    }

    private var content: some View {
        let _ = calendarStore.events  // re-render on EKEventStoreChanged refresh
        let now = Date.now
        let window = DateInterval(start: Calendar.current.date(byAdding: .day, value: -7, to: now)!, end: now)
        let completed = reminders.reminders
            .filter { $0.isCompleted && $0.completionDate.map(window.contains) == true }
            .sorted { $0.completionDate! > $1.completionDate! }
        let upcoming = DailyPlanning.tasks(reminders.reminders, week: true, now: now) { _ in false }
        return List {
            Section {
                if !reminders.hasAccess {
                    Text("No Reminders access.").foregroundStyle(.secondary)
                } else {
                    ForEach(completed, id: \.calendarItemIdentifier) { Text($0.title ?? "") }
                }
            } header: {
                Text("Completed")
            } footer: {
                if reminders.hasAccess { Text("^[\(completed.count) task](inflect: true) completed") }
            }

            Section("Time by calendar") { timeByCalendar(window) }

            // Spend: add a Section here with the week's spending once Finance lands (SPEC §6.4).

            Section("Next 7 days") {
                if !reminders.hasAccess {
                    Text("No Reminders access.").foregroundStyle(.secondary)
                } else if upcoming.isEmpty {
                    Text("Nothing due.").foregroundStyle(.secondary)
                } else {
                    ForEach(upcoming, id: \.calendarItemIdentifier) { reminder in
                        LabeledContent(reminder.title ?? "") { PlanningView.due(reminder, week: true) }
                    }
                }
                Button("Plan Next Week", systemImage: "calendar.badge.plus") { planning = true }
                    .disabled(!reminders.hasAccess)
            }
        }
    }

    @ViewBuilder private func timeByCalendar(_ window: DateInterval) -> some View {
        let events = calendarStore.hasAccess ? calendarStore.events(in: window).filter { !$0.isAllDay && $0.calendar != nil } : []
        let calendars = Dictionary(events.map { ($0.calendar.calendarIdentifier, $0.calendar!) }) { first, _ in first }
        let hours = WeeklyReview.hoursByCalendar(
            events.map { (calendarID: $0.calendar.calendarIdentifier, interval: DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate))) },
            within: window
        ).sorted { $0.value > $1.value }
        if !calendarStore.hasAccess {
            Text("No Calendar access.").foregroundStyle(.secondary)
        } else if hours.isEmpty {
            Text("No timed events.").foregroundStyle(.secondary)
        } else {
            ForEach(hours, id: \.key) { id, seconds in
                LabeledContent {
                    Text((seconds / 3600).formatted(.number.precision(.fractionLength(0...1))) + " h")
                } label: {
                    Label {
                        Text(calendars[id]?.title ?? "")
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(calendarStore.color(for: calendars[id]))
                    }
                }
            }
        }
    }
}
