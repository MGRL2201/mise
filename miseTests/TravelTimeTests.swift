import Testing
import Foundation
import EventKit
import CoreLocation
@testable import mise

@MainActor
struct TravelTimeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func event(startsIn seconds: TimeInterval, allDay: Bool = false, geo: Bool = true) -> EKEvent {
        let event = EKEvent(eventStore: EKEventStore())
        event.startDate = now.addingTimeInterval(seconds)
        event.endDate = event.startDate.addingTimeInterval(3600)
        event.isAllDay = allDay
        if geo {
            let place = EKStructuredLocation(title: "Dentist")
            place.geoLocation = CLLocation(latitude: 52.5, longitude: 13.4)
            event.structuredLocation = place
        }
        return event
    }

    @Test func fireDateSubtractsETAAndBuffer() {
        let start = now.addingTimeInterval(7200)
        #expect(TravelTime.fireDate(start: start, eta: 1500, bufferMinutes: 10, now: now) == start.addingTimeInterval(-2100))
    }

    @Test func fireDateInThePastIsSkipped() {
        let start = now.addingTimeInterval(1200)
        #expect(TravelTime.fireDate(start: start, eta: 1500, bufferMinutes: 10, now: now) == nil)
    }

    @Test func candidatesKeepTimedEventsWithPlaceWithin24h() {
        let soon = event(startsIn: 3600)
        #expect(TravelTime.candidates([soon], now: now) == [soon])
    }

    @Test func candidatesSkipTooFarStartedAllDayAndNoPlace() {
        let events = [event(startsIn: 86_400 + 60), event(startsIn: -60), event(startsIn: 3600, allDay: true),
                      event(startsIn: 3600, geo: false)]
        #expect(TravelTime.candidates(events, now: now).isEmpty)
    }

    @Test func identifierIsPerOccurrence() {
        let event = event(startsIn: 3600)
        #expect(TravelTime.identifier(event) == "leave-now|" + event.rowID)
    }
}
