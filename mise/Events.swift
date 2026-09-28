import SwiftUI
@preconcurrency import EventKit

/// Calendar events layer: shares the app's one `EKEventStore`, full-access
/// only (SPEC §6.2). Callers set EKEvent properties (title, startDate,
/// endDate, isAllDay, location, notes, recurrenceRules, alarms, calendar)
/// directly, then `save`.
@Observable final class CalendarStore {
    let eventStore: EKEventStore
    var status: EKAuthorizationStatus
    var calendars: [EKCalendar] = []
    var range: DateInterval = {
        let today = Calendar.current.startOfDay(for: .now)
        return DateInterval(start: today, end: Calendar.current.date(byAdding: .day, value: 7, to: today)!)
    }() {
        didSet { reloadEvents() }
    }
    var events: [EKEvent] = []

    // Settings keyed by EKCalendar.calendarIdentifier, persisted in UserDefaults (#27).
    @ObservationIgnored private let defaults: UserDefaults
    var hiddenCalendarIDs: Set<String> {
        didSet {
            defaults.set(Array(hiddenCalendarIDs), forKey: "calendar.hidden")
            reloadEvents()
        }
    }
    var colorOverrides: [String: Color.Resolved] {
        didSet { defaults.set(try? JSONEncoder().encode(colorOverrides), forKey: "calendar.colors") }
    }
    var defaultCalendarID: String? {
        didSet { defaults.set(defaultCalendarID, forKey: "calendar.default") }
    }

    var hasAccess: Bool { status == .fullAccess }

    init(eventStore: EKEventStore = EKEventStore(), defaults: UserDefaults = .standard) {
        self.eventStore = eventStore
        self.defaults = defaults
        hiddenCalendarIDs = Self.loadHidden(defaults)
        colorOverrides = Self.loadColors(defaults)
        defaultCalendarID = defaults.string(forKey: "calendar.default")
        status = EKEventStore.authorizationStatus(for: .event)
        let store = eventStore
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged, object: store) {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    private static func loadHidden(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: "calendar.hidden") ?? [])
    }

    private static func loadColors(_ defaults: UserDefaults) -> [String: Color.Resolved] {
        defaults.data(forKey: "calendar.colors").flatMap { try? JSONDecoder().decode([String: Color.Resolved].self, from: $0) } ?? [:]
    }

    /// Re-read after a backup restore rewrote UserDefaults; setting hiddenCalendarIDs reloads events.
    func reloadSettings() {
        colorOverrides = Self.loadColors(defaults)
        defaultCalendarID = defaults.string(forKey: "calendar.default")
        hiddenCalendarIDs = Self.loadHidden(defaults)
    }

    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        await refresh()
    }

    func refresh() async {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            withMutation(keyPath: \.calendars) { calendars = [] }
            events = []
            return
        }
        // Every account source (iCloud, Exchange/Outlook, local, subscribed).
        withMutation(keyPath: \.calendars) { calendars = eventStore.calendars(for: .event) }
        reloadEvents()
    }

    // Refetched EKEvents (and EKCalendars) are == the old ones (isEqual) even after an
    // external edit, so a plain assignment skips @Observable's notify; force it (#126).
    private func reloadEvents() {
        withMutation(keyPath: \.events) { events = events(in: range) }
    }

    func events(in interval: DateInterval) -> [EKEvent] {
        // nil = all calendars.
        let visible = hiddenCalendarIDs.isEmpty ? nil : Self.visible(eventStore.calendars(for: .event), hidden: hiddenCalendarIDs)
        // An empty calendars array would mean "all" to EventKit.
        if visible?.isEmpty == true { return [] }
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: visible)
        return eventStore.events(matching: predicate).sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return (lhs.title ?? "") < (rhs.title ?? "")
        }
    }

    func newEvent(in calendar: EKCalendar? = nil) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar ?? defaultCalendar
        return event
    }

    static func visible(_ calendars: [EKCalendar], hidden: Set<String>) -> [EKCalendar] {
        calendars.filter { !hidden.contains($0.calendarIdentifier) }
    }

    /// User's chosen default if it still exists and is writable, else the system default.
    /// Looked up directly: `calendars` is empty until refresh() (#27).
    var defaultCalendar: EKCalendar? {
        if let chosen = defaultCalendarID.flatMap(eventStore.calendar(withIdentifier:)), chosen.allowsContentModifications {
            return chosen
        }
        return eventStore.defaultCalendarForNewEvents
    }

    /// User override, else the calendar's own color; gray without a calendar.
    func color(for calendar: EKCalendar?) -> Color {
        guard let calendar else { return .gray }
        return colorOverrides[calendar.calendarIdentifier].map { Color($0) } ?? Color(cgColor: calendar.cgColor)
    }

    // Reload rather than patch: a .futureEvents edit touches many occurrences.
    func save(_ event: EKEvent, span: EKSpan = .thisEvent) throws {
        do {
            try eventStore.save(event, span: span, commit: true)
        } catch {
            event.rollback()
            throw error
        }
        reloadEvents()
    }

    func delete(_ event: EKEvent, span: EKSpan = .thisEvent) throws {
        let id = event.eventIdentifier, occurrence = event.occurrenceDate
        let predicate = eventStore.predicateForEvents(withStart: event.startDate, end: event.endDate, calendars: nil)
        let recurs = event.hasRecurrenceRules  // remove() resets the object
        try eventStore.remove(event, span: span, commit: true)
        // #16: EventKit silently ignores a .thisEvent removal of a series' only
        // occurrence (COUNT=1 or UNTIL-truncated after a split). Still there? Make it a
        // one-off and remove that; .futureEvents would also take the split-off series.
        // Assumes that's the only way a .thisEvent removal leaves the occurrence behind;
        // any other cause would also get detached and deleted here.
        if span == .thisEvent, recurs,
           let left = eventStore.events(matching: predicate).first(where: { $0.eventIdentifier == id && $0.occurrenceDate == occurrence }) {
            left.recurrenceRules = nil
            try eventStore.save(left, span: .thisEvent, commit: true)
            try eventStore.remove(left, span: .thisEvent, commit: true)
        }
        reloadEvents()
    }
}

extension EKEvent {
    // Recurring occurrences share eventIdentifier; occurrenceDate (the original
    // series slot) tells them apart even when a detached occurrence is moved.
    var rowID: String { "\(eventIdentifier ?? "")|\(occurrenceDate.timeIntervalSinceReferenceDate)" }
}
