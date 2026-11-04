import Foundation

/// Woran eine Erinnerung erinnert. In v1 nur Aufgaben und Termine (`types=task,event`).
public enum ReminderOrigin: String, Hashable, Sendable, Codable {
    case task, event
}

/// Eine kommende Erinnerung aus `GET /reminders/upcoming`.
public struct UpcomingReminder: Hashable, Sendable {
    public var id: Int
    public var origin: ReminderOrigin
    /// Die Aufgabe oder der Termin (`entity_id`): Abhaken braucht die Aufgabe, und das Abplanen
    /// findet darüber alle Mitteilungen derselben Aufgabe.
    public var entityID: Int
    public var title: String
    /// `fires_at`, nie `remind_at`: nur dieses Feld ist ein Zeitpunkt mit Zone.
    public var firesAt: Date

    public init(id: Int, origin: ReminderOrigin, entityID: Int, title: String, firesAt: Date) {
        self.id = id
        self.origin = origin
        self.entityID = entityID
        self.title = title
        self.firesAt = firesAt
    }
}

/// Eine Mitteilung, wie der Abgleich sie auf dem Gerät haben will.
public struct PlannedNotification: Hashable, Sendable {
    /// `reminder.<id>.<task|event>.<entity_id>`: Dieselbe Kennung ersetzt beim Planen die alte
    /// Mitteilung, und über sie findet das Abplanen alle Mitteilungen derselben Aufgabe.
    public var id: String
    /// Die Erinnerung am Server, für das Verwerfen.
    public var reminderID: Int
    public var origin: ReminderOrigin
    public var entityID: Int
    public var title: String
    public var firesAt: Date

    public init(id: String, reminderID: Int, origin: ReminderOrigin, entityID: Int, title: String, firesAt: Date) {
        self.id = id
        self.reminderID = reminderID
        self.origin = origin
        self.entityID = entityID
        self.title = title
        self.firesAt = firesAt
    }
}

/// Port für die kommenden Erinnerungen der angemeldeten Person. Umgesetzt in YuvomiAPI.
public protocol UpcomingReminders: Sendable {
    func upcoming(from: Date, to: Date) async throws(APIError) -> [UpcomingReminder]
}

/// Port für die geplanten Mitteilungen auf dem Gerät. Umgesetzt in RemindersFeature.
public protocol NotificationScheduling: Sendable {
    /// Kennungen aller geplanten Mitteilungen der App, auch fremder.
    func pending() async -> Set<String>
    /// Kennungen der schon zugestellten Mitteilungen in der Mitteilungszentrale.
    func delivered() async -> Set<String>
    /// Plant oder ersetzt, je nach Kennung.
    func plan(_ notifications: [PlannedNotification]) async
    /// Entfernt geplante und schon zugestellte Mitteilungen.
    func remove(_ ids: Set<String>) async
}

/// Der Abgleich: bringt die geplanten Mitteilungen auf den Stand der kommenden Erinnerungen.
public struct ReminderSync: Sendable {
    /// 14 × 86400 s, nicht 14 Kalendertage: Über die Zeitumstellung im Herbst wäre das Fenster
    /// eine Stunde länger, und der Server antwortet dann 400.
    static let window: TimeInterval = 14 * 86_400
    /// Kennungen anderer Herkunft fasst der Abgleich nicht an.
    static let prefix = "reminder."
    /// Hinweise wie „Nicht abgehakt“. Sie gehören zu Yuvomi und gehen beim Abräumen mit, aber
    /// kein Abgleich entfernt sie, denn der Server kennt sie nicht.
    public static let noticePrefix = "reminder.notice."
    /// iOS behält vermutlich nur 64 geplante Mitteilungen je App, der Server liefert bis 200.
    static let limit = 60
    /// Was früher fällt, verpasst iOS womöglich schon beim Planen.
    static let leadTime: TimeInterval = 5

    private let source: any UpcomingReminders
    private let scheduler: any NotificationScheduling

    public init(source: any UpcomingReminders, scheduler: any NotificationScheduling) {
        self.source = source
        self.scheduler = scheduler
    }

