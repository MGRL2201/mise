import SwiftUI
import SwiftData

@main
struct MiseApp: App {
    let container = Storage.makeContainer()
    @State private var themeStore = ThemeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ThemeRoot())
                .environment(themeStore)
        }
        .modelContainer(container)
    }
}
