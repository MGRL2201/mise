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
    }()
    var events: [EKEvent] = []

    var hasAccess: Bool { status == .fullAccess }

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
        status = EKEventStore.authorizationStatus(for: .event)
        let store = eventStore
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged, object: store) {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func requestAccess() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        await refresh()
    }

    func refresh() async {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            calendars = []
            events = []
            return
        }
        // Every account source (iCloud, Exchange/Outlook, local, subscribed).
        calendars = eventStore.calendars(for: .event)
        reloadEvents()
    }

    // Refetched EKEvents are == the old ones (isEqual) even after an external
    // edit, so a plain assignment skips @Observable's notify; force it (#126).
    private func reloadEvents() {
        withMutation(keyPath: \.events) { events = events(in: range) }
    }

    func events(in interval: DateInterval) -> [EKEvent] {
        // ponytail: all calendars; #27 filters hidden ones here.
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return eventStore.events(matching: predicate).sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            return (lhs.title ?? "") < (rhs.title ?? "")
        }
    }

    func newEvent(in calendar: EKCalendar? = nil) -> EKEvent {
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar ?? eventStore.defaultCalendarForNewEvents
        return event
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
        try eventStore.remove(event, span: span, commit: true)
        reloadEvents()
    }
}

/// Placeholder list of upcoming events; real calendar views land in #23–#27.
struct CalendarView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle("Calendar")
            .themedBackground()
            .task { await store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .notDetermined:
            ContentUnavailableView {
                Label("Calendar", systemImage: "calendar")
            } description: {
                Text("mise needs access to Calendar to show your events.")
            } actions: {
                Button("Allow Access") { Task { await store.requestAccess() } }
            }
        case .fullAccess:
            if store.events.isEmpty {
                ContentUnavailableView("No Upcoming Events", systemImage: "calendar")
            } else {
                List(store.events, id: \.rowID) { event in
                    row(for: event)
                }
                .refreshable { await store.refresh() }
            }
        default:
            ContentUnavailableView {
                Label("Full Access Needed", systemImage: "lock")
            } description: {
                Text("mise needs full access to Calendar. Enable it in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = privacySettingsURL(macAnchor: "Privacy_Calendars") { openURL(url) }
                }
            }
        }
    }

    private func row(for event: EKEvent) -> some View {
        HStack {
            Circle()
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(event.title ?? "")
                Group {
                    if event.isAllDay {
                        Text("All day, \(event.startDate.formatted(.dateTime.weekday().day()))")
                    } else {
                        Text(event.startDate, format: .dateTime.weekday().day().hour().minute())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private extension EKEvent {
    // Recurring occurrences share eventIdentifier; startDate tells them apart.
    var rowID: String { "\(eventIdentifier ?? "")|\(startDate.timeIntervalSinceReferenceDate)" }
}
