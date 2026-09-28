import SwiftUI
import SwiftData
@preconcurrency import EventKit

/// Pure geometry for the day timeline (#23); #24 N-day grid and #29 task drop reuse it.
enum TimelineLayout {
    static let hourHeight: CGFloat = 60

    /// y offset of `date` inside the column for the day starting at `dayStart`, clamped to 0...24h.
    // ponytail: wall-clock mapping, so on DST days the skipped hour is empty and the repeated hour overlaps; exact 23/25h columns if anyone notices.
    static func y(for date: Date, dayStart: Date, calendar: Calendar = .current) -> CGFloat {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        if date <= dayStart { return 0 }
        if date >= dayEnd { return 24 * hourHeight }
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hours = Double(c.hour!) + Double(c.minute!) / 60 + Double(c.second!) / 3600
        return hours * hourHeight
    }

    /// Inverse of y(for:): the date at `y` in that day (clamped to the day). #29 drop target.
    static func date(forY y: CGFloat, dayStart: Date, calendar: Calendar = .current) -> Date {
        let seconds = Int((min(max(y, 0), 24 * hourHeight) / hourHeight * 3600).rounded())
        if seconds >= 24 * 3600 { return calendar.date(byAdding: .day, value: 1, to: dayStart)! }
        return calendar.date(bySettingHour: seconds / 3600, minute: seconds / 60 % 60, second: seconds % 60, of: dayStart)!
    }

    /// Tap-to-create start: the half hour containing `y`, at most 23:30.
    static func slotStart(forY y: CGFloat, dayStart: Date, calendar: Calendar = .current) -> Date {
        let half = hourHeight / 2
        return date(forY: min((y / half).rounded(.down), 47) * half, dayStart: dayStart, calendar: calendar)
    }

    struct Slot: Equatable { var column: Int; var columnCount: Int }

    /// Side-by-side columns for overlapping intervals. Input order = output order.
    static func slots(for intervals: [(start: Date, end: Date)]) -> [Slot] {
        // Zero-length events get one minute so they still claim a column.
        let spans = intervals.map { (start: $0.start, end: max($0.end, $0.start.addingTimeInterval(60))) }
        let order = spans.indices.sorted {
            spans[$0].start != spans[$1].start ? spans[$0].start < spans[$1].start : spans[$0].end > spans[$1].end
        }
        var result = Array(repeating: Slot(column: 0, columnCount: 1), count: spans.count)
        var columnEnds: [Date] = [], cluster: [Int] = [], clusterEnd = Date.distantPast
        func closeCluster() {
            for i in cluster { result[i].columnCount = columnEnds.count }
            columnEnds = []; cluster = []
        }
        for i in order {
            let span = spans[i]
            if span.start >= clusterEnd { closeCluster() }
            if let column = columnEnds.firstIndex(where: { $0 <= span.start }) {
                columnEnds[column] = span.end
                result[i].column = column
            } else {
                columnEnds.append(span.end)
                result[i].column = columnEnds.count - 1
            }
            cluster.append(i)
            clusterEnd = max(clusterEnd, span.end)
        }
        closeCluster()
        return result
    }
}

/// Pure helpers for the N-day grid (#24), N = 1...7.
enum DayGrid {
    static func clamp(_ count: Int) -> Int { min(max(count, 1), 7) }

    /// Start-of-day dates of the visible columns.
    static func visibleDays(from start: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        let first = calendar.startOfDay(for: start)
        return (0..<clamp(count)).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }

    /// `start` moved by `pages` screens of `count` days.
    static func page(_ start: Date, by pages: Int, count: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: pages * clamp(count), to: start)!
    }

    /// "+" default start: the next whole hour; on a day other than today, that hour of `day`.
    static func newEventStart(on day: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        let next = calendar.dateInterval(of: .hour, for: now)!.end
        if calendar.isDate(day, inSameDayAs: now) { return next }
        return calendar.date(bySettingHour: calendar.component(.hour, from: next), minute: 0, second: 0, of: day)!
    }

    /// Pinch out (zoom in) shows fewer days, pinch in shows more.
    static func count(afterPinch scale: CGFloat, from count: Int) -> Int {
        clamp(scale > 1.25 ? count - 1 : scale < 0.8 ? count + 1 : count)
    }

    /// Visible columns where `event` sits in the all-day row, matching DayColumn.split per day.
    static func allDaySpan(_ event: EKEvent, days: [Date], calendar: Calendar = .current) -> ClosedRange<Int>? {
        let hits = days.indices.filter { !DayColumn.split([event], day: days[$0], calendar: calendar).allDay.isEmpty }
        guard let first = hits.first, let last = hits.last else { return nil }
        return first...last
    }
}

