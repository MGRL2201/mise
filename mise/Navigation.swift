import SwiftUI

/// Every screen the app can navigate to. Shared by the iOS tab/More list, the
/// Mac sidebar, and deep links (`mise://<destination>` or `.../new`).
enum Destination: String, CaseIterable, Identifiable {
    case today, tasks, calendar, money, notes, news, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .money: "Money"
        case .notes: "Notes"
        case .news: "News"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .tasks: "checklist"
        case .calendar: "calendar"
        case .money: "dollarsign.circle"
        case .notes: "note.text"
        case .news: "newspaper"
        case .settings: "gear"
        }
    }
}

/// A parsed deep link, e.g. `mise://tasks` (show) or `mise://tasks/new`
/// (jump to destination and start a new item — quick-add UI comes later).
enum Route: Equatable {
    case show(Destination)
    case new(Destination)

    init?(url: URL) {
        guard url.scheme == "mise", let host = url.host,
            let destination = Destination(rawValue: host)
        else { return nil }

        switch url.path {
        case "", "/": self = .show(destination)
        case "/new": self = .new(destination)
        default: return nil
        }
    }

    var destination: Destination {
        switch self {
        case .show(let destination), .new(let destination): destination
        }
    }
}

/// Placeholder body for every destination until its real screen lands.
struct PlaceholderView: View {
    let destination: Destination

    var body: some View {
        ContentUnavailableView {
            DestinationLabel(destination: destination)
        }
        .navigationTitle(destination.title)
        .themedBackground()
    }
}

struct ContentView: View {
    static let title = "mise"

    // The four fixed iOS tabs plus "more", which pushes notes/news/settings.
    private enum MainTab: Hashable {
        case today, tasks, calendar, money, more
    }

    private static let moreDestinations: [Destination] = [.notes, .news, .settings]

    @State private var tab: MainTab = .today
    @State private var morePath: [Destination] = []
    @State private var macSelection: Destination? = .today

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(Destination.allCases, selection: $macSelection) { destination in
                DestinationLabel(destination: destination)
                    .tag(destination)
            }
            .navigationTitle(Self.title)
        } detail: {
            if let macSelection {
                detailView(for: macSelection)
            } else {
                ContentUnavailableView("Select a destination", systemImage: "sidebar.left")
            }
        }
        .onOpenURL { url in
            guard let route = Route(url: url) else { return }
            macSelection = route.destination
        }
        #else
        TabView(selection: $tab) {
            Tab("Today", systemImage: Destination.today.systemImage, value: .today) {
                NavigationStack { PlaceholderView(destination: .today) }
            }
            Tab("Tasks", systemImage: Destination.tasks.systemImage, value: .tasks) {
                NavigationStack { PlaceholderView(destination: .tasks) }
            }
            Tab("Calendar", systemImage: Destination.calendar.systemImage, value: .calendar) {
                NavigationStack { PlaceholderView(destination: .calendar) }
            }
            Tab("Money", systemImage: Destination.money.systemImage, value: .money) {
                NavigationStack { PlaceholderView(destination: .money) }
            }
            Tab("More", systemImage: "ellipsis", value: .more) {
                NavigationStack(path: $morePath) {
                    List(Self.moreDestinations) { destination in
                        NavigationLink(value: destination) {
                            DestinationLabel(destination: destination)
                        }
                    }
                    .navigationTitle("More")
                    .themedBackground()
                    .navigationDestination(for: Destination.self) { destination in
                        detailView(for: destination)
                    }
                }
            }
        }
        .onOpenURL { url in
            guard let route = Route(url: url) else { return }
            select(route.destination)
        }
        #endif
    }

    @ViewBuilder
    private func detailView(for destination: Destination) -> some View {
        if destination == .settings {
            SettingsView()
        } else {
            PlaceholderView(destination: destination)
        }
    }

    #if !os(macOS)
    private func select(_ destination: Destination) {
        switch destination {
        case .today: tab = .today
        case .tasks: tab = .tasks
        case .calendar: tab = .calendar
        case .money: tab = .money
        case .notes, .news, .settings:
            tab = .more
            morePath = [destination]
        }
    }
    #endif
}
