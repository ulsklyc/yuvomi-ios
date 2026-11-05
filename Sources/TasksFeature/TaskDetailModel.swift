import Foundation
import Observation
import YuvomiCore

/// Zustand des Details einer Aufgabe. Eines je geöffneter Aufgabe, gebaut von `TaskListModel`.
///
/// Schreiben ist optimistisch wie in der Liste (Q3): Haken und Kreise wechseln sofort und
/// springen bei einem Fehler zurück. Was danach mit Liste und Erinnerungen geschieht, entscheidet
/// der Besitzer über die Rückrufe, das Detail kennt beide nicht.
@MainActor @Observable
public final class TaskDetailModel {
    public enum State: Hashable, Sendable {
        case loading
        case loaded(TaskDetail)
        case failed(Problem)
        /// Gelöscht oder nicht mehr sichtbar (404). Erneut versuchen brächte nichts.
        case gone
    }

    public enum Problem: Hashable, Sendable {
        case unreachable, unexpectedResponse
    }

    public let taskID: Int
    public private(set) var state: State = .loading {
        didSet { if case .loaded(let task) = state { blocks = DescriptionBlock.blocks(of: Checklist(description: task.description)) } }
    }
    /// Neuladen ist gescheitert, das alte Detail bleibt sichtbar.
    public private(set) var refreshProblem: Problem?
    /// Hinweis nach einem gescheiterten Schreiben, bis zum nächsten Versuch (Q13).
    public private(set) var notice: TaskNotice?
    /// Hat das Abhaken eine Serie fortgesetzt: die Fälligkeit des nächsten Vorkommens (Q12).
    public private(set) var nextDue: CalendarDay?
    /// Aufgabe und Unteraufgaben, deren Statuswechsel gerade läuft, auch aus der Liste.
    public var writingStatus: Set<Int> { overlay.writing }
    /// Laufende und seit dem Start eines Ladens bestätigte Statuswechsel, geteilt mit der Liste
    /// (Codex-Review E3).
    private let overlay: StatusOverlay
    /// Die zuletzt vom Server bestätigte Beschreibung nach einem Ankreuzen, mit dessen Nummer.
    /// Ein Laden, das davor begann, übernimmt sie statt seines älteren Texts (Codex-Review E3).
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var tickedDescription: (count: Int, text: String)?
    /// Punkte der Checkliste, deren Ankreuzen gerade läuft: Zeile → Zustand, den die Person
    /// gewählt hat. Die Ansicht zeigt ihn statt des gespeicherten, bis die Antwort da ist.
    public private(set) var ticking: [Int: Bool] = [:]
    /// Die Checkliste ist gesperrt: Ein Ankreuzen der Aufgabe läuft, hier oder in einem früher
    /// geöffneten Detail derselben Aufgabe (Issue #23).
    public var isTickLocked: Bool { overlay.isTicking(taskID) }
    /// Die Beschreibung in Blöcken, einmal je neuem Text berechnet statt bei jedem Zeichnen.
    private(set) var blocks: [DescriptionBlock] = []

    /// Darf die Person schreiben? Fragt die Liste, damit ein 403 überall gleich wirkt.
    public var canWrite: Bool { mayWrite() }

    /// Darf die Person die Aufgabe ändern und löschen (Q7)? Nicht bei Nur-lesen, und eine
    /// gesperrte nur, wenn sie sie selbst angelegt hat. Fehlt die Angabe, gilt sie als fremd.
    public var canEdit: Bool {
        guard canWrite, let task = loaded else { return false }
        return task.isEditable(by: memberID())
    }
    /// Das offene Formular fürs Ändern, sonst `nil`. Setzt die View es auf `nil`, ist das Abbrechen.
    public var form: TaskFormModel?
    public private(set) var isDeleting = false
    /// Kategorien aus `meta/options`, für den Namen einer eigenen Kategorie (Q8).
    public private(set) var options: TaskOptions?

    /// Wie in `TaskListModel`: Nur die Antwort des jüngsten Ladevorgangs zählt.
    private var generation = 0
    private let tasks: any TaskReading
    private let writer: any TaskWriting
    private let editor: any TaskEditing
    private let mayWrite: @MainActor () -> Bool
    private let memberID: @MainActor () -> Int?
    private let onUnauthorized: @MainActor () -> Void
    private let onStatusChanged: @MainActor () -> Void
    private let onTicked: @MainActor () -> Void
    private let onRolledBack: @MainActor (Int, TaskStatus) -> Void
    private let onSubtaskGone: @MainActor (Int) -> Void
    private let onForbidden: @MainActor () -> Void
    private let onGone: @MainActor () -> Void
    private let onDeleted: @MainActor () -> Void

