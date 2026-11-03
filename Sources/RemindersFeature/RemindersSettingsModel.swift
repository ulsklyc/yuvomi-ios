import Foundation
import Observation

/// Stand der Erlaubnis für Mitteilungen, ohne die Typen von UserNotifications.
public enum NotificationPermissionStatus: Hashable, Sendable {
    /// iOS hat noch nicht gefragt.
    case notDetermined
    case denied
    case allowed
}

/// Port für die Erlaubnis. Umgesetzt mit `UNUserNotificationCenter` in `SystemNotificationPermission`.
public protocol NotificationPermission: Sendable {
    func current() async -> NotificationPermissionStatus
    /// Löst die Frage von iOS aus. Hat iOS schon gefragt, kommt der alte Stand zurück.
    func request() async -> NotificationPermissionStatus
}

/// Karte über der Liste und Abschnitt „Erinnerungen“ in den Einstellungen.
@MainActor @Observable
public final class RemindersSettingsModel {
    public private(set) var permission: NotificationPermissionStatus = .notDetermined
    /// Solange iOS fragt, löst ein zweites Tippen keine zweite Frage aus.
    public private(set) var isAsking = false
    private var cardDismissed = false

    /// Die Karte, solange iOS nicht gefragt hat und niemand „Nicht jetzt“ gewählt hat. Fragt
    /// iOS über den Schalter, verschwindet sie ebenfalls.
    public var showsCard: Bool { permission == .notDetermined && !cardDismissed && !isAsking }

    /// Der Schalter, wie er erscheint: an nur mit Erlaubnis.
    public var isOn: Bool { permission == .allowed && wantsReminders }

    private let source: any NotificationPermission
    private let defaults: UserDefaults
    private let onChange: @MainActor (Bool) -> Void

    private static let wantsKey = "reminders.enabled"
    private static let cardKey = "reminders.cardDismissed"

    /// - Parameter onChange: `true` heißt abgleichen, `false` abräumen.
    public init(permission: any NotificationPermission, defaults: UserDefaults = .standard, onChange: @escaping @MainActor (Bool) -> Void) {
        source = permission
        self.defaults = defaults
        self.onChange = onChange
    }

    /// Ohne gespeicherten Wunsch gilt „an“: Wer iOS erlaubt hat, will Erinnerungen.
    private var wantsReminders: Bool {
        get { defaults.object(forKey: Self.wantsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.wantsKey) }
    }

    public func load() async {
        cardDismissed = defaults.bool(forKey: Self.cardKey)
        permission = await source.current()
    }

    public func allowFromCard() async {
        dismissCard()
        await turnOn()
    }

    /// „Nicht jetzt“: Die Karte kommt nicht wieder, der Weg bleibt in den Einstellungen.
    public func notNow() {
        dismissCard()
    }

    /// Der Schalter „Erinnerungen auf diesem iPhone“.
    public func setOn(_ on: Bool) async {
        if on {
            await turnOn()
        } else {
            wantsReminders = false
            onChange(false)
        }
    }

    private func dismissCard() {
        defaults.set(true, forKey: Self.cardKey)
        cardDismissed = true
    }

    private func turnOn() async {
        guard !isAsking else { return }
        if permission == .notDetermined {
            isAsking = true
            permission = await source.request()
            isAsking = false
        }
        wantsReminders = true
        if isOn { onChange(true) }
    }
}
