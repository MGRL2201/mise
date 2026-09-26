import SwiftUI

@main
struct MiseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    static let title = "mise"

    var body: some View {
        Text(Self.title)
    }
}
