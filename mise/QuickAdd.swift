import Foundation
import FoundationModels
@preconcurrency import EventKit

/// Deterministic parse of a one-line task ("pay rent every 1st 9am !high") into reminder fields.
/// Relative words resolve against `now` here; NSDataDetector only sees the leftovers for absolute dates.
struct QuickAdd: Equatable {
    var title: String
    var due: DateComponents?          // nil = no due; hour/minute nil = all-day
    var recurrence = RecurrencePreset.none
    var priority = 0                  // EventKit raw: 1 high, 5 medium, 9 low, 0 none
    var listName: String?             // exact title of the matched list
    var unknownList: String?          // first `#name` that matched no list, as typed

    private static let priorities = ["!high": 1, "!!!": 1, "!med": 5, "!medium": 5, "!!": 5, "!low": 9, "!": 9]
    private static let recurrenceWords: [String: RecurrencePreset] = [
        "daily": .daily, "weekdays": .weekdays, "weekly": .weekly, "biweekly": .biweekly,
        "monthly": .monthly, "yearly": .yearly, "annually": .yearly,
    ]
    private static let everyWords: [String: RecurrencePreset] = [
        "day": .daily, "weekday": .weekdays, "week": .weekly, "month": .monthly, "year": .yearly,
    ]
    // Model priority/recurrence only count when the raw text has one of these whole words.
    private static let priorityCues: Set = ["urgent", "urgently", "asap", "important", "critical", "crucial", "priority"]
    private static let recurrenceCues: Set = [
        "every", "each", "repeat", "repeats", "repeating", "recurring", "daily", "nightly", "weekly",
        "weekdays", "biweekly", "fortnightly", "monthly", "yearly", "annually",
    ]
    private static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Callers must skip empty/whitespace-only input: the resulting title would be empty.
    static func parse(_ text: String, lists: [String], now: Date, calendar: Calendar = .current) -> QuickAdd {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let lower = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;")) }
        let today = calendar.startOfDay(for: now)
        var result = QuickAdd(title: "")
        var kept: [String] = []
        var tags: Set<String> = []  // consumed `#list` tokens, kept out of the title fallback too
        var day: Date?
        var time: (hour: Int, minute: Int)?
        var tonight = false
        var monthDay: Int?
        var byWeekday = false

        func upcoming(_ weekday: Int, strictlyAfter: Bool) -> Date? {
            var offset = (weekday - calendar.component(.weekday, from: today) + 7) % 7
            if strictlyAfter && offset == 0 { offset = 7 }
            return calendar.date(byAdding: .day, value: offset, to: today)
        }

        var i = 0
        while i < lower.count {
            let w = lower[i]
            let next = i + 1 < lower.count ? lower[i + 1] : ""
            let afterNext = i + 2 < lower.count ? lower[i + 2] : ""
            if let p = priorities[w] {
                result.priority = p
            } else if w.hasPrefix("#"), w.contains(where: \.isLetter) {  // "#1" stays in the title
                if let list = lists.first(where: { $0.replacingOccurrences(of: " ", with: "").lowercased() == w.dropFirst() }) {
                    result.listName = list
                } else if result.unknownList == nil {
                    result.unknownList = String(words[i].trimmingCharacters(in: CharacterSet(charactersIn: ",.;")).dropFirst())
                }
                tags.insert(words[i])
            } else if let r = recurrenceWords[w] {
                result.recurrence = r
            } else if w == "every", let r = everyWords[next] {
                result.recurrence = r
                i += 1
            } else if w == "every", [next, afterNext] == ["other", "week"] || [next, afterNext] == ["2", "weeks"] {
                result.recurrence = .biweekly
                i += 2
            } else if w == "every", let weekday = weekday(next) {
                result.recurrence = .weekly
                day = upcoming(weekday, strictlyAfter: false)
                byWeekday = true
                i += 1
            } else if w == "every", let n = ordinal(next) {
                result.recurrence = .monthly
                monthDay = n
                i += 1
            } else if w == "today" || w == "tonight" {
                day = today
                tonight = w == "tonight"
            } else if w == "tomorrow" {
                day = calendar.date(byAdding: .day, value: 1, to: today)
            } else if w == "in", let n = Int(next), (1...3650).contains(n),
                      let unit = ["day": 1, "days": 1, "week": 7, "weeks": 7][afterNext] {
                day = calendar.date(byAdding: .day, value: n * unit, to: today)
                i += 2
            } else if w == "on" || w == "next", let weekday = weekday(next) {
                day = upcoming(weekday, strictlyAfter: w == "next")
                byWeekday = true
                i += 1
            } else if let weekday = weekday(w) {
                day = upcoming(weekday, strictlyAfter: false)
                byWeekday = true
            } else if w == "at", let t = parseTime(next) {
                time = t
                i += 1
            } else if let t = parseTime(w) {
                time = t
            } else {
                kept.append(words[i])
            }
            i += 1
        }

        if tonight && time == nil { time = (20, 0) }
        func at(_ date: Date) -> Date {
            time.flatMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: date) } ?? date
        }
        if let d = day, byWeekday, d == today, time != nil, at(d) <= now {
            day = calendar.date(byAdding: .day, value: 7, to: d)
        }
        if let n = monthDay {
            // .strict skips months lacking day N (e.g. the 31st); without a time, today counts.
            let match = DateComponents(day: n, hour: time?.hour, minute: time?.minute, second: time == nil ? nil : 0)
            day = calendar.nextDate(after: (time == nil ? today : now).addingTimeInterval(-1), matching: match, matchingPolicy: .strict)
        }

        var title = kept.joined(separator: " ")
        if day == nil,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let date = match.date, let range = Range(match.range, in: title) {
            var detected = Calendar(identifier: .gregorian)
            detected.timeZone = match.timeZone ?? .current
            // ponytail: time inside the detector match ("oct 5 at 7") is dropped unless given as a separate time token; upgrade: take hour/minute from the match when no time was parsed.
            day = calendar.date(from: detected.dateComponents([.year, .month, .day], from: date))
            title.removeSubrange(range)
            title = title.split(separator: " ").joined(separator: " ")
        }

        if day == nil, time != nil {
            day = at(today) > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        if day == nil, result.recurrence != .none { day = today }  // EventKit requires a due date for recurrence
        if result.recurrence == .weekdays, let d = day {  // Sat/Sun -> next Monday
            let wd = calendar.component(.weekday, from: d)
            if wd == 1 || wd == 7 { day = calendar.date(byAdding: .day, value: (9 - wd) % 7, to: d) }
        }
        if let day {
            var due = calendar.dateComponents([.year, .month, .day], from: day)
            if let time { due.hour = time.hour; due.minute = time.minute }
            result.due = due
        }
        result.title = title.isEmpty ? words.filter { !tags.contains($0) }.joined(separator: " ") : title
        return result
    }

    /// Closest list for a mistyped `#name`: case/space-insensitive equal, prefix (3+ chars), or a small typo.
    static func closeMatch(_ name: String, in lists: [String]) -> String? {
        func normalized(_ s: String) -> [Character] { Array(s.lowercased().filter { !$0.isWhitespace }) }
        let n = normalized(name)
        let limit = n.count <= 4 ? 1 : 2
        var best: (list: String, distance: Int)?
        for list in lists {
            let l = normalized(list)
            let d = n.count >= 3 && l.starts(with: n) ? 0 : levenshtein(n, l)
            if d <= limit, d < best?.distance ?? .max { best = (list, d) }
        }
        return best?.list
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// Calendar weekday (1 = Sunday) for a full or 3-letter name.
    private static func weekday(_ word: String) -> Int? {
        weekdayNames.firstIndex { $0 == word || $0.prefix(3) == word }.map { $0 + 1 }
    }

    private static func ordinal(_ word: String) -> Int? {
        guard let m = word.wholeMatch(of: #/(\d{1,2})(st|nd|rd|th)/#), let n = Int(m.1), (1...31).contains(n) else { return nil }
        return n
    }

    /// "9am", "9:30pm", "18:00", "noon"; a bare number is not a time.
    private static func parseTime(_ word: String) -> (hour: Int, minute: Int)? {
        if word == "noon" { return (12, 0) }
        guard let m = word.wholeMatch(of: #/(\d{1,2})(?::(\d{2}))?(am|pm)?/#), m.2 != nil || m.3 != nil,
              var hour = Int(m.1), let minute = Int(m.2 ?? "0"), minute < 60 else { return nil }
        if let suffix = m.3 {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (suffix == "pm" ? 12 : 0)
        }
        return hour < 24 ? (hour, minute) : nil
    }

    /// Fills gaps from the model when `text` has a cue word; deterministic fields always win. Pure, so testable without the model.
    func merging(_ f: QuickTaskFields, text: String, today: DateComponents) -> QuickAdd {
        var result = self
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        let title = f.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title.lowercased() != "nil" { result.title = title }
        if priority == 0, !words.isDisjoint(with: Self.priorityCues), let p = f.priority {
            result.priority = switch p { case .high: 1; case .medium: 5; case .low: 9 }
        }
        if recurrence == .none, !words.isDisjoint(with: Self.recurrenceCues), let r = f.recurrence {
            result.recurrence = switch r {
            case .daily: .daily
            case .weekdays: .weekdays
            case .weekly: .weekly
            case .biweekly: .biweekly
            case .monthly: .monthly
            case .yearly: .yearly
            }
            if due == nil { result.due = today }  // EventKit requires a due date for recurrence
        }
        return result
    }

    /// `parse`, then the on-device model tidies the title and fills priority/recurrence the markers missed.
    /// Any model failure (unavailable, guardrail, simulator error 1026) returns the deterministic result.
    static func parseSmart(_ text: String, lists: [String], now: Date = .now) async -> QuickAdd {
        let plain = parse(text, lists: lists, now: now)
        // Empty title (input was only a `#list`): nothing for the model to tidy, and it would invent one.
        guard OnDeviceAI.unavailableReason == nil, !plain.title.isEmpty else { return plain }
        let session = LanguageModelSession(instructions: """
            Extract a to-do item from a personal organizer app. \
            Only fill priority or recurrence when the text clearly says so.
            """)
        // The deterministic title is already stripped of markers and dates (also avoids a "!high" guardrail false positive).
        guard let fields = try? await session.respond(to: plain.title, generating: QuickTaskFields.self).content else { return plain }
        return plain.merging(fields, text: text, today: Calendar.current.dateComponents([.year, .month, .day], from: now))
    }

    func apply(to reminder: EKReminder, lists: [EKCalendar]) {
        reminder.title = title
        reminder.priority = priority
        reminder.dueDateComponents = due
        reminder.recurrenceRules = due == nil ? nil : recurrence.rule.map { [$0] }
        if due?.hour != nil, (reminder.alarms ?? []).isEmpty {
            reminder.alarms = [EKAlarm(relativeOffset: 0)]  // timed tasks notify at due, like Reminders.app
        }
        if let list = lists.first(where: { $0.title == listName }) {
            reminder.calendar = list
        }
    }
}

/// Model output for quick add. No date field: model dates are unreliable, so dates stay in `QuickAdd.parse`.
@Generable
struct QuickTaskFields {
    @Generable
    enum Priority { case high, medium, low }
    @Generable
    enum Repeat { case daily, weekdays, weekly, biweekly, monthly, yearly }

    @Guide(description: "Short task title, without dates, times, recurrence or priority words")
    var title: String
    @Guide(description: "Only if the text says it is urgent, important, low priority or similar")
    var priority: Priority?
    @Guide(description: "Only if the text says it repeats")
    var recurrence: Repeat?
}
