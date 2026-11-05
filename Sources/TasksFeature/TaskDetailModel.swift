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
    /// Aufgabe und Unteraufgaben, deren Statuswechsel gerade läuft.
    public private(set) var writingStatus: Set<Int> = []
    /// Laufende und seit dem Start eines Ladens bestätigte Statuswechsel (Codex-Review E3).
    @ObservationIgnored private var overlay = StatusOverlay()
    /// Die zuletzt vom Server bestätigte Beschreibung nach einem Ankreuzen, mit dessen Nummer.
    /// Ein Laden, das davor begann, übernimmt sie statt seines älteren Texts (Codex-Review E3).
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var tickedDescription: (count: Int, text: String)?
    /// Punkte der Checkliste, deren Ankreuzen gerade läuft: Zeile → Zustand, den die Person
    /// gewählt hat. Die Ansicht zeigt ihn statt des gespeicherten, bis die Antwort da ist.
    public private(set) var ticking: [Int: Bool] = [:]
    /// Die Beschreibung in Blöcken, einmal je neuem Text berechnet statt bei jedem Zeichnen.
    private(set) var blocks: [DescriptionBlock] = []

    /// Darf die Person schreiben? Fragt die Liste, damit ein 403 überall gleich wirkt.
    public var canWrite: Bool { mayWrite() }

    /// Wie in `TaskListModel`: Nur die Antwort des jüngsten Ladevorgangs zählt.
    private var generation = 0
    private let tasks: any TaskReading
    private let writer: any TaskWriting
    private let mayWrite: @MainActor () -> Bool
    private let onUnauthorized: @MainActor () -> Void
    private let onStatusChanged: @MainActor () -> Void
    private let onTicked: @MainActor () -> Void
    private let onForbidden: @MainActor () -> Void
    private let onGone: @MainActor () -> Void

    /// - Parameters:
    ///   - onStatusChanged: Abhaken oder Wieder öffnen ist beim Server (Aufgabe oder Unteraufgabe).
    ///   - onTicked: Ein Punkt der Checkliste ist beim Server.
    ///   - onForbidden: 403, ab jetzt nur lesen.
    ///   - onGone: Die Aufgabe gibt es nicht mehr (404). Der Besitzer schließt das Detail.
    public init(
        taskID: Int, tasks: any TaskReading, writer: any TaskWriting,
        mayWrite: @escaping @MainActor () -> Bool = { true },
        onUnauthorized: @escaping @MainActor () -> Void,
        onStatusChanged: @escaping @MainActor () -> Void = {},
        onTicked: @escaping @MainActor () -> Void = {},
        onForbidden: @escaping @MainActor () -> Void = {},
        onGone: @escaping @MainActor () -> Void = {}
    ) {
        self.taskID = taskID
        self.tasks = tasks
        self.writer = writer
        self.mayWrite = mayWrite
        self.onUnauthorized = onUnauthorized
        self.onStatusChanged = onStatusChanged
        self.onTicked = onTicked
        self.onForbidden = onForbidden
        self.onGone = onGone
    }

    public func load() async {
        generation += 1
        let mine = generation
        let mark = overlay.mark
        let ticks = tickCount
        // Nach einem Fehler zeigt „Erneut versuchen“ wieder den Ladekreis.
        if case .failed = state { state = .loading }
        do throws(APIError) {
            var task = try await tasks.task(id: taskID)
            guard mine == generation else { return }
            for (id, status) in overlay.statuses(since: mark) { Self.set(id, to: status, in: &task) }
            // Ebenso die Beschreibung: Kam ein Ankreuzen nach dem Start dieser Anfrage zurück,
            // ist seine Antwort neuer als diese.
            if let ticked = tickedDescription {
                if ticked.count > ticks { task.description = ticked.text } else { tickedDescription = nil }
            }
            state = .loaded(task)
            refreshProblem = nil
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
    /// Immer nur ein Punkt auf einmal: Jede Antwort ist die ganze Beschreibung, eine ältere
    /// Antwort überschriebe sonst einen später gesetzten Haken (Codex-Review E3).
    public func tick(line: Int) async {
        guard mayWrite(), ticking.isEmpty, let task = loaded,
              let point = Checklist(description: task.description).items.first(where: { $0.index == line })
        else { return }
        notice = nil
        ticking[line] = !point.isChecked
        defer { ticking[line] = nil }
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
        writingStatus = overlay.writing
        var confirmed: TaskStatus?
        defer {
            overlay.finish(id, confirmed: confirmed)
            writingStatus = overlay.writing
        }
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
            // Nur die Unteraufgabe ist weg, die Aufgabe selbst steht noch.
            update { $0.subtasks.removeAll { $0.id == id } }
            notice = .gone
        } catch {
            update { Self.set(id, to: before, in: &$0) }
            fail(error)
        }
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
