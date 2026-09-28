import Testing
import Foundation
import SwiftUI
import EventKit
@testable import mise

@MainActor
struct CalendarSettingsTests {
    private let eventStore = EKEventStore()

    private func calendar(_ title: String) -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = title
        return calendar
    }

    @Test func visibleDropsHiddenCalendars() {
        let a = calendar("A"), b = calendar("B")
        #expect(CalendarStore.visible([a, b], hidden: [b.calendarIdentifier]) == [a])
        #expect(CalendarStore.visible([a, b], hidden: [a.calendarIdentifier, b.calendarIdentifier]).isEmpty)
    }

    @Test func defaultCalendarFallsBackToSystemDefault() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let system = eventStore.defaultCalendarForNewEvents?.calendarIdentifier

        let absent = CalendarStore(eventStore: eventStore, defaults: defaults)
        #expect(absent.defaultCalendar?.calendarIdentifier == system)

        defaults.set("bogus-id", forKey: "calendar.default")
        let stale = CalendarStore(eventStore: eventStore, defaults: defaults)
        #expect(stale.defaultCalendar?.calendarIdentifier == system)
    }

    @Test func settingsPersistAcrossStores() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let a = calendar("A")
        let red = Color.Resolved(red: 1, green: 0, blue: 0)
        let first = CalendarStore(eventStore: eventStore, defaults: defaults)
        first.colorOverrides[a.calendarIdentifier] = red
        first.hiddenCalendarIDs = ["h"]
        first.defaultCalendarID = "gone"

        let second = CalendarStore(eventStore: eventStore, defaults: defaults)
        #expect(second.colorOverrides[a.calendarIdentifier]?.description == red.description)
        #expect(second.hiddenCalendarIDs == ["h"])
        #expect(second.defaultCalendarID == "gone")
    }
}
