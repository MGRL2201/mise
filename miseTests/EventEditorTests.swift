import Testing
import Foundation
import EventKit
import CoreLocation
@testable import mise

@MainActor
struct EventEditorTests {
    private func date(_ day: Int, _ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2030, month: 1, day: day, hour: hour))!
    }

    private func event() -> EKEvent {
        let event = EKEvent(eventStore: EKEventStore())
        event.startDate = date(2, 9)
        event.endDate = date(2, 10)
        return event
    }

    @Test func applyTrimsTitle() {
        let event = event()
        var draft = EventDraft(event)
        draft.title = "  Dentist \n"
        draft.apply(to: event, calendars: [])
        #expect(event.title == "Dentist")
    }

    @Test func draftRoundTripsThroughEvent() {
        let event = event()
        var draft = EventDraft(event)
        draft.title = "Dentist"
        draft.location = "Main St 1"
        draft.startDate = date(3, 14)
        draft.endDate = date(3, 15)
        draft.recurrence = .custom
        draft.customFrequency = .monthly
        draft.customInterval = 3
        draft.repeatEnd = date(20, 0)
        draft.alerts = [0, 900]
        draft.url = "https://example.com/dentist"
        draft.notes = "bring card"
        draft.apply(to: event, calendars: [])

        #expect(EventDraft(event) == draft)

        // EventKit snaps all-day dates to the day and swaps in its default
        // all-day alarm; the draft's alerts must survive the toggle.
        draft.isAllDay = true
        draft.recurrence = .weekly
        draft.apply(to: event, calendars: [])
        let allDay = EventDraft(event)
        #expect(allDay.isAllDay && allDay.recurrence == .weekly)
        #expect(allDay.alerts == [0, 900])
        #expect(event.alarms?.count == 2)
    }

    @Test func untouchedFieldsSurviveApply() {
        let event = event()
        let monWed = EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.wednesday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
            end: EKRecurrenceEnd(occurrenceCount: 5))
        event.recurrenceRules = [monWed]
        event.alarms = [EKAlarm(relativeOffset: -600), EKAlarm(absoluteDate: date(1, 8))]

        var draft = EventDraft(event)
        draft.title = "Renamed"
        draft.apply(to: event, calendars: [])

        #expect(event.title == "Renamed")
        #expect(event.recurrenceRules?.first?.recurrenceEnd?.occurrenceCount == 5)
        #expect(event.recurrenceRules?.first?.daysOfTheWeek?.count == 2)
        #expect(event.alarms?.count == 2)
        #expect(event.location == nil && event.url == nil && event.notes == nil)
    }

    @Test func pickedPlaceRoundTrips() {
        let event = event()
        var draft = EventDraft(event)
        draft.location = "Apple Park"
        draft.latitude = 37.3349
        draft.longitude = -122.009
        draft.apply(to: event, calendars: [])

        #expect(event.location == "Apple Park")
        #expect(event.structuredLocation?.title == "Apple Park")
        #expect(event.structuredLocation?.geoLocation?.coordinate.latitude == 37.3349)
        #expect(event.structuredLocation?.geoLocation?.coordinate.longitude == -122.009)
        #expect(EventDraft(event) == draft)
    }

    @Test func removingPlaceClearsLocation() {
        let event = event()
        let place = EKStructuredLocation(title: "Apple Park")
        place.geoLocation = CLLocation(latitude: 37.3349, longitude: -122.009)
        event.structuredLocation = place
        var draft = EventDraft(event)
        #expect(draft.location == "Apple Park" && draft.latitude == 37.3349)
        draft.location = ""
        draft.latitude = nil
        draft.longitude = nil
        draft.apply(to: event, calendars: [])

        #expect(event.location == nil || event.location == "")
        #expect(event.structuredLocation?.geoLocation == nil)
    }

    @Test func unrelatedEditKeepsFreeTextLocation() {
        let event = event()
        event.location = "Room 4B, see Teams link"
        var draft = EventDraft(event)
        #expect(draft.location == "Room 4B, see Teams link" && draft.latitude == nil)
        draft.title = "Standup"
        draft.apply(to: event, calendars: [])

        #expect(event.location == "Room 4B, see Teams link")
        #expect(event.structuredLocation?.geoLocation == nil)
    }

    @Test func allDayToggleDropsDayRelativeAlarm() {
        let event = event()
        event.isAllDay = true
        event.alarms = [EKAlarm(relativeOffset: 32400), EKAlarm(absoluteDate: date(1, 8))]  // 9 AM on the day
        var draft = EventDraft(event)
        draft.isAllDay = false
        draft.startDate = date(2, 9)
        draft.endDate = date(2, 10)
        draft.apply(to: event, calendars: [])

        #expect(event.alarms?.contains { $0.absoluteDate == nil && $0.relativeOffset > 0 } == false)
        #expect(event.alarms?.contains { $0.absoluteDate == date(1, 8) } == true)
    }

    @Test func alertsRewriteKeepsAbsoluteAlarm() {
        let event = event()
        event.alarms = [EKAlarm(relativeOffset: -600), EKAlarm(absoluteDate: date(1, 8))]
        var draft = EventDraft(event)
        #expect(draft.alerts == [600])
        draft.alerts = [0, 3600]
        draft.apply(to: event, calendars: [])

        #expect(event.alarms?.count == 3)
        #expect(event.alarms?.contains { $0.absoluteDate == date(1, 8) } == true)
        #expect(EventDraft(event).alerts == [0, 3600])
    }

    @Test func endOnlyChangeKeepsCustomWeekdays() {
        let event = event()
        event.recurrenceRules = [EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1,
            daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.wednesday)],
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)]
        var draft = EventDraft(event)
        #expect(draft.recurrence == .custom)
        draft.repeatEnd = date(28, 0)
        draft.apply(to: event, calendars: [])

        let rule = event.recurrenceRules?.first
        #expect(rule?.daysOfTheWeek?.count == 2)
        #expect(rule?.recurrenceEnd?.endDate == date(28, 0))
    }

    @Test func noneClearsRecurrence() {
        let event = event()
        event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
        var draft = EventDraft(event)
        draft.recurrence = .none
        draft.apply(to: event, calendars: [])
        #expect((event.recurrenceRules ?? []).isEmpty)
    }

    @Test func setStartKeepsDuration() {
        var draft = EventDraft(event())
        draft.setStart(date(5, 13))
        #expect(draft.startDate == date(5, 13))
        #expect(draft.endDate == date(5, 14))
    }

    @Test func spanChoices() {
        #expect(EventDraft.spanChoices(recurring: false, seriesChanged: true) == [.thisEvent])
        #expect(EventDraft.spanChoices(recurring: true, seriesChanged: true) == [.futureEvents])
        #expect(EventDraft.spanChoices(recurring: true, seriesChanged: false) == [.thisEvent, .futureEvents])
    }

    @Test func seriesChangedDetectsRuleEndAndCalendarChanges() {
        let before = EventDraft(event())
        var draft = before
        draft.title = "x"
        #expect(!draft.seriesChanged(from: before))
        draft.recurrence = .daily
        #expect(draft.seriesChanged(from: before))
        draft = before
        draft.repeatEnd = date(9, 0)
        #expect(draft.seriesChanged(from: before))
        draft = before
        draft.calendarID = "other"
        #expect(draft.seriesChanged(from: before))
    }
}
