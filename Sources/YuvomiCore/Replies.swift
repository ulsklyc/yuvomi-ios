import Foundation

/// Was eine Person an einer Mitteilung getan hat und die App an den Server weitergibt.
public struct ReminderReply: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// Antippen oder Wegwischen: die Erinnerung verwerfen.
        case dismiss
        /// „Erledigt“: die Aufgabe abhaken, danach die Erinnerung verwerfen.
        case checkOff
    }

    public var kind: Kind
    public var reminderID: Int
    public var origin: ReminderOrigin
    public var entityID: Int
    /// Für den Hinweis, falls der Server das Abhaken ablehnt.
    public var title: String
    /// Wann die Person gehandelt hat. Nach 24 Stunden geht die Rückmeldung nicht mehr raus.
    public var at: Date

    public init(kind: Kind, reminderID: Int, origin: ReminderOrigin, entityID: Int, title: String, at: Date) {
        self.kind = kind
        self.reminderID = reminderID
        self.origin = origin
        self.entityID = entityID
        self.title = title
        self.at = at
    }
}

/// Port für das Zurückschreiben an den Server. Umgesetzt in YuvomiAPI.
public protocol ReminderWriting: Sendable {
    /// `PATCH /reminders/{id}/dismiss`. Am Server idempotent.
    func dismiss(reminder id: Int) async throws(APIError)
    /// `PATCH /tasks/{id}/status` mit `done`. Am Server idempotent.
    func checkOff(task id: Int) async throws(APIError)
}

/// Port für die Rückmeldungen, die der Server noch nicht hat. Sie überstehen einen Neustart.
///
/// Auf dem Main Actor, wie ihr einziger Nutzer `ReminderCoordinator`: So braucht die
/// Umsetzung mit `UserDefaults`, das nicht `Sendable` ist, keine eigene Sperre.
@MainActor
public protocol ReplyQueue: AnyObject {
    /// In der Reihenfolge, in der sie dazukamen.
    var replies: [ReminderReply] { get }
    func append(_ reply: ReminderReply)
    /// Ersetzt an derselben Stelle, etwa ein Abhaken, das nur noch verworfen werden muss.
    func replace(_ reply: ReminderReply, with new: ReminderReply)
    func remove(_ reply: ReminderReply)
    func removeAll()
}

/// Die Warteschlange in `UserDefaults`. Die sind nach dem ersten Entsperren auch bei
/// gesperrtem Gerät lesbar, anders als Dateien mit dem Schutz `complete`.
@MainActor
public final class UserDefaultsReplyQueue: ReplyQueue {
    private let defaults: UserDefaults
    private static let key = "reminders.replies"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Ein unlesbarer Eintrag, etwa aus einer künftigen Version, gilt als leer statt die App
    /// anzuhalten. Es geht nur eine Rückmeldung verloren.
    public var replies: [ReminderReply] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([ReminderReply].self, from: data)) ?? []
    }

    public func append(_ reply: ReminderReply) {
        store(replies + [reply])
    }

    public func replace(_ reply: ReminderReply, with new: ReminderReply) {
        store(replies.map { $0 == reply ? new : $0 })
    }

    public func remove(_ reply: ReminderReply) {
        store(replies.filter { $0 != reply })
    }

    public func removeAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func store(_ replies: [ReminderReply]) {
        if replies.isEmpty {
            removeAll()
        } else if let data = try? JSONEncoder().encode(replies) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