extension EKEvent {
    /// Chip in the all-day row rather than a timed block: flagged all-day, or spans the whole day.
    func showsAllDay(on dayStart: Date, calendar: Calendar = .current) -> Bool {
        isAllDay || (startDate <= dayStart && endDate >= calendar.date(byAdding: .day, value: 1, to: dayStart)!)
    }
}

/// Timed events of one day as positioned blocks, 24 * hourHeight tall; no hour labels
/// (HourGrid draws those behind). #24 lays several side by side.
struct DayColumn: View {
    let day: Date
    let events: [EKEvent]
    let onSelect: (EKEvent) -> Void
    /// Tap on empty space: start of a new 1h event there.
    let onCreate: (Date) -> Void
    /// Tray task dropped: its calendarItemIdentifier and the block start; true if blocked.
    let onDropTask: (String, Date) -> Bool

    /// The events touching `day`, split into all-day chips and timed blocks (input order kept).
    static func split(_ events: [EKEvent], day: Date, calendar: Calendar = .current) -> (allDay: [EKEvent], timed: [EKEvent]) {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
        let onDay = events.filter { $0.startDate < dayEnd && ($0.endDate > day || $0.startDate == day) }
        return (onDay.filter { $0.showsAllDay(on: day, calendar: calendar) },
                onDay.filter { !$0.showsAllDay(on: day, calendar: calendar) })
    }

    var body: some View {
        let timed = Self.split(events, day: day).timed
        let slots = TimelineLayout.slots(for: timed.map { (start: $0.startDate, end: $0.endDate) })
        GeometryReader { geo in
            // Behind the blocks, so taps on events still select them. Mac: double-click, like Calendar.app.
            Color.clear
                .contentShape(.rect)
                #if os(macOS)
                .onTapGesture(count: 2) { onCreate(TimelineLayout.slotStart(forY: $0.y, dayStart: day)) }
                #else
                .onTapGesture { onCreate(TimelineLayout.slotStart(forY: $0.y, dayStart: day)) }
                #endif
                .accessibilityHidden(true)
            ForEach(Array(zip(timed, slots)), id: \.0.rowID) { event, slot in
                // Keep the 20pt minimum inside the 24h frame for short events near midnight.
                let top = min(TimelineLayout.y(for: event.startDate, dayStart: day), 24 * TimelineLayout.hourHeight - 20)
                let height = max(TimelineLayout.y(for: event.endDate, dayStart: day) - top, 20)
                let width = geo.size.width / CGFloat(slot.columnCount)
                EventBlock(event: event, compact: width < 80) { onSelect(event) }
                    .frame(width: width - 2, height: height - 1)
                    .offset(x: CGFloat(slot.column) * width, y: top)
            }
            TimelineView(.everyMinute) { context in
                if Calendar.current.isDate(context.date, inSameDayAs: day) {
                    HStack(spacing: 0) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Rectangle().fill(.red).frame(height: 1)
                    }
                    .offset(x: -4, y: TimelineLayout.y(for: context.date, dayStart: day) - 4)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 24 * TimelineLayout.hourHeight)
        // location is in the column's own space, i.e. timeline y.
        .dropDestination(for: String.self) { ids, location in
            ids.first.map { onDropTask($0, TimeBlock.dropInterval(atY: location.y, dayStart: day).start) } ?? false
        }
    }
}

private struct EventBlock: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent
    /// Narrow slot: clip to one line instead of wrapping per character.
    let compact: Bool
    let action: () -> Void

