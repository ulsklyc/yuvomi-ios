import Foundation
@preconcurrency import UserNotifications
import YuvomiCore

/// Delegate für die Mitteilungen der Erinnerungen.
///
/// - Im Vordergrund zeigt er sie als Banner mit Ton. Ohne Delegate schluckt iOS sie still.
/// - Antippen, Wegwischen und „Erledigt“ gibt er als `ReminderReply` an die App weiter.
///   Antippen öffnet die App wie bisher auf der Aufgabenliste.
///
/// Ohne veränderlichen Zustand und deshalb `Sendable`. Die Methoden sind `nonisolated`, weil die
/// UN-Typen nicht `Sendable` sind und iOS sie ohne Actor-Bezug aufruft. Aus `response` wird nur
/// gelesen, was die Rückmeldung braucht.
///
/// Bewusst die Varianten mit Completion Handler, nicht die mit `async`: Kehrt eine
/// `nonisolated async`-Methode zurück, ruft Swift den Handler von iOS auf einem Thread des
/// Pools auf. UIKit verlangt dafür den Main Thread und beendet die App sonst mit „Call must be
/// made on main thread“ (gesehen im Simulator bei „Erledigt“ im Hintergrund).
public final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    public typealias ReplyHandler = @MainActor @Sendable (ReminderReply) async -> Void

    private let onReply: ReplyHandler

    /// - Parameter onReply: Läuft, bis die Rückmeldung gesendet oder gemerkt ist. So lange
    ///   wartet auch iOS, bevor es die App wieder anhält.
    public init(onReply: @escaping ReplyHandler) {
        self.onReply = onReply
    }

    /// Muss vor dem Ende von `didFinishLaunching` passieren. Das Center hält den Delegate nur
    /// schwach, der Aufrufer muss ihn festhalten.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        // Der Titel der Aufgabe steht im Text, die Überschrift nennt nur die Herkunft
        // (`SystemNotificationScheduler.request(for:)`, geprüft in `NotificationRequestTests`).
        guard let reply = ReminderReply(
            action: response.actionIdentifier, identifier: request.identifier, title: request.content.body, at: .now
        ) else {
            // Fremde Mitteilung oder unbekannte Aktion: nichts zu tun.
            completionHandler()
            return
        }
        // Der Handler ist im SDK nicht `Sendable`. Er läuft genau einmal, am Ende des Tasks und
        // damit auf dem MainActor, so wie UIKit es verlangt.
        nonisolated(unsafe) let completionHandler = completionHandler
        let onReply = onReply
        Task { @MainActor in
            await onReply(reply)
            completionHandler()
        }
    }
}

extension ReminderReply {
    /// Die Rückmeldung zu einer Aktion an einer Mitteilung, `nil` für fremde Mitteilungen
    /// (etwa „Nicht abgehakt“), Kennungen aus Slice 3 und unbekannte Aktionen.
    ///
    /// - Antippen und Wegwischen verwerfen (Q3).
    /// - „Erledigt“ hakt ab, aber nur an einer Aufgabe (Q2).
    init?(action: String, identifier: String, title: String, at: Date) {
        guard let parsed = ReminderSync.parse(identifier) else { return nil }
        let kind: Kind
        switch action {
        case UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier:
            kind = .dismiss
        case SystemNotificationScheduler.checkOffAction where parsed.origin == .task:
            kind = .checkOff
        default:
            return nil
        }
        self.init(kind: kind, reminderID: parsed.reminder, origin: parsed.origin, entityID: parsed.entityID, title: title, at: at)
    }
}
