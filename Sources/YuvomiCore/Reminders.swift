import Foundation

/// Woran eine Erinnerung erinnert. In v1 nur Aufgaben und Termine (`types=task,event`).
public enum ReminderOrigin: Hashable, Sendable {
    case task, event
}

/// Eine kommende Erinnerung aus `GET /reminders/upcoming`.
public struct UpcomingReminder: Hashable, Sendable {
    public var id: Int
    public var origin: ReminderOrigin
    public var title: String
    /// `fires_at`, nie `remind_at`: nur dieses Feld ist ein Zeitpunkt mit Zone.
    public var firesAt: Date

    public init(id: Int, origin: ReminderOrigin, title: String, firesAt: Date) {
        self.id = id
        self.origin = origin
        self.title = title
        self.firesAt = firesAt
    }
}

/// Eine Mitteilung, wie der Abgleich sie auf dem Gerät haben will.
public struct PlannedNotification: Hashable, Sendable {
    /// `reminder.<id>`: Dieselbe Kennung ersetzt beim Planen die alte Mitteilung.
    public var id: String
    public var origin: ReminderOrigin
    public var title: String
    public var firesAt: Date

    public init(id: String, origin: ReminderOrigin, title: String, firesAt: Date) {
        self.id = id
        self.origin = origin
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

    public func run(now: Date) async throws(APIError) {
        let reminders = try await source.upcoming(from: now, to: now.addingTimeInterval(Self.window))
        // Abmelden bricht den Lauf ab und räumt danach ab. Eine Antwort, die erst dann kommt,
        // darf keine Mitteilungen für ein abgemeldetes Konto planen.
        guard !Task.isCancelled else { return }
        let wanted = reminders
            .filter { $0.firesAt.timeIntervalSince(now) >= Self.leadTime }
            .sorted { ($0.firesAt, $0.id) < ($1.firesAt, $1.id) }
            .prefix(Self.limit)
            .map {
            PlannedNotification(id: Self.id(of: $0), origin: $0.origin, title: $0.title, firesAt: $0.firesAt)
        }
        // Was der Server noch nennt, aber gleich fällt, ist schon geplant oder zu spät zum Planen.
        // Entfernen hieße, es zu verpassen.
        let aboutToFire = reminders
            .filter { $0.firesAt.timeIntervalSince(now) < Self.leadTime }
            .map { Self.id(of: $0) }
        let pending = await scheduler.pending()
        // Auch nach jedem Warten auf iOS: Ein abgelaufener Hintergrund-Task hört hier auf.
        guard !Task.isCancelled else { return }
        let gone = Self.ours(pending)
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

    private static func id(of reminder: UpcomingReminder) -> String { prefix + String(reminder.id) }

    /// Nur Kennungen mit `reminder.` gehören dem Abgleich.
    private static func ours(_ ids: Set<String>) -> Set<String> { ids.filter { $0.hasPrefix(prefix) } }
}