    var body: some View {
        let times = (event.startDate..<event.endDate).formatted(.interval.hour().minute())
        Button(action: action) {
            HStack(alignment: .top, spacing: 4) {
                Rectangle().fill(store.color(for: event.calendar)).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title ?? "").font(.caption.weight(.semibold)).fixedSize(horizontal: compact, vertical: compact)
                    Text(times).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: compact, vertical: compact)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(store.color(for: event.calendar).opacity(0.25))
            .clipShape(.rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(event.title ?? ""), \(times)")
    }
}

/// Hour gutter labels and a line per hour, drawn behind the day column(s).
// ponytail: rows are hourHeight tall, i.e. the same wall-clock mapping as TimelineLayout.y; rows carry .id(hour) for scrollTo.
struct HourGrid: View {
    static let gutterWidth: CGFloat = 52

    var body: some View {
        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(midnight.addingTimeInterval(Double(hour) * 3600), format: .dateTime.hour())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.gutterWidth - 8, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(.separator).frame(height: 0.5)
                }
                .frame(height: TimelineLayout.hourHeight, alignment: .top)
                .id(hour)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Calendar tab: 1-7 days side by side as a timeline with all-day events above, or month / agenda (#25).
struct CalendarView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(RemindersStore.self) private var reminders
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    /// First visible day.
    @State private var day = Calendar.current.startOfDay(for: .now)
    @AppStorage("calendarDays") private var dayCount = 1
    @AppStorage("calendarMode") private var mode = CalendarMode.days
    @State private var selected: SelectedEvent?
    @State private var showingSettings = false
    #if DEBUG
    @State private var openedNewEventHook = false
    #endif

    private struct SelectedEvent: Identifiable {
        let event: EKEvent
        // Object identity: rowID changes when a save moves the start or splits the series, which would re-present the sheet.
        var id: ObjectIdentifier { ObjectIdentifier(event) }
    }

    var body: some View {
        content
            .navigationTitle("Calendar")
            .themedBackground()
            .toolbar {
                if store.hasAccess {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Event", systemImage: "plus", action: createAtNextHour)
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Calendars", systemImage: "slider.horizontal.3") { showingSettings = true }
                    }
                }
            }
            .task {
                await store.refresh()
                await reminders.refresh()  // the tray needs tasks even if the Tasks tab was never opened
            }
            #if DEBUG
            // Screenshot hook: launch with `-calendarNewEvent YES` to open the new-event editor.
            .onAppear {
                guard !openedNewEventHook, store.hasAccess, UserDefaults.standard.bool(forKey: "calendarNewEvent") else { return }
                openedNewEventHook = true
                createAtNextHour()
            }
            // Screenshot hook: launch with `-calendarSettings YES` to open calendar settings.
            .onAppear { if UserDefaults.standard.bool(forKey: "calendarSettings") { showingSettings = true } }
            #endif
            .sheet(isPresented: $showingSettings) { CalendarSettingsSheet() }
            .sheet(item: $selected) { selection in
                if selection.event.eventIdentifier?.isEmpty ?? true {  // unsaved, same check as EventEditor
                    EventEditor(event: selection.event)
                } else {
                    EventDetailView(event: selection.event)
                }
            }
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
            // Separate branches, so switching back to Days recreates the timeline and its onChange(initial:) re-sets store.range.
            switch mode {
            case .days: timeline
            case .month: MonthView(onSelect: select)
            case .agenda: AgendaView(onSelect: select)
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

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var count: Int { DayGrid.clamp(dayCount) }
    private var days: [Date] { DayGrid.visibleDays(from: day, count: count) }

    private func shift(_ pages: Int) {
        day = DayGrid.page(day, by: pages, count: count)
    }

    private func select(_ event: EKEvent) { selected = SelectedEvent(event: event) }

    private func create(at start: Date) {
        let event = store.newEvent()
        event.startDate = start
        event.endDate = start.addingTimeInterval(3600)
        selected = SelectedEvent(event: event)
    }

    /// "+": next whole hour on the first visible day (Days mode) or today.
    private func createAtNextHour() {
        create(at: DayGrid.newEventStart(on: mode == .days ? day : .now))
    }

    /// Drop from the tray: block the task at `start` (or move its block); false if it can't.
    private func dropTask(_ id: String, at start: Date) -> Bool {
        guard let reminder = reminders.reminders.first(where: { $0.calendarItemIdentifier == id }) else { return false }
        let estimate = (try? modelContext.fetch(FetchDescriptor<TaskExtras>())).flatMap {
            TaskExtras.match($0, id: id, externalID: reminder.calendarItemExternalIdentifier)?.estimateMinutes
        }
        let duration = estimate.map { TimeInterval($0 * 60) } ?? TimeBlock.defaultDuration
        guard (try? createTimeBlock(for: reminder, start: start, duration: duration, calendar: nil,
                                    calendarStore: store, context: modelContext)) != nil
        else { return false }
        Task { await store.refresh() }  // show the new block now
        return true
    }

    private var timeline: some View {
        let days = days
        return VStack(spacing: 8) {
            HStack {
                Button(count == 1 ? "Previous Day" : "Previous \(count) Days", systemImage: "chevron.left") { shift(-1) }
                Group {
                    if count == 1 {
                        Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    } else {
                        Text((day..<days.last!).formatted(.interval.month(.abbreviated).day()))
                    }
                }
                .font(.headline)
                .frame(minWidth: 110)
                Button(count == 1 ? "Next Day" : "Next \(count) Days", systemImage: "chevron.right") { shift(1) }
                Spacer()
                CalendarModeMenu()
                Menu("Days Shown", systemImage: "calendar.day.timeline.left") {
                    Picker("Days Shown", selection: $dayCount) {
                        ForEach(1...7, id: \.self) { Text($0 == 1 ? "1 Day" : "\($0) Days").tag($0) }
                    }
                }
                Button("Today") { day = Calendar.current.startOfDay(for: .now) }
                    .disabled(isToday)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal)
            UnscheduledTray()
            if count == 1 {
                allDayChips
            } else {
                dayHeaders(days)
                allDayBars(days)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        HourGrid()
                        HStack(spacing: 0) {
                            ForEach(days, id: \.self) { day in
                                DayColumn(day: day, events: store.events, onSelect: select, onCreate: create, onDropTask: dropTask)
                                    .overlay(alignment: .leading) {
                                        if day != days.first { Rectangle().fill(.separator).frame(width: 0.5) }
                                    }
                            }
                        }
                        .padding(.leading, HourGrid.gutterWidth)
                        .padding(.trailing, 4)
                    }
                    .padding(.vertical, 8)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
                    let dx = drag.translation.width
                    if abs(dx) > 80 && abs(dx) > 2 * abs(drag.translation.height) { shift(dx < 0 ? 1 : -1) }
                })
                .simultaneousGesture(MagnifyGesture().onEnded {
                    dayCount = DayGrid.count(afterPinch: $0.magnification, from: count)
                })
                .onChange(of: days, initial: true) {
                    store.range = DateInterval(start: day, end: DayGrid.page(day, by: 1, count: count))
                    let firstHour = days.compactMap { day in
                        DayColumn.split(store.events, day: day).timed.first
                            .map { Calendar.current.component(.hour, from: max($0.startDate, day)) }
                    }.min()
                    let hour = days.contains(where: Calendar.current.isDateInToday)
                        ? Calendar.current.component(.hour, from: .now) - 1 : min(firstHour ?? 8, 8)
                    proxy.scrollTo(max(hour, 0), anchor: .top)
                }
            }
        }
    }

