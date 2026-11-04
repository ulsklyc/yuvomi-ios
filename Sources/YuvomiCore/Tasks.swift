import Foundation

/// Ein Kalendertag ohne Uhrzeit und Zeitzone, wie `due_date` (`YYYY-MM-DD`).
///
/// Eigener Typ statt `Date`: Ein `Date` ist ein Zeitpunkt, und je nach Zeitzone des
/// Geräts landete derselbe Tag sonst auf dem Vortag.
public struct CalendarDay: Hashable, Sendable, Comparable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Liest `YYYY-MM-DD`; alles andere ergibt `nil`.
    public init?(iso value: String) {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// Der Tag, auf den `date` in dieser Zeitzone fällt. Immer im gregorianischen Kalender,
    /// wie `due_date`: Mit `Calendar.current` ergäbe ein buddhistischer Kalender das Jahr 2569.
    public init(_ date: Date, timeZone: TimeZone = .current) {
        let parts = Self.gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Mitternacht dieses Tages in der Zeitzone, etwa zum Formatieren in der Oberfläche.
    public func start(timeZone: TimeZone = .current) -> Date? {
        Self.gregorian(timeZone).date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// `unknown` ist ein unbekannter Wert (Glossar): ein Status, den diese App-Version nicht
/// kennt. Er gilt nie als erledigt, die Aufgabe bleibt also in der Liste.
public enum TaskStatus: Hashable, Sendable {
    case open, inProgress, done, unknown
}

/// `unknown` ist ein unbekannter Wert (Glossar). Die Liste zeigt ihn wie `none`: ohne Hinweis,
/// statt ihn als dringend oder unwichtig zu deuten.
public enum TaskPriority: Hashable, Sendable {
    case none, low, medium, high, urgent, unknown
}

/// Eine Aufgabe, so weit die Liste sie zeigt.
public struct TaskSummary: Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var due: CalendarDay?
    /// `HH:MM`, Wanduhrzeit des Haushalts.
    public var dueTime: String?
    /// Anzeigenamen, die hauptverantwortliche Person zuerst.
    public var assignees: [String]

    public init(
        id: Int, title: String, status: TaskStatus, priority: TaskPriority,
        due: CalendarDay?, dueTime: String?, assignees: [String]
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.due = due
        self.dueTime = dueTime
        self.assignees = assignees
    }
}

/// Fehler angemeldeter Abfragen.
public enum APIError: Error, Hashable, Sendable {
    /// 401: Das Credential gilt nicht mehr, etwa nach einem Passwortwechsel. Zurück zum Login.
    case unauthorized
    /// 403: Die Person darf das im Modul nicht, etwa weil sie Aufgaben nur lesen darf.
    case forbidden
    /// 404: gelöscht oder für die Person nicht (mehr) sichtbar.
    case notFound
    case unreachable
    case unexpectedResponse
}

/// Port für die Aufgaben eines angemeldeten Geräts. Umgesetzt in YuvomiAPI.
public protocol TaskReading: Sendable {
    func tasks() async throws(APIError) -> [TaskSummary]
}
