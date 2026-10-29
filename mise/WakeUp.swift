import Foundation
import Observation
import SwiftData
#if os(iOS)
import AlarmKit
import AppIntents
import SwiftUI
import UserNotifications
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

/// A Stop not yet confirmed by typing the phrase. In UserDefaults so it survives the app being killed.
struct WakePending: Codable, Equatable {
    var firstRing: Date
    var reRingID: UUID?  // nil once the re-ring cap is reached
    var stoppedAt: Date
    static let key = "wake.pending"
    static let expiry: TimeInterval = 60 * 60

    static func current(_ defaults: UserDefaults = .standard, now: Date = .now) -> WakePending? {
        guard let data = defaults.data(forKey: key),
              let pending = try? JSONDecoder().decode(WakePending.self, from: data),
              now.timeIntervalSince(pending.stoppedAt) <= expiry else { return nil }
        return pending
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

enum WakePhrase {
    static let key = "wake.phrase"
    static let standard = "I am awake"

    /// Lowercased, whitespace runs collapsed to one space, trimmed, trailing punctuation removed.
    static func normalized(_ text: String) -> String {
        var result = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = result.unicodeScalars.last, CharacterSet.punctuationCharacters.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// A blank `phrase` falls back to `standard`; an empty `typed` never matches.
    static func matches(_ typed: String, phrase: String) -> Bool {
        let target = normalized(phrase).isEmpty ? normalized(standard) : normalized(phrase)
        let typed = normalized(typed)
        return !typed.isEmpty && typed == target
    }

    /// Paste guard: accept a text change only if the inserted run (new minus the common prefix and
    /// non-overlapping common suffix) is at most 2 characters, so pasting over a selection fails.
    static func isTyped(old: String, new: String) -> Bool {
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let suffix = zip(old.reversed(), new.reversed())
            .prefix(min(old.count, new.count) - prefix).prefix { $0 == $1 }.count
        return new.count - prefix - suffix <= 2
    }
}

enum WakeFlow {
    /// Stop pressed. A stop of the pending re-ring counts one re-ring in the WakeLog; the first ring's
    /// stop doesn't. Returns the id for the next re-ring, or nil once the log has `maxReRings` re-rings.
    /// Saves the new `WakePending` either way.
    static func stopped(alarmID: UUID?, firstRing: Date, now: Date, context: ModelContext, defaults: UserDefaults,
                        calendar: Calendar = .current) -> UUID? {
        let reRings: Int
        if let alarmID, WakePending.current(defaults, now: now)?.reRingID == alarmID {
            // Logging must never block the re-ring.
            reRings = (try? WakeLog.record(firstRing: firstRing, outOfBed: false, now: now, context: context, calendar: calendar))?.reRings ?? 0
        } else {
            let day = calendar.startOfDay(for: firstRing)
            reRings = (try? context.fetch(FetchDescriptor<WakeLog>()))?.first(where: { $0.day == day })?.reRings ?? 0
        }
        let next = reRings < WakeSchedule.maxReRings ? UUID() : nil
        WakePending(firstRing: firstRing, reRingID: next, stoppedAt: now).save(defaults)
        return next
    }

    /// The pending re-ring that stopping `alarmID` would replace without stopping (another alarm's stop).
    /// Caller cancels it before `stopped`, else that chain rings forever outside the cap.
    static func orphan(stopping alarmID: UUID?, now: Date, defaults: UserDefaults) -> UUID? {
        guard let id = WakePending.current(defaults, now: now)?.reRingID, id != alarmID else { return nil }
        return id
    }

    /// Correct phrase with a current pending: logs out-of-bed, clears the pending and returns it
    /// (caller cancels its `reRingID`). Wrong phrase or no pending: changes nothing, returns nil.
    static func confirm(_ typed: String, phrase: String, now: Date, context: ModelContext, defaults: UserDefaults,
                        calendar: Calendar = .current) -> WakePending? {
        guard let pending = WakePending.current(defaults, now: now), WakePhrase.matches(typed, phrase: phrase) else { return nil }
        // A failed save must never keep the alarm ringing.
        _ = try? WakeLog.record(firstRing: pending.firstRing, outOfBed: true, now: now, context: context, calendar: calendar)
        WakePending.clear(defaults)
        return pending
    }
}

/// Presents the confirm screen; like `PlanningPrompt`.
@Observable final class WakePrompt {
    static let shared = WakePrompt()
    nonisolated static let notificationID = "wake-confirm"
    var isPresented = false
    func show() { isPresented = true }
}

#if os(iOS)
nonisolated struct WakeMetadata: AlarmMetadata {}

/// Mirrors `WakeAlarm`s into AlarmKit. Each on-alarm is a weekly `.relative`
/// AlarmKit alarm with the same id; re-rings after Stop are one-off `.fixed` alarms.
enum WakeAlarms {
    /// Bumped when `configuration` changes, so `sync` reschedules alarms made with the old one.
    static let version = 2
    static let versionKey = "wake.alarmVersion"

    nonisolated static func configuration(alarmID: UUID, hour: Int, minute: Int, schedule: Alarm.Schedule) -> AlarmManager.AlarmConfiguration<WakeMetadata> {
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: "Wake up")
        } else {
            alert = AlarmPresentation.Alert(title: "Wake up", stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        }
        return .alarm(schedule: schedule,
                      attributes: AlarmAttributes(presentation: AlarmPresentation(alert: alert), metadata: WakeMetadata(), tintColor: .accentColor),
                      stopIntent: WakeStopIntent(alarmID: alarmID.uuidString, hour: hour, minute: minute))
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
    /// restore) or with an older `configuration`, and cancels weekly AlarmKit alarms with no on-alarm.
    /// Pending `.fixed` re-rings are left alone.
    static func sync(_ alarms: [WakeAlarm]) async {
        guard !Storage.inMemory else { return }  // empty in-memory list would cancel the user's real AlarmKit alarms
        guard AlarmManager.shared.authorizationState == .authorized,
              let scheduled = try? AlarmManager.shared.alarms else { return }
        let on = alarms.filter(\.isOn)
        let onIDs = Set(on.map(\.id))
        let outdated = UserDefaults.standard.integer(forKey: versionKey) < version
        // Only touch AlarmKit alarms still .scheduled: reschedule/cancel would kill an alarm
        // that's currently ringing (.alerting) or mid-snooze (.countdown/.paused).
        var skipped = false
        for alarm in on {
            let match = scheduled.first(where: { $0.id == alarm.id })
            if outdated, let match, match.state != .scheduled { skipped = true }
            if match == nil || (match?.state == .scheduled && (outdated || match?.schedule != schedule(for: alarm))) {
                try? await schedule(alarm)
            }
        }
        for alarm in scheduled where !onIDs.contains(alarm.id) && alarm.state == .scheduled {
            if case .relative = alarm.schedule { cancel(alarm.id) }
        }
        // Keep the old version while an outdated alarm is ringing/snoozed so a later sync updates it.
        if !skipped { UserDefaults.standard.set(version, forKey: versionKey) }
    }
}

/// Alarm Stop: opens mise to confirm by typing the phrase, and rings again in 5 minutes
/// (up to the cap) until that's done. Doesn't log out of bed.
struct WakeStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Wake-up Alarm"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

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
        let stopped = UUID(uuidString: alarmID)
        if let stopped { try? AlarmManager.shared.stop(id: stopped) }
        let firstRing = WakeSchedule.firstRing(hour: hour, minute: minute, now: .now, calendar: .current)
        if let orphan = WakeFlow.orphan(stopping: stopped, now: .now, defaults: .standard) { WakeAlarms.cancel(orphan) }
        if let id = WakeFlow.stopped(alarmID: stopped, firstRing: firstRing, now: .now, context: container.mainContext, defaults: .standard) {
            // same hour:minute, so every ring of this morning lands in one log
            _ = try? await AlarmManager.shared.schedule(id: id, configuration: WakeAlarms.configuration(
                alarmID: id, hour: hour, minute: minute, schedule: .fixed(.now + WakeSchedule.reRingDelay)))
        }
        if await LocalNotifications.authorized(prompt: false) {
            let content = UNMutableNotificationContent()
            content.title = "Confirm you're up"
            content.body = "Type your phrase to stop the next alarm."
            content.interruptionLevel = .timeSensitive
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: WakePrompt.notificationID, content: content, trigger: nil))
        }
        WakePrompt.shared.show()
        return .result()
    }
}
#endif
