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

struct ContentView: View {
    static let title = "mise"

    var body: some View {
        Text(Self.title)
    }
}
