import Testing
import Foundation
@testable import mise

// Opt-in: TEST_RUNNER_MISE_FM_SPIKE=1 xcodebuild test ... -only-testing:miseTests/FoundationModelsSpikeTests
@MainActor
struct FoundationModelsSpikeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MISE_FM_SPIKE"] != nil))
    func quickCaptureSamples() async throws {
        if let reason = OnDeviceAI.unavailableReason {
            Attachment.record("unavailable: \(reason)", named: "fm_spike.txt")
            return
        }
        // Fixed "now": Sunday 2026-09-27 10:00 local.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10))!
        let samples: [(String, String, (QuickCapture) -> Bool)] = [
            ("Coffee 5.50", "expense 5.5", { $0.kind == .expense && $0.amount == 5.5 }),
            ("call mom tomorrow 6pm", "task due 2026-09-28T18:00",
             { $0.kind == .task && $0.due?.hasPrefix("2026-09-28T18:00") == true }),
            ("Uber to airport 32.40 EUR", "expense 32.4 EUR",
             { $0.kind == .expense && $0.amount == 32.4 && $0.currency == "EUR" }),
            ("pay rent every 1st 9am !high", "task", { $0.kind == .task }),
            ("Ideas for the garden: tomatoes, basil, a small bench", "note", { $0.kind == .note }),
            ("Lunch with Sam at Nando's £18.20", "expense 18.2 GBP Nando's",
             { $0.kind == .expense && $0.amount == 18.2 && $0.currency == "GBP" && $0.merchant == "Nando's" }),
            ("Dentist appointment next Tuesday 3:30pm", "task", { $0.kind == .task }),
            ("Book club notes — chapter 4 was slow but the ending surprised me", "note", { $0.kind == .note }),
            ("TRADER JOE'S #123 ... SUBTOTAL 41.17 TAX 3.29 TOTAL 44.46 VISA 09/14/2026",
             "expense 44.46 Trader Joe's",
             { $0.kind == .expense && $0.amount == 44.46
                 && $0.merchant?.lowercased().hasPrefix("trader joe") == true }),
            ("Netflix subscription 15.49 monthly", "expense 15.49", { $0.kind == .expense && $0.amount == 15.49 }),
        ]
        var lines = ["input | expected | got | ok? | ms"]
        var kindOK = 0, allOK = 0
        var times: [Int] = []
        let kinds: [QuickCapture.Kind] = [.expense, .task, .expense, .task, .note, .expense, .task, .note, .expense, .expense]
        for (i, (input, expected, check)) in samples.enumerated() {
            let clock = ContinuousClock()
            let start = clock.now
            let got: String, ok: Bool
            do {
                let c = try await QuickCapture.parse(input, now: now)
                got = "\(c.kind) '\(c.title)' amt=\(c.amount.map { "\($0)" } ?? "-") cur=\(c.currency ?? "-") "
                    + "merch=\(c.merchant ?? "-") cat=\(c.category ?? "-") due=\(c.due ?? "-")"
                ok = check(c)
                if c.kind == kinds[i] { kindOK += 1 }
            } catch {
                got = "ERROR \(error)"
                ok = false
            }
            let ms = Int((clock.now - start) / .milliseconds(1))
            times.append(ms)
            if ok { allOK += 1 }
            lines.append("\(input) | \(expected) | \(got) | \(ok ? "yes" : "NO") | \(ms)")
        }
        times.sort()
        lines.append("kind \(kindOK)/10, full \(allOK)/10, median \((times[4] + times[5]) / 2) ms, max \(times[9]) ms")
        Attachment.record(lines.joined(separator: "\n"), named: "fm_spike.txt")
    }
}
