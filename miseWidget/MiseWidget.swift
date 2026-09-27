import AppIntents
import EventKit
import SwiftUI
import WidgetKit

// ponytail: spike #10/#11 widget; replace with real Today/Tasks widgets later
/// Spike #10: shows what the app wrote to the App Group and shared keychain.
/// Spike #11: interactive tap counter + direct EventKit read.
nonisolated struct SpikeEntry: TimelineEntry {
    let date: Date
    let group: String
    let keychain: String
    let taps: Int
    let events: String
}

/// Spike #11: runs in the widget process; proves `Button(intent:)` works.
nonisolated struct SpikeTapIntent: AppIntent {
    static let title: LocalizedStringResource = "Tap"

    func perform() async throws -> some IntentResult {
        let defaults = SharedStore.defaults
        defaults?.set((defaults?.integer(forKey: "spike.taps") ?? 0) + 1, forKey: "spike.taps")
        return .result()
    }
}

nonisolated struct SpikeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpikeEntry {
        SpikeEntry(date: .now, group: "…", keychain: "…", taps: 0, events: "…")
    }

    func getSnapshot(in context: Context, completion: @escaping (SpikeEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpikeEntry>) -> Void) {
        // ponytail: fixed 15 min refresh; use EKEventStoreChanged + next event date later
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func entry() -> SpikeEntry {
        let group = SharedStore.defaults.map { $0.string(forKey: "spike.lastLaunch") ?? "empty" }
        let (value, status) = SharedStore.secret("spike.lastLaunch")
        return SpikeEntry(
            date: .now,
            group: group ?? "no container",
            keychain: value ?? "OSStatus \(status)",
            taps: SharedStore.defaults?.integer(forKey: "spike.taps") ?? 0,
            events: events()
        )
    }

    private func events() -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            let name = switch status {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .writeOnly: "writeOnly"
            default: "raw \(status.rawValue)"
            }
            return "EventKit: \(name)"
        }
        let store = EKEventStore()
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let today = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        let next = today.filter { $0.endDate > .now }.min { $0.startDate < $1.startDate }
        return "Today: \(today.count), next: \(next?.title ?? "none")"
    }
}

@main
struct MiseSpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "miseSpike", provider: SpikeProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text("Group: \(entry.group)")
                Text("Keychain: \(entry.keychain)")
                Text(entry.events)
                HStack {
                    Text("Taps: \(entry.taps)")
                    Button("Tap", intent: SpikeTapIntent())
                }
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("mise spike")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
