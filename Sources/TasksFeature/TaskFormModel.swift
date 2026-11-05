import Foundation
import Observation
import YuvomiCore

/// Zustand des Formulars im Sheet (Q2): Entwurf, Optionen, Senden und Fehler, fürs Anlegen und
/// fürs Ändern. Je geöffnetem Sheet ein Modell, wie ein Formular-Store, der mit dem Dialog
/// entsteht und mit ihm geht.
@MainActor @Observable
public final class TaskFormModel: Identifiable {
    /// Wie das Sheet endet, wenn nicht die Person es schließt.
    public enum Outcome: Hashable, Sendable {
        /// Der Server hat gesichert. Beim Ändern mit dem Stand danach (Q11), beim Anlegen `nil`.
        case saved(TaskDetail?)
        /// Ein Fehler, der das Sheet schließt (Q13): `.forbidden`, `.locked` oder `.notFound`.
        /// Die Folgen trägt der Besitzer.
        case failed(APIError)
    }

    /// Die Aufgabe, die das Formular ändert. `nil` beim Anlegen.
    public let taskID: Int?

    public var draft: TaskDraft
    /// Der Stand beim Öffnen. Ohne Abweichung davon ist „Sichern“ aus (Q9).
    public let base: TaskDraft
    /// Mitglieder und Kategorien aus `meta/options`. Ohne sie bleibt das Formular nutzbar.
    public private(set) var options: TaskOptions?
    public private(set) var isSaving = false
    /// Hinweis nach einem gescheiterten Sichern. Die Eingaben bleiben (Q4).
    public private(set) var notice: TaskNotice?

    private let editor: any TaskEditing
    private let now: () -> Date
    private let timeZone: TimeZone
    private let makeKey: () -> String
    private let onUnauthorized: @MainActor () -> Void
    private let onFinished: @MainActor (Outcome) async -> Void

    /// Der letzte Versuch und sein Schlüssel (Q14). Dieselbe Anfrage schickt denselben Schlüssel
    /// wieder, so legt der Server nicht doppelt an. Eine andere braucht einen neuen: Mit dem
    /// alten antwortete der Server 24 Stunden lang 409.
    private var attempt: (changes: TaskChanges, key: String)?

    /// - Parameters:
    ///   - task: Der gespeicherte Stand fürs Ändern, `nil` fürs Anlegen.
    ///   - now: Für den Vorschlag bei Datum und Uhrzeit; in Tests fest.
    ///   - options: Schon geladene Optionen, etwa vom Detail. Dann lädt das Formular sie nicht neu.
    ///   - onFinished: Gesichert oder ein Fehler nach Q13. Der Aufrufer schließt das Sheet.
    public init(
        editing task: TaskDetail? = nil, options: TaskOptions? = nil,
        editor: any TaskEditing, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
        makeKey: @escaping () -> String = { UUID().uuidString },
        onUnauthorized: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor (Outcome) async -> Void
    ) {
        self.taskID = task?.id
        let base = task.map(TaskDraft.init) ?? TaskDraft()
        self.base = base
        self.draft = base
        self.options = options
        self.editor = editor
        self.now = now
        self.timeZone = timeZone
        self.makeKey = makeKey
        self.onUnauthorized = onUnauthorized
        self.onFinished = onFinished
    }

    public var isEditing: Bool { taskID != nil }
    public var hasChanges: Bool { !draft.changes(from: base).isEmpty }
    public var canSave: Bool { hasChanges && draft.problems.isEmpty && !isSaving }
    /// Wem sich die Aufgabe zuweisen lässt. `nil` bei einer Person allein (Q10) oder ohne Optionen.
    public var assignablePeople: [TaskOptions.Person]? {
        guard let people = options?.people, people.count > 1 else { return nil }
        return people
    }

    /// Ab 4500 Zeichen die Zahl für den Zähler, gezählt wie am Server (Q18).
    public var descriptionCount: Int? {
        let count = draft.descriptionLength
        return count >= TaskDraft.descriptionCounterFrom ? count : nil
    }

