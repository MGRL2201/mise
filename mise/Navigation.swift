import SwiftUI

/// Every screen the app can navigate to. Shared by the iOS tab/More list, the
/// Mac sidebar, and deep links (`mise://<destination>` or `.../new`).
enum Destination: String, CaseIterable, Identifiable {
    case today, tasks, calendar, money, notes, news, wakeUp = "wakeup", settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .money: "Money"
        case .notes: "Notes"
        case .news: "News"
        case .wakeUp: "Wake-up"
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
        case .wakeUp: "alarm"
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

    // The four fixed iOS tabs plus "more", which pushes notes/news/wake-up/settings.
    private enum MainTab: Hashable {
        case today, tasks, calendar, money, more
    }

    private static let moreDestinations: [Destination] = [.notes, .news, .wakeUp, .settings]

    @State private var tab: MainTab = .today
    @State private var morePath: [Destination] = []
    @State private var macSelection: Destination? = .today
    @Environment(AppLock.self) private var lock
    private let planning = PlanningPrompt.shared

    /// macOS holds sheets back while the whole app is locked (an attached sheet
    /// blocks the main window's lock overlay). iOS covers sheets with the lock window.
    private var holdSheets: Bool {
        #if os(macOS)
        lock.mode == .wholeApp && !lock.isUnlocked
        #else
        false
        #endif
    }

    var body: some View {
        root
            .sheet(isPresented: Binding { planning.isPresented && !holdSheets }
                   set: { planning.isPresented = $0 }) { PlanningView() }
            .sheet(isPresented: Binding { planning.isWeeklyReviewPresented && !holdSheets }
                   set: { planning.isWeeklyReviewPresented = $0 }) { WeeklyReviewView() }
            #if DEBUG
            .onAppear {
                if UserDefaults.standard.bool(forKey: "misePlanning") { planning.showDaily() }
                if UserDefaults.standard.bool(forKey: "miseWeeklyReview") { planning.showWeekly() }
            }
            #endif
    }

    @ViewBuilder private var root: some View {
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
            if url.isFileURL { return SharedInbox.importOpened(url) }
            guard let route = Route(url: url) else { return }
            macSelection = route.destination
        }
        #if DEBUG
        .onAppear { if let debugTab { macSelection = debugTab } }
        #endif
        #else
        TabView(selection: $tab) {
            Tab("Today", systemImage: Destination.today.systemImage, value: .today) {
                NavigationStack { detailView(for: .today) }
            }
            Tab("Tasks", systemImage: Destination.tasks.systemImage, value: .tasks) {
                NavigationStack { detailView(for: .tasks) }
            }
            Tab("Calendar", systemImage: Destination.calendar.systemImage, value: .calendar) {
                NavigationStack { detailView(for: .calendar) }
            }
            Tab("Money", systemImage: Destination.money.systemImage, value: .money) {
                NavigationStack { detailView(for: .money) }
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
                    .toolbarTitleDisplayMode(.inlineLarge)
                    .navigationDestination(for: Destination.self) { destination in
                        detailView(for: destination)
                    }
                }
            }
        }
        .onOpenURL { url in
            if url.isFileURL { return SharedInbox.importOpened(url) }
            guard let route = Route(url: url) else { return }
            select(route.destination)
        }
        #if DEBUG
        .onAppear { if let debugTab { select(debugTab) } }
        #endif
        #endif
    }

    #if DEBUG
    /// Screenshot hook: launch with `-miseTab calendar` to start on that destination.
    private var debugTab: Destination? { UserDefaults.standard.string(forKey: "miseTab").flatMap(Destination.init) }
    #endif

    private func detailView(for destination: Destination) -> some View {
        Group {
            if destination == .settings {
                SettingsView()
            } else if destination == .tasks {
                TasksView()
            } else if destination == .calendar {
                CalendarView()
            } else if destination == .wakeUp {
                WakeUpView()
            } else if destination == .money && lock.mode == .financeAndNotes && !lock.isUnlocked {
                // ponytail: Notes isn't gated; per-note lock (Phase 5, SPEC §6.5) will reuse AppLock.isUnlocked.
                LockView()
            } else {
                PlaceholderView(destination: destination)
            }
        }
        #if !os(macOS)
        // Title shares the toolbar row instead of sitting below an empty band (#131).
        .toolbarTitleDisplayMode(.inlineLarge)
        #endif
    }

    #if !os(macOS)
    private func select(_ destination: Destination) {
        switch destination {
        case .today: tab = .today
        case .tasks: tab = .tasks
        case .calendar: tab = .calendar
        case .money: tab = .money
        case .notes, .news, .wakeUp, .settings:
            tab = .more
            morePath = [destination]
        }
    }
    #endif
}
