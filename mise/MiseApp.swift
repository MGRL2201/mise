import SwiftUI
import SwiftData

@main
struct MiseApp: App {
    let container = Storage.makeContainer()
    @State private var themeStore = ThemeStore()
    @State private var appLock = AppLock()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AppLockRoot())
                .modifier(ThemeRoot())
                .environment(themeStore)
                .environment(appLock)
                .onChange(of: phase, initial: true) { _, phase in
                    switch phase {
                    case .active: AutoBackup.run(context: container.mainContext)
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
}
