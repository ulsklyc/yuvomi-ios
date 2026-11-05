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

    /// `YYYY-MM-DD`, das Gegenstück zu `init?(iso:)`.
    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
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

    /// Der gregorianische Kalender in `timeZone`, nie `Calendar.current` (siehe oben).
    public static func gregorian(_ timeZone: TimeZone) -> Calendar {
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

    /// Was die App setzen kann. `.unknown` kommt nur vom Server.
    public static let settable: [TaskPriority] = [.none, .low, .medium, .high, .urgent]
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
    /// Wie viele Unteraufgaben erledigt sind, `nil` ohne Unteraufgaben.
    public var subtasks: SubtaskProgress?

    public init(
        id: Int, title: String, status: TaskStatus, priority: TaskPriority,
        due: CalendarDay?, dueTime: String?, assignees: [String], subtasks: SubtaskProgress? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.due = due
        self.dueTime = dueTime
        self.assignees = assignees
        self.subtasks = subtasks
    }
}

/// „2 von 5 Unteraufgaben erledigt“, für die Zeile der Liste.
public struct SubtaskProgress: Hashable, Sendable {
    public var done: Int
    public var total: Int

    /// `nil` ohne Unteraufgaben, damit die Zeile kein „0/0“ zeigt.
    public init?(done: Int, total: Int) {
        guard total > 0 else { return nil }
        self.done = min(max(done, 0), total)
        self.total = total
    }
}

/// Fehler angemeldeter Abfragen.
public enum APIError: Error, Hashable, Sendable {
    /// 401: Das Credential gilt nicht mehr, etwa nach einem Passwortwechsel. Zurück zum Login.
    case unauthorized
    /// 403: Die Person darf das im Modul nicht, etwa weil sie Aufgaben nur lesen darf.
    case forbidden
    /// 403 `task_locked`: Die Aufgabe ist gesperrt, ändern darf sie nur, wer sie angelegt hat.
    /// Abhaken bleibt offen, der Fall kommt also nur beim Anlegen, Ändern und Löschen.
    case locked
    /// 404: gelöscht oder für die Person nicht (mehr) sichtbar.
    case notFound
    /// 409: Was die Person gesehen hat, stimmt nicht mehr, etwa eine Zeile der Checkliste,
    /// die jemand inzwischen geändert hat.
    case conflict
    case unreachable
    case unexpectedResponse
}

/// Eine Aufgabe, so weit das Detail sie zeigt (Q7).
public struct TaskDetail: Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var start: CalendarDay?
    public var due: CalendarDay?
    /// `HH:MM`, Wanduhrzeit des Haushalts.
    public var dueTime: String?
    /// Anzeigenamen, die hauptverantwortliche Person zuerst.
    public var assignees: [String]
    /// Dieselben Personen als IDs, in derselben Reihenfolge.
    public var assigneeIDs: [Int]
    /// Freitext, darin womöglich eine Checkliste (`Checklist`).
    public var description: String?
    /// Die Unteraufgaben, die die Person sehen darf, in der Reihenfolge des Servers.
    public var subtasks: [TaskSummary]
    public var tags: [String]
    public var points: Int
    public var isRecurring: Bool
    /// Nur die Person, die sie angelegt hat, und Admins dürfen sie ändern. Abhaken und
    /// Ankreuzen bleiben für alle offen.
    public var isLocked: Bool
    /// Key aus `TaskOptions.categories`.
    public var category: String
    /// Wer sie angelegt hat. Ist sie gesperrt, darf nur diese Person sie ändern.
    public var createdBy: Int?

    public init(
        id: Int, title: String, status: TaskStatus, priority: TaskPriority,
        start: CalendarDay? = nil, due: CalendarDay? = nil, dueTime: String? = nil, assignees: [String] = [],
        assigneeIDs: [Int] = [], description: String? = nil, subtasks: [TaskSummary] = [], tags: [String] = [],
        points: Int = 0, isRecurring: Bool = false, isLocked: Bool = false,
        category: String = "misc", createdBy: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.start = start
        self.due = due
        self.dueTime = dueTime
        self.assignees = assignees
        self.assigneeIDs = assigneeIDs
        self.description = description
        self.subtasks = subtasks
        self.tags = tags
        self.points = points
        self.isRecurring = isRecurring
        self.isLocked = isLocked
        self.category = category
        self.createdBy = createdBy
    }
}

/// Port für die Aufgaben eines angemeldeten Geräts. Umgesetzt in YuvomiAPI.
public protocol TaskReading: Sendable {
    func tasks() async throws(APIError) -> [TaskSummary]
    /// Nur Hauptaufgaben. Eine Unteraufgabe steckt in `subtasks` ihrer Elternaufgabe.
    func task(id: Int) async throws(APIError) -> TaskDetail
}

/// Was der Server nach einem Statuswechsel meldet.
public struct StatusChange: Hashable, Sendable {
    public var status: TaskStatus
    /// Hat das Abhaken eine Serie fortgesetzt, die Fälligkeit des nächsten Vorkommens.
    public var nextDue: CalendarDay?

    public init(status: TaskStatus, nextDue: CalendarDay? = nil) {
        self.status = status
        self.nextDue = nextDue
    }
}

/// Port für das Schreiben an Aufgaben aus der App. Umgesetzt in YuvomiAPI.
///
/// Anders als `ReminderWriting` ohne Warteschlange: Die App ist dabei vorn, ein Fehler springt
/// sichtbar zurück (Q3).
public protocol TaskWriting: Sendable {
    /// Abhaken (`.done`) oder wieder öffnen (`.open`), auch für eine Unteraufgabe.
    func setStatus(task id: Int, to status: TaskStatus) async throws(APIError) -> StatusChange
    /// Einen Punkt der Checkliste ankreuzen. `expect` ist die Zeile, wie die Person sie sah
    /// (`Checklist.Line.raw`). Passt sie nicht mehr, kommt `.conflict`.
    ///
    /// - Returns: Die ganze Beschreibung danach, so wie der Server sie gespeichert hat.
    func tick(task id: Int, line: Int, checked: Bool, expect: String) async throws(APIError) -> String
}

/// Die angemeldete Person, so weit die App sie für Rechte braucht (`GET /auth/me`).
public struct Member: Hashable, Sendable {
    public var id: Int
    /// Darf die Person im Modul Aufgaben schreiben? Bei `read` zeigt die App keine Haken und
    /// kein Formular (Slice 5 Q4, Slice 6 Q7).
    public var mayWriteTasks: Bool
    /// Bei einer Person allein blendet das Formular die Zuständigen aus (Q10).
    public var householdSize: Int

    public init(id: Int, mayWriteTasks: Bool, householdSize: Int) {
        self.id = id
        self.mayWriteTasks = mayWriteTasks
        self.householdSize = householdSize
    }
}

/// Port für die Rechte der angemeldeten Person (`GET /auth/me`). Umgesetzt in YuvomiAPI.
public protocol MemberPermissions: Sendable {
    func member() async throws(APIError) -> Member
}
