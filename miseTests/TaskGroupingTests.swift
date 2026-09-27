import Testing
import Foundation
@testable import mise

@MainActor
struct TaskGroupingTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    // 2026-03-10 15:00 local
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15))! }

    private func bucket(_ components: DateComponents?) -> TaskGrouping.DueBucket? {
        TaskGrouping.dueBucket(components, now: now, calendar: calendar)
    }

    @Test func dueBuckets() {
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 10, hour: 9)) == .overdue)
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 10, hour: 18)) == .today)
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 10)) == .today)
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 9)) == .overdue)
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 11)) == .upcoming)
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 17, hour: 23)) == .upcoming)
        #expect(bucket(DateComponents(year: 2026, month: 3, day: 18)) == nil)
        #expect(bucket(nil) == nil)
    }

    @Test func dayGroupsSortAscendingAndDropNil() {
        let day = { (d: Int, h: Int) in calendar.date(from: DateComponents(year: 2026, month: 3, day: d, hour: h))! }
        let items: [(String, Date?)] = [("b", day(12, 9)), ("a", day(11, 20)), ("x", nil), ("c", day(12, 8))]
        let groups = TaskGrouping.dayGroups(items, calendar: calendar) { $0.1 }
        #expect(groups.map(\.day) == [day(11, 0), day(12, 0)])
        #expect(groups.map { $0.items.map(\.0) } == [["a"], ["b", "c"]])
    }

    @Test func priorityBuckets() {
        #expect([0, 1, 4, 5, 6, 9].map(TaskGrouping.priorityBucket) == [.none, .high, .high, .medium, .low, .low])
    }
}