    /// - Parameter replies: Rückmeldungen, die der Server noch nicht hat. Ihre Erinnerungen und
    ///   die Erinnerungen abgehakter Aufgaben plant der Abgleich nicht wieder ein.
    public func run(now: Date, replies: [ReminderReply] = []) async throws(APIError) {
        let fetched = try await source.upcoming(from: now, to: now.addingTimeInterval(Self.window))
        let answered = Set(replies.map(\.reminderID))
        let checkedOff = Set(replies.filter { $0.kind == .checkOff && $0.origin == .task }.map(\.entityID))
        let reminders = fetched.filter {
            !answered.contains($0.id) && !($0.origin == .task && checkedOff.contains($0.entityID))
        }
        // Abmelden bricht den Lauf ab und räumt danach ab. Eine Antwort, die erst dann kommt,
        // darf keine Mitteilungen für ein abgemeldetes Konto planen.
        guard !Task.isCancelled else { return }
        let wanted = reminders
            .filter { $0.firesAt.timeIntervalSince(now) >= Self.leadTime }
            .sorted { ($0.firesAt, $0.id) < ($1.firesAt, $1.id) }
            .prefix(Self.limit)
            .map {
                PlannedNotification(
                    id: Self.id(of: $0), reminderID: $0.id, origin: $0.origin,
                    entityID: $0.entityID, title: $0.title, firesAt: $0.firesAt
                )
            }
        // Was der Server noch nennt, aber gleich fällt, ist schon geplant oder zu spät zum Planen.
        // Entfernen hieße, es zu verpassen.
        // Mit der Kennung aus Slice 3, falls sie noch so geplant ist: Auch die bleibt stehen.
        let aboutToFire = reminders
            .filter { $0.firesAt.timeIntervalSince(now) < Self.leadTime }
            .flatMap { [Self.id(of: $0), Self.prefix + String($0.id)] }
        let pending = await scheduler.pending()
        // Auch nach jedem Warten auf iOS: Ein abgelaufener Hintergrund-Task hört hier auf.
        guard !Task.isCancelled else { return }
        let gone = Self.ours(pending)
            .filter { !$0.hasPrefix(Self.noticePrefix) }
            .subtracting(wanted.map(\.id))
            .subtracting(aboutToFire)
        if !gone.isEmpty { await scheduler.remove(gone) }
        guard !Task.isCancelled else { return }
        // Alles neu planen statt vergleichen: Dieselbe Kennung ersetzt, und der Port muss so
        // keinen Inhalt zurückgeben.
        await scheduler.plan(wanted)
    }

    /// Beim Abmelden, nach einem Widerruf und bei ausgeschaltetem Schalter: Keine Mitteilung
    /// von Yuvomi bleibt zurück.
    public func clear() async {
        await Self.clear(scheduler: scheduler)
    }

    /// Abräumen braucht weder Server noch Anmeldung.
    public static func clear(scheduler: any NotificationScheduling) async {
        let ours = ours(await scheduler.pending().union(await scheduler.delivered()))
        if !ours.isEmpty { await scheduler.remove(ours) }
    }

    /// Entfernt alle geplanten und zugestellten Mitteilungen derselben Aufgabe oder desselben
    /// Termins, nach dem Abhaken oder Verwerfen.
    public static func remove(origin: ReminderOrigin, entityID: Int, scheduler: any NotificationScheduling) async {
        let ids = ours(await scheduler.pending().union(await scheduler.delivered()))
            .filter { entity(of: $0).map { $0 == (origin, entityID) } ?? false }
        if !ids.isEmpty { await scheduler.remove(ids) }
    }

    /// Die Kennung einer Mitteilung. Eine Kennung aus Slice 3 (`reminder.<id>`) passt nicht mehr
    /// und wird beim ersten Abgleich nach dem Update ersetzt.
    public static func id(reminder: Int, origin: ReminderOrigin, entityID: Int) -> String {
        "\(prefix)\(reminder).\(origin.rawValue).\(entityID)"
    }

    /// Erinnerung, Herkunft und Aufgabe oder Termin aus einer Kennung, `nil` für fremde und alte.
    public static func parse(_ id: String) -> (reminder: Int, origin: ReminderOrigin, entityID: Int)? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let reminder = Int(parts[0]), let origin = ReminderOrigin(rawValue: String(parts[1])),
              let entityID = Int(parts[2])
        else { return nil }
        return (reminder, origin, entityID)
    }

    private static func entity(of id: String) -> (ReminderOrigin, Int)? {
        parse(id).map { ($0.origin, $0.entityID) }
    }

    private static func id(of reminder: UpcomingReminder) -> String {
        id(reminder: reminder.id, origin: reminder.origin, entityID: reminder.entityID)
    }

    /// Nur Kennungen mit `reminder.` gehören dem Abgleich.
    private static func ours(_ ids: Set<String>) -> Set<String> { ids.filter { $0.hasPrefix(prefix) } }
}
