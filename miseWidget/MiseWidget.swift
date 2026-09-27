import SwiftUI
import WidgetKit

/// Spike #10: shows what the app wrote to the App Group and shared keychain.
nonisolated struct SpikeEntry: TimelineEntry {
    let date: Date
    let group: String
    let keychain: String
}

nonisolated struct SpikeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpikeEntry {
        SpikeEntry(date: .now, group: "…", keychain: "…")
    }

    func getSnapshot(in context: Context, completion: @escaping (SpikeEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpikeEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> SpikeEntry {
        let group = SharedStore.defaults.map { $0.string(forKey: "spike.lastLaunch") ?? "empty" }
        let (value, status) = SharedStore.secret("spike.lastLaunch")
        return SpikeEntry(date: .now, group: group ?? "no container", keychain: value ?? "OSStatus \(status)")
    }
}

@main
struct MiseSpikeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "miseSpike", provider: SpikeProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                Text("Group: \(entry.group)")
                Text("Keychain: \(entry.keychain)")
            }
            .font(.caption)
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("mise spike")
        .supportedFamilies([.systemSmall])
    }
}
