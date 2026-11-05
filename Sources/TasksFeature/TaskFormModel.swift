import Foundation
import Observation
import YuvomiCore

/// Zustand des Formulars im Sheet (Q2): Entwurf, Optionen, Senden und Fehler. Je geöffnetem
/// Sheet ein Modell, wie ein Formular-Store, der mit dem Dialog entsteht und mit ihm geht.
@MainActor @Observable
public final class TaskFormModel: Identifiable {
    /// Wie das Sheet endet, wenn nicht die Person es schließt.
    public enum Outcome: Hashable, Sendable {
        /// Der Server hat angelegt.
        case saved
        /// 403: Die Person darf Aufgaben nur ansehen (Q13).
        case readOnly
    }

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

    /// Je Sheet ein Schlüssel (Q14). Ein zweiter Versuch mit derselben Anfrage schickt ihn
    /// wieder, so legt der Server nicht doppelt an.
    private var key: String
    /// Was der letzte Versuch geschickt hat. Weicht die nächste Anfrage davon ab, braucht sie
    /// einen neuen Schlüssel: Mit dem alten antwortete der Server 24 Stunden lang 409.
    private var attempted: TaskChanges?

    /// - Parameters:
    ///   - now: Für den Vorschlag bei Datum und Uhrzeit; in Tests fest.
    ///   - onFinished: Gesichert oder Nur-lesen. Der Aufrufer schließt das Sheet.
    public init(
        editor: any TaskEditing, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
        makeKey: @escaping () -> String = { UUID().uuidString },
        onUnauthorized: @escaping @MainActor () -> Void,
        onFinished: @escaping @MainActor (Outcome) async -> Void
    ) {
        self.draft = TaskDraft()
        self.base = TaskDraft()
        self.editor = editor
        self.now = now
        self.timeZone = timeZone
        self.makeKey = makeKey
        self.onUnauthorized = onUnauthorized
        self.onFinished = onFinished
        self.key = makeKey()
    }

    public var hasChanges: Bool { !draft.changes(from: base).isEmpty }
    public var canSave: Bool { hasChanges && draft.problems.isEmpty && !isSaving }
    /// Bei einer Person allein gibt es nichts zuzuweisen (Q10).
    public var showsAssignees: Bool { (options?.people.count ?? 0) > 1 }

    /// Ab 4500 Zeichen die Zahl für den Zähler, gezählt wie am Server (Q18).
    public var descriptionCount: Int? {
        let count = draft.description.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
        return count >= 4500 ? count : nil
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
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let hour = calendar.component(.hour, from: now()) + 1
            draft.dueTime = hour > 23 ? "23:59" : String(format: "%02d:00", hour)
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
        do throws(APIError) {
            options = try await editor.options()
        } catch .unauthorized {
            onUnauthorized()
        } catch .forbidden {
            await onFinished(.readOnly)
        } catch {
            // Ohne Optionen fehlen nur Zuständige und Kategorien, der Rest geht.
        }
    }

    public func save() async {
        guard canSave else { return }
        let changes = draft.changes(from: base)
        if let attempted, attempted != changes { key = makeKey() }
        attempted = changes
        isSaving = true
        notice = nil
        defer { isSaving = false }
        do throws(APIError) {
            _ = try await editor.create(draft, parent: nil, idempotencyKey: key)
            await onFinished(.saved)
        } catch .unauthorized {
            onUnauthorized()
        } catch .forbidden {
            await onFinished(.readOnly)
        } catch .conflict {
            notice = .stillRunning
        } catch {
            // `.locked` und `.notFound` kommen erst mit Unteraufgaben (F4) und Ändern (F3).
            notice = TaskNotice(error)
        }
    }
}