    /// N = 1: the day's all-day events as a horizontal chip row.
    @ViewBuilder
    private var allDayChips: some View {
        let allDay = DayColumn.split(store.events, day: day).allDay
        if !allDay.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(allDay, id: \.rowID) { event in
                        Button { select(event) } label: {
                            Text(event.title ?? "")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(store.color(for: event.calendar).opacity(0.25), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// N > 1: weekday + day number above each column.
    private func dayHeaders(_ days: [Date]) -> some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let today = Calendar.current.isDateInToday(day)
                VStack(spacing: 0) {
                    Text(day, format: .dateTime.weekday(.abbreviated)).font(.caption2).foregroundStyle(.secondary)
                    Text(day, format: .dateTime.day())
                        .font(.subheadline.weight(today ? .bold : .regular))
                        .foregroundStyle(today ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.leading, HourGrid.gutterWidth)
        .padding(.trailing, 4)
    }

    /// N > 1: one bar per all-day event across the columns it covers.
    // ponytail: one row per event, no lane packing; capped at 3 rows then scrolls.
    @ViewBuilder
    private func allDayBars(_ days: [Date]) -> some View {
        let bars = store.events.compactMap { event in DayGrid.allDaySpan(event, days: days).map { (event, $0) } }
        if !bars.isEmpty {
            let rowHeight: CGFloat = 22
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(bars, id: \.0.rowID) { event, span in
                        GeometryReader { geo in
                            let width = geo.size.width / CGFloat(days.count)
                            Button { select(event) } label: {
                                Text(event.title ?? "")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    .background(store.color(for: event.calendar).opacity(0.25), in: .rect(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .frame(width: width * CGFloat(span.count) - 2, height: rowHeight - 2)
                            .offset(x: width * CGFloat(span.lowerBound))
                        }
                        .frame(height: rowHeight)
                    }
                }
            }
            .frame(height: rowHeight * CGFloat(min(bars.count, 3)))
            .scrollIndicators(.hidden)
            .padding(.leading, HourGrid.gutterWidth)
            .padding(.trailing, 4)
        }
    }
}

/// Open tasks without a time block (today, overdue, undated), dragged onto a day column to block them (#29).
private struct UnscheduledTray: View {
    @Environment(RemindersStore.self) private var reminders
    @Environment(CalendarStore.self) private var calendarStore
    @Query private var extras: [TaskExtras]
    @AppStorage("calendarTrayExpanded") private var expanded = true

    var body: some View {
        // Read so a deleted linked event (refresh replaces events) puts its task back in the tray.
        let _ = calendarStore.events
        let tasks = TimeBlock.unscheduled(reminders.reminders, now: .now) { reminder in
            TaskExtras.match(extras, id: reminder.calendarItemIdentifier, externalID: reminder.calendarItemExternalIdentifier)?
                .eventID.flatMap { calendarStore.eventStore.event(withIdentifier: $0) } != nil
        }
        if reminders.hasAccess && !tasks.isEmpty {
            DisclosureGroup("Unscheduled (\(tasks.count))", isExpanded: $expanded) {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(tasks, id: \.calendarItemIdentifier) { reminder in
                            let title = reminder.title ?? ""
                            chip(title)
                                .draggable(reminder.calendarItemIdentifier) { chip(title) }
                                .accessibilityLabel("\(title), drag onto the timeline")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .font(.subheadline)
            .padding(.horizontal)
        }
    }

    private func chip(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.tint.opacity(0.2), in: .capsule)
    }
}

/// Event details; Edit (writable calendars only) swaps the sheet to EventEditor in place.
struct EventDetailView: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var travelTime: String?

    private var showsTravelTime: Bool { !event.isAllDay && event.structuredLocation?.geoLocation != nil }

    var body: some View {
        if editing {
            EventEditor(event: event) { editing = false }
        } else {
            details
        }
    }

    private var details: some View {
        NavigationStack {
            Form {
                Section {
                    Text(event.title ?? "").font(.headline)
                    Label {
                        Text(event.calendar.title)
                    } icon: {
                        Circle().fill(store.color(for: event.calendar)).frame(width: 10, height: 10)
                    }
                    if event.isAllDay {
                        Text("All day, \((event.startDate..<event.endDate).formatted(.interval.weekday().month().day()))")
                    } else {
                        Text((event.startDate..<event.endDate).formatted(.interval.weekday().month().day().hour().minute()))
                    }
                    if event.hasRecurrenceRules {
                        Label("Repeats", systemImage: "repeat")
                    }
                }
                if let location = event.location, !location.isEmpty {
                    Section("Location") {
                        Text(location)
                        if showsTravelTime {
                            Text(travelTime ?? "Travel time unavailable").foregroundStyle(.secondary)
                        }
                    }
                }
                if let url = event.url {
                    Section("URL") { Link(url.absoluteString, destination: url) }
                }
                if let notes = event.notes, !notes.isEmpty {
                    Section("Notes") { Text(notes) }
                }
            }
            .navigationTitle("Event")
            .task {
                guard showsTravelTime, await LocationPermission.shared.allowed(prompt: true) else { return }
                travelTime = await TravelTime.eta(to: event).map(TravelTime.describe)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if event.calendar.allowsContentModifications {
                    ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
                }
            }
        }
    }
}
