import Testing
import SwiftData
import Foundation
#if os(iOS)
import AlarmKit
#endif
@testable import mise

@MainActor
struct WakeUpTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var components = DateComponents(year: y, month: m, day: d, hour: h, minute: min)
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    /// Holds the container alive; `ModelContext` doesn't retain it on its own.
    @MainActor private struct Store {
        let container: ModelContainer
        var context: ModelContext { container.mainContext }
    }

    private func freshStore() throws -> Store {
        Store(container: try ModelContainer(
            for: Schema(Storage.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        ))
    }

    // MARK: nextFire

    @Test func weekdayAlarmLaterTodayReturnsToday() {
        // Friday 2026-10-02, alarm 07:00 Mon/Wed/Fri, asked at 06:00.
        let after = date(2026, 10, 2, 6, 0)
        let fire = WakeSchedule.nextFire(hour: 7, minute: 0, weekdays: [2, 4, 6], after: after, calendar: calendar)
        #expect(fire == date(2026, 10, 2, 7, 0))
    }

    @Test func timeAlreadyPassedTodayReturnsNextMatchingWeekday() {
        // Friday 2026-10-02 08:00, alarm 07:00 Mon/Wed/Fri -> Monday 2026-10-05.
        let after = date(2026, 10, 2, 8, 0)
        let fire = WakeSchedule.nextFire(hour: 7, minute: 0, weekdays: [2, 4, 6], after: after, calendar: calendar)
        #expect(fire == date(2026, 10, 5, 7, 0))
    }

    @Test func exactlyAtTimeIsExcluded() {
        let after = date(2026, 10, 2, 7, 0)
        let fire = WakeSchedule.nextFire(hour: 7, minute: 0, weekdays: [6], after: after, calendar: calendar)
        #expect(fire == date(2026, 10, 9, 7, 0))
    }

    @Test func emptyWeekdaysReturnsNextOccurrenceOfTime() {
        let after = date(2026, 10, 2, 6, 0)
        let fire = WakeSchedule.nextFire(hour: 7, minute: 0, weekdays: [], after: after, calendar: calendar)
        #expect(fire == date(2026, 10, 2, 7, 0))
    }

    @Test func dstGapStillReturnsADate() throws {
        // Europe/London: clocks spring forward at 01:00 -> 02:00 on 2026-03-29;
        // 01:30 doesn't exist that day.
        let after = date(2026, 3, 28, 12, 0)
        let fire = try #require(WakeSchedule.nextFire(hour: 1, minute: 30, weekdays: [], after: after, calendar: calendar))
        #expect(fire >= date(2026, 3, 29, 0, 0))
    }

    // MARK: firstRing

    @Test func firstRingIsTodayForMorningAlarm() {
        let fire = WakeSchedule.firstRing(hour: 6, minute: 30, now: date(2026, 10, 2, 6, 40), calendar: calendar)
        #expect(fire == date(2026, 10, 2, 6, 30))
    }

    @Test func firstRingBeforeMidnightIsPreviousDay() {
        let fire = WakeSchedule.firstRing(hour: 23, minute: 58, now: date(2026, 10, 2, 0, 5), calendar: calendar)
        #expect(fire == date(2026, 10, 1, 23, 58))
    }

    // MARK: averageOutOfBed

    @Test func averagesMinutesSinceMidnight() {
        let a = WakeLog(firstRing: date(2026, 10, 1, 7, 0), calendar: calendar)
        a.outOfBed = date(2026, 10, 1, 7, 0)
        let b = WakeLog(firstRing: date(2026, 10, 2, 7, 0), calendar: calendar)
        b.outOfBed = date(2026, 10, 2, 7, 30)
        #expect(WakeSchedule.averageOutOfBed([a, b], calendar: calendar) == 435)
    }

    @Test func logsWithoutOutOfBedAreIgnored() {
        let withOutOfBed = WakeLog(firstRing: date(2026, 10, 1, 7, 0), calendar: calendar)
        withOutOfBed.outOfBed = date(2026, 10, 1, 7, 0)
        let without = WakeLog(firstRing: date(2026, 10, 2, 7, 0), calendar: calendar)
        #expect(WakeSchedule.averageOutOfBed([withOutOfBed, without], calendar: calendar) == 420)
    }

    @Test func emptyLogsReturnsNil() {
        #expect(WakeSchedule.averageOutOfBed([], calendar: calendar) == nil)
    }

    // MARK: record

    @Test func firstReRingCreatesLogWithOneReRing() throws {
        let store = try freshStore(); let context = store.context
        let firstRing = date(2026, 10, 1, 7, 0)
        let log = try WakeLog.record(firstRing: firstRing, outOfBed: false, now: firstRing, context: context, calendar: calendar)
        #expect(log.reRings == 1)
        #expect(log.outOfBed == nil)
    }

    @Test func secondReRingIncrementsToTwo() throws {
        let store = try freshStore(); let context = store.context
        let firstRing = date(2026, 10, 1, 7, 0)
        try WakeLog.record(firstRing: firstRing, outOfBed: false, now: firstRing, context: context, calendar: calendar)
        let log = try WakeLog.record(firstRing: firstRing, outOfBed: false, now: firstRing, context: context, calendar: calendar)
        #expect(log.reRings == 2)
    }

    @Test func outOfBedSetsTimestamp() throws {
        let store = try freshStore(); let context = store.context
        let firstRing = date(2026, 10, 1, 7, 0)
        let outOfBed = date(2026, 10, 1, 7, 10)
        let log = try WakeLog.record(firstRing: firstRing, outOfBed: true, now: outOfBed, context: context, calendar: calendar)
        #expect(log.outOfBed == outOfBed)
    }

    @Test func laterOutOfBedDoesNotOverwrite() throws {
        let store = try freshStore(); let context = store.context
        let firstRing = date(2026, 10, 1, 7, 0)
        let first = date(2026, 10, 1, 7, 10)
        let second = date(2026, 10, 1, 7, 20)
        try WakeLog.record(firstRing: firstRing, outOfBed: true, now: first, context: context, calendar: calendar)
        let log = try WakeLog.record(firstRing: firstRing, outOfBed: true, now: second, context: context, calendar: calendar)
        #expect(log.outOfBed == first)
    }

    @Test func differentDayCreatesSeparateLog() throws {
        let store = try freshStore(); let context = store.context
        try WakeLog.record(firstRing: date(2026, 10, 1, 7, 0), outOfBed: false, now: date(2026, 10, 1, 7, 0), context: context, calendar: calendar)
        try WakeLog.record(firstRing: date(2026, 10, 2, 7, 0), outOfBed: false, now: date(2026, 10, 2, 7, 0), context: context, calendar: calendar)
        let logs = try context.fetch(FetchDescriptor<WakeLog>())
        #expect(logs.count == 2)
    }

    // MARK: backup round-trip

    @Test func backupRoundTripIncludesWakeAlarmAndLog() throws {
        let sourceStore = try freshStore()
        let source = sourceStore.context
        let alarm = WakeAlarm(hour: 7, minute: 30, weekdays: [2, 3, 4, 5, 6])
        source.insert(alarm)
        let log = WakeLog(firstRing: date(2026, 10, 1, 7, 0), calendar: calendar)
        log.outOfBed = date(2026, 10, 1, 7, 5)
        source.insert(log)
        try source.save()

        let files = AttachmentFileStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let data = try BackupService.export(context: source, files: files, defaults: defaults)

        let targetStore = try freshStore()
        let target = targetStore.context
        try BackupService.restore(data, context: target, files: files, defaults: defaults)

        let restoredAlarms = try target.fetch(FetchDescriptor<WakeAlarm>())
        #expect(restoredAlarms.count == 1)
        #expect(restoredAlarms.first?.id == alarm.id)
        #expect(restoredAlarms.first?.hour == 7)
        #expect(restoredAlarms.first?.minute == 30)
        #expect(restoredAlarms.first?.weekdays == [2, 3, 4, 5, 6])

        let restoredLogs = try target.fetch(FetchDescriptor<WakeLog>())
        #expect(restoredLogs.count == 1)
        #expect(restoredLogs.first?.day == log.day)
        #expect(restoredLogs.first?.outOfBed == log.outOfBed)
    }

    @Test func backupWithoutWakeKeysLeavesExistingAlarmsAlone() throws {
        let targetStore = try freshStore()
        let target = targetStore.context
        let existing = WakeAlarm(hour: 6, minute: 45, weekdays: [])
        target.insert(existing)
        try target.save()

        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let json = #"{"version":2,"createdAt":0,"attachments":[],"settings":"\#(settings.base64EncodedString())"}"#
        let files = AttachmentFileStore(baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        try BackupService.restore(Data(json.utf8), context: target, files: files, defaults: defaults)

        let alarms = try target.fetch(FetchDescriptor<WakeAlarm>())
        #expect(alarms.map(\.id) == [existing.id])
    }

    #if os(iOS)
    // MARK: AlarmKit schedule

    @Test func scheduleIsWeeklyRelativeAtAlarmTime() {
        let schedule = WakeAlarms.schedule(for: WakeAlarm(hour: 6, minute: 30, weekdays: [2, 6]))
        #expect(schedule == .relative(.init(time: .init(hour: 6, minute: 30), repeats: .weekly([.monday, .friday]))))
    }

    @Test func outOfRangeWeekdaysAreDropped() {
        let schedule = WakeAlarms.schedule(for: WakeAlarm(hour: 6, minute: 30, weekdays: [0, 2, 8]))
        #expect(schedule == .relative(.init(time: .init(hour: 6, minute: 30), repeats: .weekly([.monday]))))
    }

    @Test func noValidWeekdaysMeansNoSchedule() {
        #expect(WakeAlarms.schedule(for: WakeAlarm(hour: 6, minute: 30, weekdays: [0, 9])) == nil)
    }
    #endif
}
