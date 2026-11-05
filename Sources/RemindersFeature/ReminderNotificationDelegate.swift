import Foundation
@preconcurrency import UserNotifications
import YuvomiCore

/// Delegate für die Mitteilungen der Erinnerungen.
///
/// - Im Vordergrund zeigt er sie als Banner mit Ton. Ohne Delegate schluckt iOS sie still.
/// - Antippen, Wegwischen und „Erledigt“ gibt er als `ReminderReply` an die App weiter.
/// - Antippen meldet er zuerst als Ziel (Slice 5, Q8): Eine Aufgabe oder der Hinweis „Nicht
///   abgehakt“ öffnet das Detail, ein Termin die Liste.
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
    public typealias OpenHandler = @MainActor @Sendable (Destination) -> Void

    /// Wohin ein Tipp führt. Wie eine Route in einer Web-App.
    public enum Destination: Hashable, Sendable, CustomStringConvertible {
        case list, task(Int)
        public var description: String {
            switch self {
            case .list: "list"
            case .task(let id): "task(\(id))"
            }
        }
    }

    private let onReply: ReplyHandler
    private let onOpen: OpenHandler

    /// - Parameters:
    ///   - onReply: Läuft, bis die Rückmeldung gesendet oder gemerkt ist. So lange wartet auch
    ///     iOS, bevor es die App wieder anhält.
    ///   - onOpen: Das Ziel eines Tipps. Vor der Rückmeldung, damit das Detail nicht aufs Netz wartet.
    public init(onReply: @escaping ReplyHandler, onOpen: @escaping OpenHandler = { _ in }) {
        self.onReply = onReply
        self.onOpen = onOpen
    }

    /// Das Ziel eines Tipps auf diese Mitteilung, `nil` für andere Aktionen und fremde Mitteilungen.
    static func destination(action: String, identifier: String) -> Destination? {
        guard action == UNNotificationDefaultActionIdentifier else { return nil }
        if let parsed = ReminderSync.parse(identifier) {
            return parsed.origin == .task ? .task(parsed.entityID) : .list
        }
        // `reminder.notice.notCheckedOff.<Aufgabe>.<UUID>`. Ältere Hinweise ohne Aufgabe führen zur Liste.
        guard identifier.hasPrefix(SystemNotificationScheduler.notCheckedOffPrefix) else { return nil }
        let parts = identifier.dropFirst(SystemNotificationScheduler.notCheckedOffPrefix.count).split(separator: ".")
        guard parts.count == 2, let id = Int(parts[0]) else { return .list }
        return .task(id)
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
        let target = Self.destination(action: response.actionIdentifier, identifier: request.identifier)
        // Der Titel der Aufgabe steht im Text, die Überschrift nennt nur die Herkunft
        // (`SystemNotificationScheduler.request(for:)`, geprüft in `NotificationRequestTests`).
        let reply = ReminderReply(
            action: response.actionIdentifier, identifier: request.identifier, title: request.content.body, at: .now
        )
        guard reply != nil || target != nil else {
            // Fremde Mitteilung oder unbekannte Aktion: nichts zu tun.
            completionHandler()
            return
        }
        // Der Handler ist im SDK nicht `Sendable`. Er läuft genau einmal, am Ende des Tasks und
        // damit auf dem MainActor, so wie UIKit es verlangt.
        nonisolated(unsafe) let completionHandler = completionHandler
        let onReply = onReply
        let onOpen = onOpen
        Task { @MainActor in
            if let target { onOpen(target) }
            if let reply { await onReply(reply) }
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
