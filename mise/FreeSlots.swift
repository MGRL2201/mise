import Foundation
import SwiftData
@preconcurrency import EventKit

/// When the user works, for free-slot suggestions (SPEC §6.3). Minutes after midnight; Calendar weekdays (1 = Sunday).
struct WorkingHours: Equatable {
    static let startKey = "planning.workStart"
    static let endKey = "planning.workEnd"
    /// Weekday digits, e.g. "23456" = Mon–Fri.
    static let daysKey = "planning.workDays"
    static let standard = WorkingHours(start: 9 * 60, end: 18 * 60, weekdays: Set(2...6))

    var start: Int
    var end: Int
    var weekdays: Set<Int>

    static var current: WorkingHours {
        let defaults = UserDefaults.standard
        return WorkingHours(start: defaults.object(forKey: startKey) as? Int ?? standard.start,
                            end: defaults.object(forKey: endKey) as? Int ?? standard.end,
                            weekdays: defaults.string(forKey: daysKey).map(weekdays(from:)) ?? standard.weekdays)
    }

    static func weekdays(from digits: String) -> Set<Int> { Set(digits.compactMap(\.wholeNumberValue)) }
}

enum FreeSlots {
    /// Earliest `limit` slots of `duration` inside working hours over `days` days from today, one per free gap,
    /// starting no earlier than `now` rounded up to the quarter hour.
    static func find(busy: [DateInterval], hours: WorkingHours, duration: TimeInterval, now: Date,
                     days: Int = 7, limit: Int = 3, calendar: Calendar = .current) -> [DateInterval] {
        guard duration > 0, hours.end > hours.start else { return [] }
        // Absolute quarter hours are local quarter hours: every time zone offset is a multiple of 15 minutes.
        let quarter: TimeInterval = 15 * 60
        let earliest = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / quarter).rounded(.up) * quarter)
        var merged: [DateInterval] = []
        for interval in busy.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        var slots: [DateInterval] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<max(days, 0) where slots.count < limit {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  hours.weekdays.contains(calendar.component(.weekday, from: day)),
                  let open = calendar.date(bySettingHour: hours.start / 60, minute: hours.start % 60, second: 0, of: day),
                  let close = calendar.date(bySettingHour: hours.end / 60, minute: hours.end % 60, second: 0, of: day)
            else { continue }
            var cursor = max(open, earliest)
            for interval in merged where interval.end > cursor && interval.start < close {
                if interval.start.timeIntervalSince(cursor) >= duration { slots.append(DateInterval(start: cursor, duration: duration)) }
                cursor = interval.end
            }
            if close.timeIntervalSince(cursor) >= duration { slots.append(DateInterval(start: cursor, duration: duration)) }
        }
        return Array(slots.prefix(limit))
    }
}

/// Free slots around the user's events (all-day and "free" ones don't block) and task time blocks,
/// which count even in hidden calendars. `excludingEventID` is the task's own block when rescheduling.
func suggestFreeSlots(duration: TimeInterval, calendarStore: CalendarStore, context: ModelContext,
                      excludingEventID: String? = nil, now: Date = .now, days: Int = 7) -> [DateInterval] {
    let start = Calendar.current.startOfDay(for: now)
    let window = DateInterval(start: start, end: Calendar.current.date(byAdding: .day, value: days, to: start) ?? start)
    let blocks = ((try? context.fetch(FetchDescriptor<TaskExtras>())) ?? []).compactMap(\.eventID)
        .compactMap(calendarStore.eventStore.event(withIdentifier:))
    // Duplicates (a block that is also a visible event) merge away in FreeSlots.find.
    let busy = (calendarStore.events(in: window) + blocks).filter {
        !$0.isAllDay && $0.availability != .free && $0.eventIdentifier != excludingEventID
    }
    return FreeSlots.find(busy: busy.map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) },
                          hours: .current, duration: duration, now: now, days: days)
}
