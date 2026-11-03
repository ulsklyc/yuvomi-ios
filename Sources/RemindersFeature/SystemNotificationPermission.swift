@preconcurrency import UserNotifications

/// Setzt `NotificationPermission` mit dem Notification Center um. Ohne vorläufige Erlaubnis:
/// Sie stellt die ersten Mitteilungen still zu, das passt nicht zu Erinnerungen.
public struct SystemNotificationPermission: NotificationPermission {
    public init() {}

    public func current() async -> NotificationPermissionStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        // Vorläufig erlaubt stellt still zu. Für Erinnerungen zählt das wie nicht gefragt,
        // die Karte holt dann die volle Erlaubnis.
        case .notDetermined, .provisional: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    public func request() async -> NotificationPermissionStatus {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await current()
    }
}