    /// Schalter „Datum“ (Q17): an mit heute, aus nimmt die Uhrzeit mit.
    public var hasDue: Bool {
        get { draft.due != nil }
        set {
            guard newValue != hasDue else { return }
            draft.due = newValue ? CalendarDay(now(), timeZone: timeZone) : nil
            if !newValue { draft.dueTime = nil }
        }
    }

    /// Schalter „Uhrzeit“ (Q17): an mit der nächsten vollen Stunde, spätestens 23:59.
    public var hasTime: Bool {
        get { draft.due != nil && draft.dueTime != nil }
        set {
            guard newValue != hasTime else { return }
            guard newValue, draft.due != nil else {
                draft.dueTime = nil
                return
            }
            // Über die Uhr statt über die Stundenzahl: Am Tag der Zeitumstellung folgt auf 01:00
            // direkt 03:00, und 02:00 gäbe es nicht.
            let calendar = CalendarDay.gregorian(timeZone)
            let today = calendar.startOfDay(for: now())
            let hour = calendar.dateInterval(of: .hour, for: now())?.start ?? now()
            let next = hour.addingTimeInterval(3600)
            guard calendar.isDate(next, inSameDayAs: today) else {
                draft.dueTime = "23:59"
                return
            }
            let parts = calendar.dateComponents([.hour, .minute], from: next)
            draft.dueTime = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
    }

    /// Der Tag für den Datumswähler, Mitternacht in der Zeitzone des Modells.
    public var dueDate: Date {
        get { draft.due?.start(timeZone: timeZone) ?? now() }
        set { draft.due = CalendarDay(newValue, timeZone: timeZone) }
    }

    /// `HH:MM` für den Zeitwähler, am gewählten Tag. Nur Stunde und Minute zählen.
    public var dueTimeDate: Date {
        get {
            let calendar = CalendarDay.gregorian(timeZone)
            let parts = (draft.dueTime ?? "").split(separator: ":").compactMap { Int($0) }
            // Am gewählten Tag: An einem anderen Tag gibt es Uhrzeiten, die heute fehlen.
            let day = draft.due?.start(timeZone: timeZone) ?? calendar.startOfDay(for: now())
            guard parts.count == 2 else { return day }
            return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day) ?? day
        }
        set {
            let parts = CalendarDay.gregorian(timeZone).dateComponents([.hour, .minute], from: newValue)
            draft.dueTime = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
    }

    /// Die zuerst gewählte Person ist hauptverantwortlich (Q10): Neue kommen ans Ende.
    public func toggleAssignee(_ id: Int) {
        if let index = draft.assigneeIDs.firstIndex(of: id) {
            draft.assigneeIDs.remove(at: index)
        } else {
            draft.assigneeIDs.append(id)
        }
    }

    public func loadOptions() async {
        guard options == nil else { return }
        do throws(APIError) {
            options = try await editor.options()
        } catch .unauthorized {
            onUnauthorized()
        } catch .forbidden {
            await onFinished(.failed(.forbidden))
        } catch {
            // Ohne Optionen fehlen nur Zuständige und Kategorien, der Rest geht.
        }
    }

    public func save() async {
        guard canSave else { return }
        let changes = draft.changes(from: base)
        isSaving = true
        notice = nil
        defer { isSaving = false }
        do throws(APIError) {
            if let taskID {
                // PUT ist idempotent und braucht keinen Schlüssel.
                await onFinished(.saved(try await editor.update(task: taskID, changes)))
            } else {
                let key = attempt.flatMap { $0.changes == changes ? $0.key : nil } ?? makeKey()
                attempt = (changes, key)
                _ = try await editor.create(draft, parent: nil, idempotencyKey: key)
                await onFinished(.saved(nil))
            }
        } catch .unauthorized {
            onUnauthorized()
        } catch .conflict {
            notice = .stillRunning
        } catch {
            switch error {
            case .forbidden, .locked, .notFound: await onFinished(.failed(error))
            default: notice = TaskNotice(error)
            }
        }
    }
}
