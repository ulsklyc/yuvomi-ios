import Foundation
@preconcurrency import UserNotifications
import YuvomiCore

/// Setzt `NotificationScheduling` mit dem Notification Center von iOS um.
///
/// Hält das Center nicht fest, sondern holt es je Aufruf: `UNUserNotificationCenter` ist nicht
/// `Sendable`, der Planer soll es aber sein. Die UN-Typen verlassen dieses Modul nicht.
public struct SystemNotificationScheduler: NotificationScheduling {
    /// Kategorie je Herkunft (Q2): Nur die Aufgabe hat einen Knopf. `otherCategory` gilt für
    /// einen unbekannten Typ, der sich nur verwerfen lässt.
    static let taskCategory = "reminder.task"
    static let eventCategory = "reminder.event"
    static let otherCategory = "reminder.other"
    /// „Erledigt“. Über alle Kategorien eindeutig, so verlangt es iOS.
    static let checkOffAction = "reminder.checkOff"

    public init() {}

    /// Muss beim Start passieren, bevor iOS eine Aktion meldet.
    public static func registerCategories(locale: Locale = .current) {
        UNUserNotificationCenter.current().setNotificationCategories(categories(locale: locale))
    }

    /// Alle Kategorien melden das Wegwischen (`customDismissAction`), denn auch Wegwischen
    /// verwirft (Q3). „Erledigt“ verlangt bei gesperrtem Gerät das Entsperren (Q4) und läuft
    /// im Hintergrund, ohne die App zu öffnen.
    static func categories(locale: Locale = .current) -> Set<UNNotificationCategory> {
        let checkOff = UNNotificationAction(
            identifier: checkOffAction,
            title: String(localized: "reminders.action.markDone", bundle: localizedBundle(for: locale), locale: locale),
            options: [.authenticationRequired],
            icon: UNNotificationActionIcon(systemImageName: "checkmark")
        )
        return [
            UNNotificationCategory(identifier: taskCategory, actions: [checkOff], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: eventCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: otherCategory, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
        ]
    }

    /// Sagt sofort Bescheid, dass der Server das Abhaken abgelehnt hat (Q6). Unter
    /// `reminder.notice.`: Kein Abgleich räumt den Hinweis ab, Abmelden schon.
    public func announceNotCheckedOff(title: String) async {
        try? await UNUserNotificationCenter.current().add(Self.notCheckedOffRequest(title: title))
    }

    static func notCheckedOffRequest(title: String, locale: Locale = .current) -> UNNotificationRequest {
        let bundle = localizedBundle(for: locale)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "reminders.notCheckedOff.title", bundle: bundle, locale: locale)
        content.body = String(localized: "reminders.notCheckedOff.body \(title)", bundle: bundle, locale: locale)
        content.sound = .default
        return UNNotificationRequest(identifier: ReminderSync.noticePrefix + "notCheckedOff.\(UUID().uuidString)", content: content, trigger: nil)
    }

    public func pending() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
    }

    public func delivered() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier))
    }

    public func plan(_ notifications: [PlannedNotification]) async {
        let center = UNUserNotificationCenter.current()
        for notification in notifications {
            // Abgebrochen, etwa weil iOS dem Hintergrund-Task die Zeit nimmt: Der Rest folgt
            // beim nächsten Abgleich.
            guard !Task.isCancelled else { return }
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
        switch notification.origin {
        case .task:
            content.title = String(localized: "reminders.notification.task", bundle: bundle, locale: locale)
            content.body = notification.title
            content.categoryIdentifier = taskCategory
        case .event:
            content.title = String(localized: "reminders.notification.event", bundle: bundle, locale: locale)
            content.body = notification.title
            content.categoryIdentifier = eventCategory
        case .unknown:
            // Ein unbekannter Typ: allgemeiner Text statt Herkunft und Titel.
            content.title = String(localized: "reminders.notification.other", bundle: bundle, locale: locale)
            content.body = String(localized: "reminders.notification.other.body", bundle: bundle, locale: locale)
            content.categoryIdentifier = otherCategory
        }
        content.sound = .default

        return UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
    }
}
