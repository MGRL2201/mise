import Foundation
import SwiftData

/// A wake-up alarm (#132). `weekdays` uses Calendar weekday numbers
/// (1 = Sunday ... 7 = Saturday); empty means one-off, ringing once at the
/// next occurrence of hour:minute. No `@Attribute(.unique)` (see Storage.swift
/// comment): identity is by `id`, kept CloudKit-compatible.
@Model
final class WakeAlarm {
    var id: UUID = UUID()
    var hour: Int = 7
    var minute: Int = 0
    var weekdays: [Int] = []
    var isOn: Bool = true

    init(hour: Int, minute: Int, weekdays: [Int]) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }
}

/// One day's wake-up record: when the alarm first rang, how many times it
/// re-rang before the user got up, and when they got out of bed (if they did).
@Model
final class WakeLog {
    var day: Date = Date()
    var firstRing: Date = Date()
    var reRings: Int = 0
    var outOfBed: Date?

    init(firstRing: Date, calendar: Calendar) {
        self.firstRing = firstRing
        self.day = calendar.startOfDay(for: firstRing)
    }
}

enum WakeSchedule {
    static let reRingDelay: TimeInterval = 5 * 60
    static let maxReRings = 12

    /// Earliest date strictly after `after` at `hour:minute` whose weekday is
    /// in `weekdays` (any day if empty). DST-safe: asks Calendar for the next
    /// match per weekday and takes the minimum.
    static func nextFire(hour: Int, minute: Int, weekdays: [Int], after: Date, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let candidateWeekdays = weekdays.isEmpty ? [nil] : weekdays.map { Optional($0) }
        let candidates = candidateWeekdays.compactMap { weekday -> Date? in
            var matching = components
            matching.weekday = weekday
            return calendar.nextDate(after: after, matching: matching, matchingPolicy: .nextTime)
        }
        return candidates.min()
    }

    /// Mean minutes-since-midnight of `outOfBed` over logs that have one,
    /// rounded; nil if none do.
    static func averageOutOfBed(_ logs: [WakeLog], calendar: Calendar) -> Int? {
        let minutes = logs.compactMap { log -> Int? in
            guard let outOfBed = log.outOfBed else { return nil }
            let components = calendar.dateComponents([.hour, .minute], from: outOfBed)
            guard let hour = components.hour, let minute = components.minute else { return nil }
            return hour * 60 + minute
        }
        guard !minutes.isEmpty else { return nil }
        return Int((Double(minutes.reduce(0, +)) / Double(minutes.count)).rounded())
    }
}

extension WakeLog {
    /// Records a re-ring or an out-of-bed event for the log matching
    /// `firstRing`'s day, creating one if none exists yet.
    @discardableResult
    static func record(firstRing: Date, outOfBed: Bool, now: Date, context: ModelContext, calendar: Calendar = .current) throws -> WakeLog {
        let day = calendar.startOfDay(for: firstRing)
        let log: WakeLog
        if let existing = try context.fetch(FetchDescriptor<WakeLog>()).first(where: { $0.day == day }) {
            log = existing
        } else {
            log = WakeLog(firstRing: firstRing, calendar: calendar)
            context.insert(log)
        }
        if outOfBed {
            if log.outOfBed == nil { log.outOfBed = now }
        } else {
            log.reRings += 1
        }
        try context.save()
        return log
    }
}
