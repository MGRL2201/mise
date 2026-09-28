import SwiftUI
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

extension EKEvent {
    /// Chip in the all-day row rather than a timed block: flagged all-day, or spans the whole day.
    func showsAllDay(on dayStart: Date, calendar: Calendar = .current) -> Bool {
        isAllDay || (startDate <= dayStart && endDate >= calendar.date(byAdding: .day, value: 1, to: dayStart)!)
    }

    var color: Color { Color(cgColor: calendar.cgColor) }
}

/// Timed events of one day as positioned blocks, 24 * hourHeight tall; no hour labels
/// (HourGrid draws those behind). #24 lays several side by side.
struct DayColumn: View {
    let day: Date
    let events: [EKEvent]
    let onSelect: (EKEvent) -> Void

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
            ForEach(Array(zip(timed, slots)), id: \.0.rowID) { event, slot in
                // Keep the 20pt minimum inside the 24h frame for short events near midnight.
                let top = min(TimelineLayout.y(for: event.startDate, dayStart: day), 24 * TimelineLayout.hourHeight - 20)
                let height = max(TimelineLayout.y(for: event.endDate, dayStart: day) - top, 20)
                let width = geo.size.width / CGFloat(slot.columnCount)
                EventBlock(event: event) { onSelect(event) }
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
    }
}

private struct EventBlock: View {
    let event: EKEvent
    let action: () -> Void

    var body: some View {
        let times = (event.startDate..<event.endDate).formatted(.interval.hour().minute())
        Button(action: action) {
            HStack(alignment: .top, spacing: 4) {
                Rectangle().fill(event.color).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title ?? "").font(.caption.weight(.semibold))
                    Text(times).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(event.color.opacity(0.25))
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

/// Calendar tab: one day as a timeline, with all-day chips above.
struct CalendarView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var selected: SelectedEvent?

    private struct SelectedEvent: Identifiable {
        let event: EKEvent
        var id: String { event.rowID }
    }

    var body: some View {
        content
            .navigationTitle("Calendar")
            .themedBackground()
            .task { await store.refresh() }
            .sheet(item: $selected) { EventDetailView(event: $0.event) }
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
            timeline
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

    private func shift(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day)!
    }

    private var timeline: some View {
        let allDay = DayColumn.split(store.events, day: day).allDay
        return VStack(spacing: 8) {
            HStack {
                Button("Previous Day", systemImage: "chevron.left") { shift(-1) }
                Text(day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.headline)
                    .frame(minWidth: 110)
                Button("Next Day", systemImage: "chevron.right") { shift(1) }
                Spacer()
                Button("Today") { day = Calendar.current.startOfDay(for: .now) }
                    .disabled(isToday)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal)
            if !allDay.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(allDay, id: \.rowID) { event in
                            Button { selected = SelectedEvent(event: event) } label: {
                                Text(event.title ?? "")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(event.color.opacity(0.25), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        HourGrid()
                        DayColumn(day: day, events: store.events) { selected = SelectedEvent(event: $0) }
                            .padding(.leading, HourGrid.gutterWidth)
                            .padding(.trailing, 4)
                    }
                    .padding(.vertical, 8)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
                    let dx = drag.translation.width
                    if abs(dx) > 80 && abs(dx) > 2 * abs(drag.translation.height) { shift(dx < 0 ? 1 : -1) }
                })
                .onChange(of: day, initial: true) {
                    store.range = DateInterval(start: day, end: Calendar.current.date(byAdding: .day, value: 1, to: day)!)
                    let firstHour = DayColumn.split(store.events, day: day).timed.first
                        .map { Calendar.current.component(.hour, from: max($0.startDate, day)) }
                    let hour = isToday ? Calendar.current.component(.hour, from: .now) - 1 : min(firstHour ?? 8, 8)
                    proxy.scrollTo(max(hour, 0), anchor: .top)
                }
            }
        }
    }
}

/// Read-only event details; #26 replaces it with the editor.
struct EventDetailView: View {
    let event: EKEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(event.title ?? "").font(.headline)
                    Label {
                        Text(event.calendar.title)
                    } icon: {
                        Circle().fill(event.color).frame(width: 10, height: 10)
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
                    Section("Location") { Text(location) }
                }
                if let url = event.url {
                    Section("URL") { Link(url.absoluteString, destination: url) }
                }
                if let notes = event.notes, !notes.isEmpty {
                    Section("Notes") { Text(notes) }
                }
            }
            .navigationTitle("Event")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
