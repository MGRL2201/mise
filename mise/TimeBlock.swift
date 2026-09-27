import Foundation
import SwiftData
@preconcurrency import EventKit

/// Time-blocking a task: a calendar event linked to the reminder via TaskExtras.eventID (SPEC §6.2).
enum TimeBlock {
    static let doneMark = "✓ "

    /// Event title for a task's time block: done adds the mark once, not done strips it.
    static func title(_ title: String, done: Bool) -> String {
        let bare = title.hasPrefix(doneMark) ? String(title.dropFirst(doneMark.count)) : title
        return done ? doneMark + bare : bare
    }
}

/// Creates an event for `reminder` and links it, or moves the already linked event
/// (and to `calendar` when given). The reminder must already be saved (its identifiers
/// are the link key). If linking a new event fails it is removed again.
@discardableResult
func createTimeBlock(for reminder: EKReminder, start: Date, duration: TimeInterval, calendar: EKCalendar?,
                     calendarStore: CalendarStore, context: ModelContext) throws -> EKEvent {
    let existing = TaskExtras.match(try context.fetch(FetchDescriptor<TaskExtras>()), id: reminder.calendarItemIdentifier,
                                    externalID: reminder.calendarItemExternalIdentifier)?.eventID
        .flatMap { calendarStore.eventStore.event(withIdentifier: $0) }
    let event: EKEvent
    if let existing {
        event = existing
        if let calendar { event.calendar = calendar }
    } else {
        event = calendarStore.newEvent(in: calendar)
        event.title = TimeBlock.title(reminder.title ?? "", done: reminder.isCompleted)
    }
    event.startDate = start
    event.endDate = start.addingTimeInterval(duration)
    try calendarStore.save(event)
    do {
        try TaskExtras.setEventID(event.eventIdentifier, in: context, reminderID: reminder.calendarItemIdentifier,
                                  externalID: reminder.calendarItemExternalIdentifier)
    } catch {
        if existing == nil { try? calendarStore.delete(event) }
        throw error
    }
    return event
}
