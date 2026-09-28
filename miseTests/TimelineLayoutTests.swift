import Testing
import Foundation
@testable import mise

@MainActor
struct TimelineLayoutTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }
    private var dayStart: Date { at(10, 0) }
    private let h = TimelineLayout.hourHeight

    private func y(_ date: Date) -> CGFloat { TimelineLayout.y(for: date, dayStart: dayStart, calendar: calendar) }
    private func slots(_ hours: [(Int, Int)]) -> [TimelineLayout.Slot] {
        TimelineLayout.slots(for: hours.map { (start: at(10, $0.0), end: at(10, $0.1)) })
    }
    private func slot(_ column: Int, _ count: Int) -> TimelineLayout.Slot { .init(column: column, columnCount: count) }

    @Test func yOffsets() {
        #expect(y(dayStart) == 0)
        #expect(y(at(10, 9, 30)) == 9.5 * h)
        #expect(y(at(11, 0)) == 24 * h)
        #expect(y(at(9, 22)) == 0)
        #expect(y(at(11, 5)) == 24 * h)
    }

    @Test func dateForYRoundTrips() {
        let date = at(10, 9, 30)
        #expect(TimelineLayout.date(forY: y(date), dayStart: dayStart, calendar: calendar) == date)
        #expect(TimelineLayout.date(forY: -10, dayStart: dayStart, calendar: calendar) == dayStart)
        #expect(TimelineLayout.date(forY: 30 * h, dayStart: dayStart, calendar: calendar) == at(11, 0))
    }

    @Test func slotStartRoundsDownToHalfHour() {
        let start = { TimelineLayout.slotStart(forY: $0, dayStart: dayStart, calendar: calendar) }
        #expect(start(9.9 * h) == at(10, 9, 30))
        #expect(start(9.4 * h) == at(10, 9))
        #expect(start(0) == dayStart)
        #expect(start(24 * h) == at(10, 23, 30))
    }

    @Test func slotsEmptyAndSingle() {
        #expect(slots([]) == [])
        #expect(slots([(9, 10)]) == [slot(0, 1)])
    }

    @Test func overlappingShareColumns() {
        #expect(slots([(9, 11), (10, 12)]) == [slot(0, 2), slot(1, 2)])
    }

    @Test func touchingDoNotOverlap() {
        #expect(slots([(9, 10), (10, 11)]) == [slot(0, 1), slot(0, 1)])
    }

    @Test func clusterReusesFreedColumn() {
        #expect(slots([(9, 12), (9, 10), (10, 11)]) == [slot(0, 2), slot(1, 2), slot(1, 2)])
    }

    @Test func separateClustersCountIndependently() {
        #expect(slots([(9, 11), (10, 12), (13, 14)]) == [slot(0, 2), slot(1, 2), slot(0, 1)])
    }

    @Test func inputOrderPreserved() {
        #expect(slots([(10, 11), (13, 14), (9, 12)]) == [slot(1, 2), slot(0, 1), slot(0, 2)])
    }

    @Test func zeroLengthGetsColumn() {
        #expect(slots([(9, 9), (9, 10)]) == [slot(1, 2), slot(0, 2)])
    }
}
