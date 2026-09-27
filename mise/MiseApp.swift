import SwiftUI
import SwiftData
import EventKit
#if os(iOS)
import WidgetKit
#endif

@main
struct MiseApp: App {
    let container: ModelContainer
    @State private var themeStore = ThemeStore()
    @State private var appLock = AppLock()
    @State private var reminders: RemindersStore
    @State private var calendar: CalendarStore
    @Environment(\.scenePhase) private var phase

    init() {
        container = Storage.makeContainer()
        let store = EKEventStore()  // one store per app (Apple guidance)
        _reminders = State(initialValue: RemindersStore(eventStore: store, context: container.mainContext))
        _calendar = State(initialValue: CalendarStore(eventStore: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AppLockRoot())
                .modifier(ThemeRoot())
                .environment(themeStore)
                .environment(appLock)
                .environment(reminders)
                .environment(calendar)
                .onChange(of: phase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        AutoBackup.run(context: container.mainContext)
                        #if os(iOS)
                        Self.recordSpikeLaunch()
                        #endif
                    #if os(iOS)
                    case .background: AutoBackup.scheduleRefresh()
                    #endif
                    default: break
                    }
                }
        }
        .modelContainer(container)
        #if os(iOS)
        .backgroundTask(.appRefresh(AutoBackup.taskID)) { [container] in
            await MainActor.run {
                AutoBackup.run(context: container.mainContext)
                AutoBackup.scheduleRefresh()
            }
        }
        #endif
    }

    #if os(iOS)
    // ponytail: spike write for #10/#11; replace with real widget snapshot later
    /// Spike #10: the widget shows these to prove App Group + shared keychain work.
    /// Spike #11: asks for calendar access once so the widget can read EventKit.
    private static func recordSpikeLaunch() {
        let now = Date.now.formatted(date: .abbreviated, time: .standard)
        SharedStore.defaults?.set(now, forKey: "spike.lastLaunch")
        SharedStore.setSecret(now, for: "spike.lastLaunch")
        WidgetCenter.shared.reloadAllTimelines()
        // Spike #11: the widget reads EventKit directly; the grant is per app.
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        Task {
            _ = try? await EKEventStore().requestFullAccessToEvents()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    #endif
}
