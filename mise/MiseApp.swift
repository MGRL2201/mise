import SwiftUI
import SwiftData

@main
struct MiseApp: App {
    let container = Storage.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
