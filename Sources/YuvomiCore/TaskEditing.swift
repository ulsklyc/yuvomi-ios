import Foundation

/// Was mit einem Feld beim Speichern geschieht. In JS entspräche das einem Body, in dem das
/// Feld fehlt (`keep`), `null` ist (`clear`) oder einen Wert hat (`set`).
public enum Change<Value: Hashable & Sendable>: Hashable, Sendable {
    case keep
    case clear
    case set(Value)
}

/// Die Felder, die der Server beim Anlegen oder Ändern bekommt, nur die geänderten (Q9).
///
/// Titel, Priorität und Kategorie lassen sich nicht leeren (`null` wäre 400): Bei ihnen
/// heißt `nil` „bleibt“.
public struct TaskChanges: Hashable, Sendable {
    public var title: String?
    public var due: Change<CalendarDay>
    /// `HH:MM`.
    public var dueTime: Change<String>
    /// Die hauptverantwortliche Person zuerst.
    public var assigneeIDs: Change<[Int]>
    public var priority: TaskPriority?
    public var category: String?
    public var description: Change<String>

    public init(
        title: String? = nil, due: Change<CalendarDay> = .keep, dueTime: Change<String> = .keep,
        assigneeIDs: Change<[Int]> = .keep, priority: TaskPriority? = nil, category: String? = nil,
        description: Change<String> = .keep
    ) {
        self.title = title
        self.due = due
        self.dueTime = dueTime
        self.assigneeIDs = assigneeIDs
        self.priority = priority
        self.category = category
        self.description = description
    }

    /// Ohne Änderung ist „Sichern“ aus (Q9).
    public var isEmpty: Bool { self == TaskChanges() }
}

/// Der Stand des Formulars (Q1): die sechs Felder, die die App anlegt und ändert.
public struct TaskDraft: Hashable, Sendable {
    /// Grenzen wie `server/middleware/validate.js`.
    public static let titleLimit = 200
    public static let descriptionLimit = 5000

    public var title = ""
    public var due: CalendarDay?
    /// `HH:MM`. Gilt nur mit Datum (Q17).
    public var dueTime: String?
    /// Die zuerst gewählte Person ist hauptverantwortlich (Q10).
    public var assigneeIDs: [Int] = []
    public var priority: TaskPriority = .none
    /// Wie die Vorgabe des Servers.
    public var category = "misc"
    public var description = ""

    /// Das leere Formular fürs Anlegen.
    public init() {}

    /// Der gespeicherte Stand fürs Ändern.
    public init(_ task: TaskDetail) {
        title = task.title
        due = task.due
        dueTime = task.dueTime
        assigneeIDs = task.assigneeIDs
        priority = task.priority
        category = task.category
        description = task.description ?? ""
    }

    public enum Problem: Hashable, Sendable {
        case titleMissing, titleTooLong, descriptionTooLong
    }

    /// Was den Server mit 400 antworten ließe. Gezählt wird wie dort: nach `trim()` und in
    /// UTF-16, wie JS `.length`.
    public var problems: Set<Problem> {
        var problems = Set<Problem>()
        let title = trimmedTitle
        if title.isEmpty { problems.insert(.titleMissing) }
        if title.utf16.count > Self.titleLimit { problems.insert(.titleTooLong) }
        if trimmedDescription.utf16.count > Self.descriptionLimit { problems.insert(.descriptionTooLong) }
        return problems
    }

    /// Nur, was sich gegenüber `base` geändert hat. Anlegen ist `changes(from: TaskDraft())`:
    /// Was fehlt, setzt dann der Server.
    public func changes(from base: TaskDraft) -> TaskChanges {
        var changes = TaskChanges()
        let title = trimmedTitle, description = trimmedDescription
        if title != base.trimmedTitle { changes.title = title }
        if due != base.due { changes.due = due.map(Change.set) ?? .clear }
        if effectiveTime != base.effectiveTime { changes.dueTime = effectiveTime.map(Change.set) ?? .clear }
        if assigneeIDs != base.assigneeIDs { changes.assigneeIDs = assigneeIDs.isEmpty ? .clear : .set(assigneeIDs) }
        if priority != base.priority { changes.priority = priority }
        if category != base.category { changes.category = category }
        if description != base.trimmedDescription {
            changes.description = description.isEmpty ? .clear : .set(self.description)
        }
        return changes
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Ohne Datum gibt es keine Uhrzeit (Q17).
    private var effectiveTime: String? { due == nil ? nil : dueTime }
}

/// Eine Kategorie aus `GET /tasks/meta/options`.
public struct TaskCategory: Hashable, Sendable, Identifiable {
    public var key: String
    /// Name einer eigenen Kategorie. Bei den eingebauten fehlt er.
    public var name: String?
    /// Übersetzungsschlüssel der Web-App bei den eingebauten, etwa `tasks.categoryHousehold`.
    public var labelKey: String?

    public var id: String { key }

    public init(key: String, name: String?, labelKey: String?) {
        self.key = key
        self.name = name
        self.labelKey = labelKey
    }

    /// Wie die Web-App (Q8): die eigene Übersetzung zu `labelKey`, sonst `name`, sonst der Key.
    /// `translate` liefert `nil`, wenn die App den Schlüssel nicht kennt.
    public func title(_ translate: (String) -> String?) -> String {
        if let labelKey, let translated = translate(labelKey) { return translated }
        if let name, !name.isEmpty { return name }
        return key
    }
}

/// Was das Formular zur Auswahl anbietet.
public struct TaskOptions: Hashable, Sendable {
    public struct Person: Hashable, Sendable, Identifiable {
        public var id: Int
        public var name: String

        public init(id: Int, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Die Mitglieder des Haushalts, in der Reihenfolge des Servers.
    public var people: [Person]
    public var categories: [TaskCategory]

    public init(people: [Person], categories: [TaskCategory]) {
        self.people = people
        self.categories = categories
    }
}

/// Port fürs Anlegen, Ändern und Löschen von Aufgaben. Umgesetzt in YuvomiAPI.
///
/// Getrennt von `TaskWriting`, damit die Fakes fürs Abhaken nicht mitwachsen.
public protocol TaskEditing: Sendable {
    func options() async throws(APIError) -> TaskOptions
    /// Legt eine Aufgabe an, mit `parent` als Unteraufgabe. Derselbe `idempotencyKey` bei
    /// einem zweiten Versuch legt sie nicht doppelt an (Q14). Läuft der erste noch, kommt
    /// `.conflict`. Nur mit `draft.problems.isEmpty`: Sonst antwortet der Server 400, und das
    /// kommt als `.unexpectedResponse` an.
    func create(_ draft: TaskDraft, parent: Int?, idempotencyKey: String) async throws(APIError) -> TaskSummary
    /// - Returns: Die Aufgabe, wie der Server sie danach gespeichert hat.
    func update(task id: Int, _ changes: TaskChanges) async throws(APIError) -> TaskDetail
    /// Mit Unteraufgaben, Erinnerungen und Kommentaren. Ohne Rückgängig (Q3).
    func delete(task id: Int) async throws(APIError)
}
