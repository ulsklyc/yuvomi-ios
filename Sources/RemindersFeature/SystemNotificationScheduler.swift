import Foundation
@preconcurrency import UserNotifications
import YuvomiCore

/// Setzt `NotificationScheduling` mit dem Notification Center von iOS um.
///
/// Hält das Center nicht fest, sondern holt es je Aufruf: `UNUserNotificationCenter` ist nicht
/// `Sendable`, der Planer soll es aber sein. Die UN-Typen verlassen dieses Modul nicht.
public struct SystemNotificationScheduler: NotificationScheduling {
    public init() {}

    public func pending() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
    }

    public func delivered() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier))
    }

    public func plan(_ notifications: [PlannedNotification]) async {
        let center = UNUserNotificationCenter.current()
        for notification in notifications {
            // Der Abgleich prüft den Vorlauf vor dem Abruf. Nach einem langsamen Abruf kann
            // ein Zeitpunkt schon vorbei sein, und ein vergangener Trigger feuert nie. Eine
            // Sekunde Luft für den Weg zum System.
            guard notification.firesAt.timeIntervalSinceNow >= 1 else { continue }
            // Ein Fehler hier betrifft eine Mitteilung, der nächste Abgleich versucht es neu.
            try? await center.add(Self.request(for: notification))
        }
    }

    public func remove(_ ids: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Array(ids))
        center.removeDeliveredNotifications(withIdentifiers: Array(ids))
    }

    /// Die Anfrage für eine Mitteilung: Kalender-Trigger mit allen Komponenten in UTC, damit
    /// sie auch nach einem Wechsel der Zeitzone zum selben Zeitpunkt feuert. Kein
    /// Intervall-Trigger: Ein Intervall ≤ 0 lässt `UNTimeIntervalNotificationTrigger` abstürzen.
    /// `locale:` in `String(localized:)` wählt nur die Formatierung, nicht die Sprache. Die
    /// Sprache kommt aus dem passenden `.lproj`, sonst bleibt die Wahl von iOS.
    private static func localizedBundle(for locale: Locale) -> Bundle {
        guard let language = locale.language.languageCode?.identifier,
              let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return .module }
        return bundle
    }

    static func request(for notification: PlannedNotification, locale: Locale = .current) -> UNNotificationRequest {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        var components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notification.firesAt)
        components.calendar = utc
        components.timeZone = .gmt

        let bundle = localizedBundle(for: locale)
        let content = UNMutableNotificationContent()
        content.title = switch notification.origin {
        case .task: String(localized: "reminders.notification.task", bundle: bundle, locale: locale)
        case .event: String(localized: "reminders.notification.event", bundle: bundle, locale: locale)
        }
        content.body = notification.title
        content.sound = .default

        return UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }
}
