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
