import Testing
import Foundation
import EventKit
@testable import mise

@MainActor
struct DayTimelineTests {
    let calendar = Calendar.current
    let store = EKEventStore()
    var dayStart: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))! }

    private func event(_ startHour: Double, _ endHour: Double, allDay: Bool = false) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.startDate = dayStart.addingTimeInterval(startHour * 3600)
        event.endDate = dayStart.addingTimeInterval(endHour * 3600)
        event.isAllDay = allDay
        return event
    }

    @Test func allDayCoversFlaggedAndWholeDaySpans() {
        #expect(event(0, 24, allDay: true).showsAllDay(on: dayStart, calendar: calendar))
        #expect(event(-30, 48).showsAllDay(on: dayStart, calendar: calendar))  // multi-day, covers whole day
        #expect(!event(9, 10).showsAllDay(on: dayStart, calendar: calendar))
        #expect(!event(-2, 3).showsAllDay(on: dayStart, calendar: calendar))  // crosses midnight: timed, clamped
    }

    @Test func splitDropsEventsOutsideTheDay() {
        let events = [event(0, 24, allDay: true), event(9, 10), event(-2, 3), event(25, 26), event(-5, -1)]
        let (allDay, timed) = DayColumn.split(events, day: dayStart, calendar: calendar)
        #expect(allDay.elementsEqual([events[0]], by: ===))
        #expect(timed.elementsEqual([events[1], events[2]], by: ===))
    }
}
