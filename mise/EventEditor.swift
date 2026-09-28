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
        event.title = title
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
