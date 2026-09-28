import SwiftUI
@preconcurrency import EventKit

/// Calendar tab layouts (#25). Persisted as `calendarMode`; `-calendarMode month` works as a launch arg.
enum CalendarMode: String, CaseIterable {
    case days, month, agenda
}

/// Pure helpers for the month grid (#25).
enum MonthGrid {
    /// Start-of-day dates of the whole weeks covering `month`'s month, starting on `calendar.firstWeekday`.
    static func days(in month: Date, calendar: Calendar = .current) -> [Date] {
        let first = self.month(month, by: 0, calendar: calendar)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: first)!
        let length = calendar.range(of: .day, in: .month, for: first)!.count
        let total = (lead + length + 6) / 7 * 7
        return (0..<total).map { calendar.startOfDay(for: calendar.date(byAdding: .day, value: $0, to: start)!) }
    }

    /// Start of the month `months` away from `date`'s month.
    static func month(_ date: Date, by months: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: months, to: calendar.dateInterval(of: .month, for: date)!.start)!
    }
}

/// Mode picker shown in every mode's header.
struct CalendarModeMenu: View {
    @AppStorage("calendarMode") private var mode = CalendarMode.days

    var body: some View {
        Menu("Calendar View", systemImage: "calendar") {
            Picker("Calendar View", selection: $mode) {
                ForEach(CalendarMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
        }
    }
}

/// One event in a day list: color bar, title, time range or "All day".
private struct AgendaRow: View {
    @Environment(CalendarStore.self) private var store
    let event: EKEvent
    let day: Date
    let action: () -> Void

    var body: some View {
        let time = event.showsAllDay(on: day) ? "All day" : (event.startDate..<event.endDate).formatted(.interval.hour().minute())
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(store.color(for: event.calendar)).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title ?? "").font(.body)
                    Text(time).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Month grid with event dots; the selected day's events listed below.
struct MonthView: View {
    @Environment(CalendarStore.self) private var store
    let onSelect: (EKEvent) -> Void
    @State private var month = MonthGrid.month(.now, by: 0)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)

    private var isCurrentMonth: Bool { Calendar.current.isDate(month, equalTo: .now, toGranularity: .month) }

    /// Paging selects the 1st, or today in the current month.
    private func show(_ newMonth: Date) {
        month = newMonth
        selectedDay = isCurrentMonth ? Calendar.current.startOfDay(for: .now) : month
    }

    private func shift(_ months: Int) { show(MonthGrid.month(month, by: months)) }

    private func eventsOn(_ day: Date) -> [EKEvent] {
        let split = DayColumn.split(store.events, day: day)
        return split.allDay + split.timed
    }

    var body: some View {
        let days = MonthGrid.days(in: month)
        let range = DateInterval(start: days.first!, end: Calendar.current.date(byAdding: .day, value: 1, to: days.last!)!)
        VStack(spacing: 8) {
            HStack {
                Button("Previous Month", systemImage: "chevron.left") { shift(-1) }
                Text(month, format: .dateTime.month(.wide).year())
                    .font(.headline)
                    .frame(minWidth: 140)
                Button("Next Month", systemImage: "chevron.right") { shift(1) }
                Spacer()
                CalendarModeMenu()
                Button("Today") { show(MonthGrid.month(.now, by: 0)) }
                    .disabled(isCurrentMonth)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal)
            weekdayRow
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    Button { selectedDay = day } label: { dayCell(day) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
                let dx = drag.translation.width
                if abs(dx) > 80 && abs(dx) > 2 * abs(drag.translation.height) { shift(dx < 0 ? 1 : -1) }
            })
            Divider()
            dayList
        }
        .onChange(of: range, initial: true) { store.range = range }
    }

    private var weekdayRow: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let offset = Calendar.current.firstWeekday - 1
        let rotated = Array(symbols[offset...] + symbols[..<offset])
        return HStack(spacing: 0) {
            ForEach(rotated.indices, id: \.self) { i in
                Text(rotated[i]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let today = cal.isDateInToday(day)
        let selected = day == selectedDay
        let inMonth = cal.isDate(day, equalTo: month, toGranularity: .month)
        let events = eventsOn(day)
        return VStack(spacing: 3) {
            Text(day, format: .dateTime.day())
                .font(.callout.weight(today || selected ? .semibold : .regular))
                .foregroundStyle(today ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 32, height: 32)
                .background {
                    if today {
                        Circle().fill(.tint)
                    } else if selected {
                        Circle().fill(.secondary.opacity(0.3))
                    }
                }
            HStack(spacing: 2) {
                ForEach(events.prefix(3), id: \.rowID) { event in
                    Circle().fill(store.color(for: event.calendar)).frame(width: 5, height: 5)
                }
                if events.count > 3 {
                    Text("+").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(day.formatted(date: .complete, time: .omitted))\(today ? ", today" : ""), ^[\(events.count) event](inflect: true)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var dayList: some View {
        let events = eventsOn(selectedDay)
        if events.isEmpty {
            Text("No Events").foregroundStyle(.secondary).frame(maxHeight: .infinity)
        } else {
            List(events, id: \.rowID) { event in
                AgendaRow(event: event, day: selectedDay) { onSelect(event) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

/// Upcoming events from today, one section per day with events; loads 60 more days on reaching the end.
struct AgendaView: View {
    @Environment(CalendarStore.self) private var store
    let onSelect: (EKEvent) -> Void
    @State private var loadedDays = 60

    // ponytail: capped at 2 years ahead so an empty calendar doesn't page forever; raise the cap or add "Load More" if anyone scrolls that far.
    private let maxDays = 730

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let range = DateInterval(start: today, end: cal.date(byAdding: .day, value: loadedDays, to: today)!)
        // ponytail: splits every loaded day over all loaded events (O(days x events)); index by day if it ever stutters.
        let sections: [(day: Date, events: [EKEvent])] = (0..<loadedDays).compactMap { offset in
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            let split = DayColumn.split(store.events, day: day)
            let events = split.allDay + split.timed
            return events.isEmpty ? nil : (day, events)
        }
        VStack(spacing: 8) {
            HStack {
                Text("Upcoming").font(.headline)
                Spacer()
                CalendarModeMenu()
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal)
            if sections.isEmpty && loadedDays >= maxDays {
                ContentUnavailableView("No Upcoming Events", systemImage: "calendar")
            } else {
                List {
                    ForEach(sections, id: \.day) { section in
                        Section {
                            ForEach(section.events, id: \.rowID) { event in
                                AgendaRow(event: event, day: section.day) { onSelect(event) }
                            }
                        } header: {
                            Text(cal.isDateInToday(section.day) ? "Today"
                                 : cal.isDateInTomorrow(section.day) ? "Tomorrow"
                                 : section.day.formatted(.dateTime.weekday(.wide).month().day()))
                        }
                    }
                    if loadedDays < maxDays {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .id(loadedDays)
                            .onAppear { loadedDays = min(loadedDays + 60, maxDays) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: range, initial: true) { store.range = range }
    }
}
