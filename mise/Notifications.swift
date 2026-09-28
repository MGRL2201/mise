import UserNotifications

/// Local notification permission, shared by every feature that schedules notifications.
enum LocalNotifications {
    /// Asks once when undetermined (only if `prompt`), then reports whether alerts may be shown.
    static func authorized(prompt: Bool = true) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, prompt {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return status == .authorized || status == .provisional
    }
}

extension LocalNotifications {
    /// Swaps the pending requests whose identifier starts with `prefix` for `requests` (empty removes them).
    static func replace(prefix: String, with requests: [UNNotificationRequest]) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for request in requests { try? await center.add(request) }
    }
}

/// Notification taps and foreground presentation. Set as the center's delegate in `MiseApp.init`
/// so a tap that cold-launches the app is still delivered.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        if id.hasPrefix(DailyPlanning.identifier) {
            await MainActor.run { PlanningPrompt.shared.showDaily() }
        } else if id.hasPrefix(WeeklyReview.identifier) {
            await MainActor.run { PlanningPrompt.shared.showWeekly() }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