    /// - Parameters:
    ///   - onStatusChanged: Abhaken oder Wieder öffnen ist beim Server (Aufgabe oder Unteraufgabe).
    ///   - onTicked: Ein Punkt der Checkliste ist beim Server.
    ///   - onForbidden: 403, ab jetzt nur lesen.
    ///   - memberID: Die Id der Person aus `/auth/me`, für gesperrte Aufgaben (Q7).
    ///   - onStatusChanged: Auch nach einem Ändern (Q11).
    ///   - onGone: Die Aufgabe gibt es nicht mehr (404). Der Besitzer schließt das Detail.
    ///   - onDeleted: Die Person hat sie gelöscht. Der Besitzer schließt das Detail ohne Hinweis.
    public convenience init(
        taskID: Int, tasks: any TaskReading, writer: any TaskWriting, editor: any TaskEditing,
        mayWrite: @escaping @MainActor () -> Bool = { true },
        memberID: @escaping @MainActor () -> Int? = { nil },
        onUnauthorized: @escaping @MainActor () -> Void,
        onStatusChanged: @escaping @MainActor () -> Void = {},
        onTicked: @escaping @MainActor () -> Void = {},
        onForbidden: @escaping @MainActor () -> Void = {},
        onGone: @escaping @MainActor () -> Void = {},
        onDeleted: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            taskID: taskID, tasks: tasks, writer: writer, editor: editor, overlay: StatusOverlay(),
            mayWrite: mayWrite, memberID: memberID,
            onUnauthorized: onUnauthorized, onStatusChanged: onStatusChanged, onTicked: onTicked,
            onRolledBack: { _, _ in }, onSubtaskGone: { _ in }, onForbidden: onForbidden, onGone: onGone,
            onDeleted: onDeleted
        )
    }

    /// Mit der Überlagerung der Liste, die das Detail baut.
    init(
        taskID: Int, tasks: any TaskReading, writer: any TaskWriting, editor: any TaskEditing, overlay: StatusOverlay,
        mayWrite: @escaping @MainActor () -> Bool,
        memberID: @escaping @MainActor () -> Int?,
        onUnauthorized: @escaping @MainActor () -> Void,
        onStatusChanged: @escaping @MainActor () -> Void,
        onTicked: @escaping @MainActor () -> Void,
        onRolledBack: @escaping @MainActor (Int, TaskStatus) -> Void,
        onSubtaskGone: @escaping @MainActor (Int) -> Void,
        onForbidden: @escaping @MainActor () -> Void,
        onGone: @escaping @MainActor () -> Void,
        onDeleted: @escaping @MainActor () -> Void
    ) {
        self.taskID = taskID
        self.overlay = overlay
        self.tasks = tasks
        self.writer = writer
        self.editor = editor
        self.mayWrite = mayWrite
        self.memberID = memberID
        self.onUnauthorized = onUnauthorized
        self.onStatusChanged = onStatusChanged
        self.onTicked = onTicked
        self.onRolledBack = onRolledBack
        self.onSubtaskGone = onSubtaskGone
        self.onForbidden = onForbidden
        self.onGone = onGone
        self.onDeleted = onDeleted
    }

    public func load() async {
        generation += 1
        let mine = generation
        let mark = overlay.mark
        let ticks = tickCount
        // Nach einem Fehler zeigt „Erneut versuchen“ wieder den Ladekreis.
        if case .failed = state { state = .loading }
        // Die Kategorien einmal je Detail, neben der Aufgabe her. Ohne sie zeigt es den Key.
        let editor = options == nil ? editor : nil
        async let fetched = try? await editor?.options()
        do throws(APIError) {
            var task = try await tasks.task(id: taskID)
            guard mine == generation else { return }
            overlaid(&task, since: mark)
            // Ebenso die Beschreibung: Kam ein Ankreuzen nach dem Start dieser Anfrage zurück,
            // ist seine Antwort neuer als diese.
            if let ticked = tickedDescription {
                if ticked.count > ticks { task.description = ticked.text } else { tickedDescription = nil }
            }
            state = .loaded(task)
            refreshProblem = nil
            // Erst nach der Aufgabe: Ohne Optionen fehlt nur der Name der Kategorie.
            if let fetched = await fetched { options = fetched }
        } catch .unauthorized {
            onUnauthorized()
        } catch .notFound {
            guard mine == generation else { return }
            state = .gone
            onGone()
        } catch {
            // Abgebrochen, etwa weil das Detail zu ist: kein Fehler, der nächste Aufruf lädt neu.
            guard mine == generation, !Task.isCancelled else { return }
            let problem: Problem = error == .unreachable ? .unreachable : .unexpectedResponse
            if case .loaded = state {
                refreshProblem = problem
            } else {
                state = .failed(problem)
            }
        }
    }

    /// Laufende und seit `mark` bestätigte Statuswechsel und Löschungen über eine Antwort legen,
    /// deren Anfrage bei `mark` begann.
    private func overlaid(_ task: inout TaskDetail, since mark: Int) {
        for (id, status) in overlay.statuses(since: mark) { Self.set(id, to: status, in: &task) }
        let gone = overlay.gone(since: mark)
        task.subtasks.removeAll { gone.contains($0.id) }
    }

    /// Abhaken oder wieder öffnen, je nach Status der Aufgabe (Knopf im Kopf).
    public func toggleStatus() async {
        guard let task = loaded else { return }
        await write(taskID, from: task.status)
    }

    /// Eine Unteraufgabe abhaken oder wieder öffnen, mit ihrer eigenen Id (wie die PWA).
    public func toggleSubtask(_ id: Int) async {
        guard let subtask = loaded?.subtasks.first(where: { $0.id == id }) else { return }
        await write(id, from: subtask.status)
    }

    /// Setzt den Status der Aufgabe (`id == task.id`) oder einer ihrer Unteraufgaben.
    private static func set(_ id: Int, to status: TaskStatus, in task: inout TaskDetail) {
        if id == task.id { task.status = status }
        for i in task.subtasks.indices where task.subtasks[i].id == id { task.subtasks[i].status = status }
    }

    /// Einen Punkt der Checkliste umschalten. `expect` ist die Zeile aus dem zuletzt gesehenen
    /// Text, die Antwort ist die neue Beschreibung (Q12).
    ///
    /// Immer nur ein Punkt je Aufgabe auf einmal, auch über ein wieder geöffnetes Detail hinweg:
    /// Jede Antwort ist die ganze Beschreibung, eine ältere Antwort überschriebe sonst einen später
    /// gesetzten Haken (Codex-Review E3, Issue #23).
    public func tick(line: Int) async {
        guard mayWrite(), let task = loaded,
              let point = Checklist(description: task.description).items.first(where: { $0.index == line })
        else { return }
        // Zuletzt: Ab hier gibt das defer die Sperre wieder frei.
        guard overlay.beginTick(taskID) else { return }
        notice = nil
        ticking[line] = !point.isChecked
        defer {
            ticking[line] = nil
            overlay.finishTick(taskID)
        }
        do throws(APIError) {
            let description = try await writer.tick(task: taskID, line: line, checked: !point.isChecked, expect: point.raw)
            tickCount += 1
            tickedDescription = (tickCount, description)
            update { $0.description = description }
            onTicked()
        } catch .unauthorized {
            onUnauthorized()
        } catch .conflict {
            // Jemand hat die Beschreibung geändert: neu laden statt eine falsche Zeile zu haken.
            // Den Hinweis gibt es nur, wenn das Neuladen geklappt hat, sonst steht sein Fehler da.
            await load()
            if refreshProblem == nil, loaded != nil { notice = .changed }
        } catch {
            fail(error)
        }
    }

    private var loaded: TaskDetail? {
        guard case .loaded(let task) = state else { return nil }
        return task
    }

    /// Ein Statuswechsel für die Aufgabe (`id == taskID`) oder eine ihrer Unteraufgaben.
    private func write(_ id: Int, from before: TaskStatus) async {
        guard mayWrite(), !overlay.isWriting(id) else { return }
        let target: TaskStatus = before == .done ? .open : .done
        notice = nil
        overlay.begin(id, to: target)
        var confirmed: TaskStatus?
        defer { overlay.finish(id, confirmed: confirmed) }
        update { Self.set(id, to: target, in: &$0) }
        do throws(APIError) {
            let change = try await writer.setStatus(task: id, to: target)
            confirmed = target
            // Ein Neuladen, das inzwischen ankam, kann den Wechsel überschrieben haben.
            update { Self.set(id, to: target, in: &$0) }
            if id == taskID { nextDue = target == .done ? change.nextDue : nil }
            onStatusChanged()
        } catch .unauthorized {
            onUnauthorized()
        } catch .notFound where id != taskID {
            // Nur die Unteraufgabe ist weg, die Aufgabe selbst steht noch. Auch in einem neu
            // geöffneten Detail derselben Aufgabe und einem Laden, das davor begann (Issue #24).
            // Lokal und über die Liste: Ein Detail ohne Liste (eigener Init) hat nur das Lokale,
            // ein zweiter Aufruf für dasselbe Modell ändert nichts.
            overlay.markGone(id)
            removeSubtask(id)
            onSubtaskGone(id)
        } catch {
            update { Self.set(id, to: before, in: &$0) }
            onRolledBack(id, before)
            fail(error)
        }
    }

    /// Ein Wechsel der Liste ist gescheitert. Hat das Detail ihn aus der Überlagerung
    /// übernommen, springt er hier ebenso zurück, ohne erneut zu laden.
    func restore(_ id: Int, to status: TaskStatus) {
        update { Self.set(id, to: status, in: &$0) }
    }

    /// Die Unteraufgabe gibt es nicht mehr. Nur ein Detail, das sie zeigt, bekommt den Hinweis.
    func removeSubtask(_ id: Int) {
        guard loaded?.subtasks.contains(where: { $0.id == id }) == true else { return }
        update { $0.subtasks.removeAll { $0.id == id } }
        notice = .gone
    }

    /// Die Kategorie zum Key, mit Namen aus `meta/options`. Ohne Optionen nur der Key (Q8).
    public func category(for key: String) -> TaskCategory {
        options?.category(for: key) ?? TaskCategory(key: key, name: nil, labelKey: nil)
    }

    /// „Bearbeiten“: das Formular mit dem gespeicherten Stand (Q2, Q9).
    public func startEditing() {
        guard canEdit, let task = loaded else { return }
        // Was davor schon lief oder danach bestätigt wird, kennt die Antwort aufs Sichern womöglich nicht.
        let mark = overlay.mark
        form = TaskFormModel(
            editing: task, options: options, editor: editor, onUnauthorized: onUnauthorized,
            onFinished: { [weak self] outcome in await self?.finishEditing(outcome, since: mark) }
        )
    }

    /// Sheet zu, dann die Folgen nach Q11 und Q13.
    private func finishEditing(_ outcome: TaskFormModel.Outcome, since mark: Int) async {
        form = nil
        switch outcome {
        case .saved(let saved):
            // Ein Laden, das vor dem Sichern begann, kennt die Änderung nicht mehr.
            generation += 1
            if var task = saved {
                overlaid(&task, since: mark)
                state = .loaded(task)
            }
            refreshProblem = nil
            onStatusChanged()
        case .failed(let error):
            await failEditing(error)
        }
    }

    /// Löschen nach der Rückfrage der View (Q3). Ohne Rückgängig; 404 gilt als Erfolg.
    public func delete() async {
        guard canEdit, !isDeleting else { return }
        isDeleting = true
        notice = nil
        defer { isDeleting = false }
        do throws(APIError) {
            try await editor.delete(task: taskID)
        } catch .notFound {
            // Schon weg: gilt als gelöscht.
        } catch .unauthorized {
            onUnauthorized()
            return
        } catch {
            await failEditing(error)
            return
        }
        onDeleted()
    }

    /// Wie `fail`. Ist die Aufgabe inzwischen gesperrt, lädt das Detail neu und blendet dann
    /// Bearbeiten und Löschen aus (Q13).
    private func failEditing(_ error: APIError) async {
        fail(error)
        if error == .locked { await load() }
    }

    /// Gemeinsame Folgen nach Q13 für 403, 404 und den Rest.
    private func fail(_ error: APIError) {
        switch error {
        case .notFound:
            state = .gone
            onGone()
        case .forbidden:
            notice = .readOnly
            onForbidden()
        default:
            notice = TaskNotice(error)
        }
    }

    private func update(_ change: (inout TaskDetail) -> Void) {
        guard var task = loaded else { return }
        change(&task)
        state = .loaded(task)
    }
}
