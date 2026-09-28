import Foundation

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
