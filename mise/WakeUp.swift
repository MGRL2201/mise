import Foundation
import SwiftData
#if os(iOS)
import AlarmKit
import AppIntents
import SwiftUI
#endif

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

    /// When the alarm set for `hour:minute` first rang this morning: today, or
    /// the day before if that is still ahead (an alarm set before midnight, re-ringing after).
    static func firstRing(hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        guard today > now, let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return today }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: yesterday) ?? today
    }

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

#if os(iOS)
nonisolated struct WakeMetadata: AlarmMetadata {}

/// Mirrors `WakeAlarm`s into AlarmKit. Each on-alarm is a weekly `.relative`
/// AlarmKit alarm with the same id; "Still in bed" re-rings are one-off `.fixed` alarms.
enum WakeAlarms {
    nonisolated static func configuration(alarmID: UUID, hour: Int, minute: Int, schedule: Alarm.Schedule) -> AlarmManager.AlarmConfiguration<WakeMetadata> {
        let stillInBed = AlarmButton(text: "Still in bed", textColor: .white, systemImageName: "bed.double")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: "Stop when you're out of bed", secondaryButton: stillInBed, secondaryButtonBehavior: .custom)
        } else {
            alert = AlarmPresentation.Alert(title: "Stop when you're out of bed",
                                            stopButton: AlarmButton(text: "I'm out of bed", textColor: .white, systemImageName: "figure.walk"),
                                            secondaryButton: stillInBed, secondaryButtonBehavior: .custom)
        }
        let id = alarmID.uuidString
        return .alarm(schedule: schedule,
                      attributes: AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(), tintColor: .accentColor),
                      stopIntent: OutOfBedIntent(alarmID: id, hour: hour, minute: minute),
                      secondaryIntent: StillInBedIntent(alarmID: id, hour: hour, minute: minute))
    }

    /// The weekly AlarmKit schedule for `alarm`; nil if it has no valid weekday (1...7).
    static func schedule(for alarm: WakeAlarm) -> Alarm.Schedule? {
        let days: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        let weekdays = alarm.weekdays.compactMap { (1...7).contains($0) ? days[$0 - 1] : nil }
        guard !weekdays.isEmpty else { return nil }
        return .relative(.init(time: .init(hour: alarm.hour, minute: alarm.minute), repeats: .weekly(weekdays)))
    }

    static func schedule(_ alarm: WakeAlarm) async throws {
        cancel(alarm.id)
        guard alarm.isOn, let schedule = schedule(for: alarm) else { return }
        _ = try await AlarmManager.shared.schedule(
            id: alarm.id, configuration: configuration(alarmID: alarm.id, hour: alarm.hour, minute: alarm.minute, schedule: schedule))
    }

    static func message(for error: Error) -> String {
        if case AlarmManager.AlarmError.maximumLimitReached = error { return "Too many alarms are set. Turn one off and try again." }
        return error.localizedDescription
    }

    static func cancel(_ id: UUID) {
        try? AlarmManager.shared.cancel(id: id)
    }

    /// Schedules on-alarms AlarmKit lacks or has at another time (e.g. after a backup
    /// restore) and cancels weekly AlarmKit alarms with no on-alarm. Pending `.fixed` re-rings are left alone.
    static func sync(_ alarms: [WakeAlarm]) async {
        guard AlarmManager.shared.authorizationState == .authorized,
              let scheduled = try? AlarmManager.shared.alarms else { return }
        let on = alarms.filter(\.isOn)
        let onIDs = Set(on.map(\.id))
        // Only touch AlarmKit alarms still .scheduled: reschedule/cancel would kill an alarm
        // that's currently ringing (.alerting) or mid-snooze (.countdown/.paused).
        for alarm in on {
            let match = scheduled.first(where: { $0.id == alarm.id })
            if match == nil || (match?.state == .scheduled && match?.schedule != schedule(for: alarm)) {
                try? await schedule(alarm)
            }
        }
        for alarm in scheduled where !onIDs.contains(alarm.id) && alarm.state == .scheduled {
            if case .relative = alarm.schedule { cancel(alarm.id) }
        }
    }
}

/// Alarm stop button: logs the out-of-bed time for this morning.
struct OutOfBedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "I'm Out of Bed"
    static let isDiscoverable = false

    @Parameter(title: "Alarm ID") var alarmID: String
    @Parameter(title: "Hour") var hour: Int
    @Parameter(title: "Minute") var minute: Int
    @Dependency var container: ModelContainer

    init() {}
    nonisolated init(alarmID: String, hour: Int, minute: Int) {
        self.alarmID = alarmID
        self.hour = hour
        self.minute = minute
    }

    @MainActor func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        let firstRing = WakeSchedule.firstRing(hour: hour, minute: minute, now: .now, calendar: .current)
        try WakeLog.record(firstRing: firstRing, outOfBed: true, now: .now, context: container.mainContext)
        return .result()
    }
}

/// Alarm secondary button: counts a re-ring and rings again in 5 minutes, up to the cap.
struct StillInBedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Still in Bed"
    static let isDiscoverable = false

    @Parameter(title: "Alarm ID") var alarmID: String
    @Parameter(title: "Hour") var hour: Int
    @Parameter(title: "Minute") var minute: Int
    @Dependency var container: ModelContainer

    init() {}
    nonisolated init(alarmID: String, hour: Int, minute: Int) {
        self.alarmID = alarmID
        self.hour = hour
        self.minute = minute
    }

    @MainActor func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        let firstRing = WakeSchedule.firstRing(hour: hour, minute: minute, now: .now, calendar: .current)
        // Logging must never block the re-ring.
        let log = try? WakeLog.record(firstRing: firstRing, outOfBed: false, now: .now, context: container.mainContext)
        if (log?.reRings ?? 0) <= WakeSchedule.maxReRings {
            let id = UUID()  // same hour:minute, so every ring of this morning lands in one log
            _ = try await AlarmManager.shared.schedule(id: id, configuration: WakeAlarms.configuration(
                alarmID: id, hour: hour, minute: minute, schedule: .fixed(.now + WakeSchedule.reRingDelay)))
        }
        return .result()
    }
}
#endif
