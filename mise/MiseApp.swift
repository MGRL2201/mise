import SwiftUI
import SwiftData

@main
struct MiseApp: App {
    let container = Storage.makeContainer()
    @State private var themeStore = ThemeStore()
    @State private var appLock = AppLock()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(AppLockRoot())
                .modifier(ThemeRoot())
                .environment(themeStore)
                .environment(appLock)
        }
        .modelContainer(container)
    }
}
