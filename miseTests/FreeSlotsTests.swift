import Testing
import Foundation
@testable import mise

@MainActor
struct FreeSlotsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    /// March 2026: the 2nd is a Monday, the 7th/8th a weekend, DST starts on the 8th.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }
    private func busy(_ day: Int, _ from: Int, _ to: Int) -> DateInterval {
        DateInterval(start: at(day, from), end: at(day, to))
    }
    private func find(_ busy: [DateInterval] = [], hours: WorkingHours = .standard, minutes: Int = 30,
                      now: Date, days: Int = 7) -> [Date] {
        let slots = FreeSlots.find(busy: busy, hours: hours, duration: TimeInterval(minutes * 60), now: now,
                                   days: days, calendar: calendar)
        #expect(slots.allSatisfy { $0.duration == TimeInterval(minutes * 60) })
        return slots.map(\.start)
    }

    @Test func emptyCalendarGivesFirstThreeWorkdayStarts() {
        #expect(find(now: at(2, 8)) == [at(2, 9), at(3, 9), at(4, 9)])
    }

    @Test func overlappingEventsMerge() {
        #expect(find([busy(2, 9, 10), DateInterval(start: at(2, 9, 30), end: at(2, 11))], minutes: 60,
                     now: at(2, 8), days: 1) == [at(2, 11)])
    }

    @Test func adjacentEventsLeaveNoGap() {
        #expect(find([busy(2, 9, 10), busy(2, 10, 11), DateInterval(start: at(2, 11, 30), end: at(2, 18))],
                     now: at(2, 8), days: 1) == [at(2, 11)])
    }

    @Test func nestedEventDoesNotShortenOuter() {
        #expect(find([busy(2, 9, 12), busy(2, 10, 11), busy(2, 13, 18)], minutes: 60, now: at(2, 8), days: 1) == [at(2, 12)])
    }

    @Test func dayCoveredEntirelyIsSkipped() {
        #expect(find([DateInterval(start: at(2, 0), end: at(3, 0))], now: at(2, 8), days: 2) == [at(3, 9)])
    }

    @Test func nowRoundsUpToQuarterHour() {
        #expect(find(now: at(2, 10, 7), days: 1) == [at(2, 10, 15)])
        #expect(find(now: at(2, 10, 15), days: 1) == [at(2, 10, 15)])
        #expect(find(now: at(2, 19), days: 2) == [at(3, 9)])
    }

    @Test func gapAfterEventRoundsUpToQuarterHour() {
        #expect(find([DateInterval(start: at(2, 9), end: at(2, 10, 7))], now: at(2, 8), days: 1) == [at(2, 10, 15)])
    }

    @Test func weekendSkipped() {
        #expect(find(now: at(7, 8), days: 3) == [at(9, 9)])
    }

    @Test func gapShorterThanDurationSkipped() {
        #expect(find([busy(2, 9, 10), DateInterval(start: at(2, 10, 30), end: at(2, 18))], minutes: 60,
                     now: at(2, 8), days: 2) == [at(3, 9)])
    }

    @Test func dstDaysStartAtLocalNine() {
        let everyDay = WorkingHours(start: 9 * 60, end: 18 * 60, weekdays: Set(1...7))
        #expect(find(hours: everyDay, now: at(8, 0), days: 1) == [at(8, 9)])
        #expect(find(hours: everyDay, now: at(1, 0, month: 11), days: 1) == [at(1, 9, month: 11)])
    }

    @Test func allBusyOrInvalidGivesNothing() {
        #expect(find([DateInterval(start: at(1, 0), end: at(20, 0))], now: at(2, 8)).isEmpty)
        #expect(find(minutes: 0, now: at(2, 8)).isEmpty)
        #expect(find(hours: WorkingHours(start: 18 * 60, end: 9 * 60, weekdays: Set(1...7)), now: at(2, 8)).isEmpty)
    }

    @Test func weekdayDigitsDecode() {
        #expect(WorkingHours.weekdays(from: "23456") == Set(2...6))
        #expect(WorkingHours.weekdays(from: "") == [])
    }
}
