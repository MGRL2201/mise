import Foundation
@preconcurrency import EventKit
import MapKit
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// Travel time to events with a picked place, and a "Leave now" notification per occurrence (#28).
// ponytail: only events in the next 24h, and ETAs only refresh when the app opens, events change, or iOS runs
// background refresh (from the last known location), so traffic changes in between are missed;
// a server push or live location would fix that.
enum TravelTime {
    static let transportKey = "travel.transport"
    static let bufferKey = "travel.buffer"
    static let taskID = "\(Bundle.main.bundleIdentifier ?? "mise").leavenow"
    private static let prefix = "leave-now|"
    private static let window: TimeInterval = 86_400
    private static var last: Task<Void, Never>?

    enum Transport: String, CaseIterable {
        case driving, transit, walking

        var title: String { rawValue.capitalized }
        var phrase: String {
            switch self {
            case .driving: "by car"
            case .transit: "by transit"
            case .walking: "on foot"
            }
        }
        var type: MKDirectionsTransportType {
            switch self {
            case .driving: .automobile
            case .transit: .transit
            case .walking: .walking
            }
        }
    }

    static var transport: Transport {
        UserDefaults.standard.string(forKey: transportKey).flatMap(Transport.init) ?? .driving
    }
    static var bufferMinutes: Int { UserDefaults.standard.object(forKey: bufferKey) as? Int ?? 10 }

    /// When to say "leave now", or nil if that's already past.
    static func fireDate(start: Date, eta: TimeInterval, bufferMinutes: Int, now: Date) -> Date? {
        let fire = start.addingTimeInterval(-eta - TimeInterval(bufferMinutes * 60))
        return fire > now ? fire : nil
    }

    /// Timed events with a picked place, starting within the next 24h.
    static func candidates(_ events: [EKEvent], now: Date) -> [EKEvent] {
        events.filter {
            !$0.isAllDay && $0.structuredLocation?.geoLocation != nil
                && $0.startDate > now && $0.startDate.timeIntervalSince(now) <= window
        }
    }

    static func identifier(_ event: EKEvent) -> String { prefix + event.rowID }

    static func describe(_ eta: TimeInterval) -> String {
        "\(Int((eta / 60).rounded())) min \(transport.phrase)"
    }

    /// From the last known location (background-safe), else the current one; nil when unavailable (no permission, no route, offline).
    static func eta(to event: EKEvent) async -> TimeInterval? {
        guard let place = event.structuredLocation?.geoLocation else { return nil }
        let request = MKDirections.Request()
        request.source = LocationPermission.shared.lastLocation.map { MKMapItem(location: $0, address: nil) } ?? .forCurrentLocation()
        request.destination = MKMapItem(location: place, address: nil)
        request.transportType = transport.type
        return try? await MKDirections(request: request).calculateETA().expectedTravelTime
    }

    /// Syncs pending "Leave now" notifications with the next 24h of events. `prompt: false` never asks for permission.
    /// Serialized, so a slow earlier run can't re-add an alert a later run removed.
    static func refresh(store: CalendarStore, prompt: Bool) async {
        let prev = last
        let task = Task { await prev?.value; await sync(store: store, prompt: prompt) }
        last = task
        await task.value
    }

    private static func sync(store: CalendarStore, prompt: Bool) async {
        let now = Date.now
        // No calendar access: empty list, so stale alerts are still removed below.
        let events = store.hasAccess ? candidates(store.events(in: DateInterval(start: now, duration: window)), now: now) : []
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        var keep = Set<String>()
        // Without permission nothing is kept, so stale alerts are removed below.
        if !events.isEmpty, await LocalNotifications.authorized(prompt: prompt),
           await LocationPermission.shared.allowed(prompt: prompt) {
            for event in events {
                let id = identifier(event)
                // A failed lookup keeps the existing notification rather than dropping it.
                guard let eta = await eta(to: event) else { keep.insert(id); continue }
                guard let fire = fireDate(start: event.startDate, eta: eta, bufferMinutes: bufferMinutes, now: .now) else { continue }
                keep.insert(id)
                let content = UNMutableNotificationContent()
                content.title = "Leave now for \(event.title ?? "event")"
                let place = event.structuredLocation?.title ?? event.location ?? ""
                content.body = describe(eta) + (place.isEmpty ? "" : " to \(place)")
                content.sound = .default
                let parts = Calendar.current.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second], from: fire)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { !keep.contains($0) })
    }

    #if os(iOS)
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = .now.addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}

/// When-in-use location permission. Only prompt from foreground UI; background callers pass `prompt: false`.
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Last known fix; kept warm by `allowed(prompt: true)` so background refresh has a source.
    var lastLocation: CLLocation? { manager.location }

    func allowed(prompt: Bool) async -> Bool {
        if prompt, manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
            }
        }
        let allowed = ![.notDetermined, .denied, .restricted].contains(manager.authorizationStatus)  // macOS lacks .authorizedWhenInUse
        if allowed, prompt { manager.requestLocation() }
        return allowed
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }
}
