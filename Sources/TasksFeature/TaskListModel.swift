import Foundation
import Observation
import YuvomiCore

/// Ein Abschnitt der Liste. Erledigte Aufgaben zeigt Slice 1 nicht.
public struct TaskSection: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case overdue, today, upcoming, noDate
    }

    public var kind: Kind
    public var tasks: [TaskSummary]
    public var id: Kind { kind }
}

/// Zustand der Aufgabenliste: lesen, abhaken und wieder öffnen.
@MainActor @Observable
public final class TaskListModel {
    public enum State: Hashable, Sendable {
        case loading
        case loaded([TaskSection])
        case failed(Problem)
    }

    public enum Problem: Hashable, Sendable {
        case unreachable, unexpectedResponse
    }

    public private(set) var state: State = .loading
    /// Neuladen ist gescheitert, die alte Liste bleibt sichtbar.
    public private(set) var refreshProblem: Problem?

    /// Der Pfad der Navigation: die geöffnete Aufgabe, leer auf der Liste. Auch eine Mitteilung
    /// setzt ihn (Q8). Wie ein Router-Stack in einer Web-App, nur als Array von Ids.
    public var path: [Int] = [] {
        didSet { details = details.filter { path.contains($0.key) } }
    }
    /// Je Aufgabe im Pfad ihr Detail. Wie ein Cache neben dem Router: nicht beobachtet, denn
    /// SwiftUI füllt ihn beim Zeichnen des Ziels.
    @ObservationIgnored private var details: [Int: TaskDetailModel] = [:]

    /// Darf die Person Aufgaben schreiben? Aus `/auth/me` beim Laden, ein 403 stellt es ab (Q4).
    public private(set) var canWrite = true
    /// Aufgaben, deren Statuswechsel gerade läuft, mit dem Ziel. Ihr Kreis ist so lange
    /// gesperrt (Q13), und ein Laden dazwischen behält den Haken.
    @ObservationIgnored private var overlay = StatusOverlay()
    public private(set) var writing: Set<Int> = []
    /// Hinweis nach einem gescheiterten Schreiben, bis zum nächsten Versuch oder Laden.
    public private(set) var notice: TaskNotice?

    /// Zählt die Ladevorgänge. Nur die Antwort des jüngsten zählt: Eine ältere, die später
    /// ankommt, zeigte sonst etwa eine gerade abgehakte Aufgabe wieder offen.
    private var generation = 0

    private let tasks: any TaskReading
    private let writer: any TaskWriting
    private let permissions: any MemberPermissions
    private let today: () -> CalendarDay
    private let onUnauthorized: @MainActor () -> Void
    private let onStatusChanged: @MainActor () -> Void

    /// - Parameters:
    ///   - today: Der Kalendertag des Geräts; in Tests fest.
    ///   - onUnauthorized: Das Credential ist widerrufen, etwa `SessionState.handle(.unauthorized, from:)`.
    ///   - onStatusChanged: Ein Abhaken oder Wieder öffnen ist beim Server, in der Liste oder im
    ///     Detail. Die App gleicht danach die Erinnerungen ab (Q10).
    public init(
        tasks: any TaskReading, writer: any TaskWriting, permissions: any MemberPermissions,
        today: @escaping () -> CalendarDay, onUnauthorized: @escaping @MainActor () -> Void,
        onStatusChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.tasks = tasks
        self.writer = writer
        self.permissions = permissions
        self.today = today
        self.onUnauthorized = onUnauthorized
        self.onStatusChanged = onStatusChanged
    }

    public func load() async {
        generation += 1
        let mine = generation
        let mark = overlay.mark
        // Die Rechte laufen neben der Liste her. Ohne Antwort bleibt es beim bisherigen Stand,
        // anfangs erlaubt: Der Server prüft ohnehin (Q4).
        async let mayWrite = try? await permissions.mayWriteTasks()
        do throws(APIError) {
            var all = try await tasks.tasks()
            let may = await mayWrite
            guard mine == generation else { return }
            // `/tasks` kann älter sein als ein Abhaken, das noch läuft oder seit dem Start fertig
            // wurde: dessen Ziel gilt weiter, und zwar vor dem Filtern der erledigten. Sonst
            // fehlte eine gerade wieder geöffnete Zeile, die die Antwort noch als erledigt kennt.
            let overlaid = overlay.statuses(since: mark)
            for i in all.indices { if let status = overlaid[all[i].id] { all[i].status = status } }
            state = .loaded(Self.sections(all, today: today(), keeping: Set(overlaid.keys)))
            canWrite = may ?? canWrite
            refreshProblem = nil
            notice = nil
        } catch .unauthorized {
            onUnauthorized()
        } catch {
            guard mine == generation else { return }
            let problem: Problem = error == .unreachable ? .unreachable : .unexpectedResponse
            if case .loaded = state {
                refreshProblem = problem
            } else {
                state = .failed(problem)
            }
        }
    }

    /// Abhaken oder wieder öffnen, je nach Stand der Zeile. Optimistisch: Der Kreis wechselt
    /// sofort und springt bei einem Fehler zurück (Q3, Q13). Die abgehakte Zeile bleibt bis
    /// zum nächsten Laden stehen (Q14).
    public func toggle(_ id: Int) async {
        guard await write(id) else { return }
        // Ein offenes Detail derselben Aufgabe hat womöglich vor dem Wechsel geladen und
        // böte sonst weiter das Falsche an (Codex-Review E3).
        await details[id]?.load()
    }

    /// Der Statuswechsel selbst. `true`, wenn der Server ihn bestätigt hat.
    private func write(_ id: Int) async -> Bool {
        guard canWrite, !overlay.isWriting(id), let before = summary(id) else { return false }
        let target: TaskStatus = before.status == .done ? .open : .done
        notice = nil
        overlay.begin(id, to: target)
        writing = overlay.writing
        var confirmed: TaskStatus?
        defer {
            overlay.finish(id, confirmed: confirmed)
            writing = overlay.writing
        }
        update(id) { $0.status = target }
        do throws(APIError) {
            _ = try await writer.setStatus(task: id, to: target)
            confirmed = target
            // Ein Laden, das inzwischen ankam, kann den Haken überschrieben haben.
            update(id) { $0.status = target }
            onStatusChanged()
            return true
        } catch .unauthorized {
            onUnauthorized()
        } catch .notFound {
            remove(id)
            notice = .gone
        } catch {
            update(id) { $0.status = before.status }
            if error == .forbidden { canWrite = false }
            notice = TaskNotice(error)
        }
        return false
    }

    private func summary(_ id: Int) -> TaskSummary? {
        guard case .loaded(let sections) = state else { return nil }
        return sections.lazy.flatMap(\.tasks).first { $0.id == id }
    }

    /// Ändert eine Zeile an ihrem Platz. Ein Neuladen dazwischen kann sie entfernt haben.
    private func update(_ id: Int, _ change: (inout TaskSummary) -> Void) {
        guard case .loaded(var sections) = state else { return }
        for s in sections.indices {
            for t in sections[s].tasks.indices where sections[s].tasks[t].id == id {
                change(&sections[s].tasks[t])
            }
        }
        state = .loaded(sections)
    }

    private func remove(_ id: Int) {
        guard case .loaded(let sections) = state else { return }
        state = .loaded(sections.compactMap { section in
            var section = section
            section.tasks.removeAll { $0.id == id }
            return section.tasks.isEmpty ? nil : section
        })
    }

    /// Das Detail zu einer Aufgabe. Solange sie im Pfad steht, behält sie ihr Modell: SwiftUI
    /// fragt beim Neuzeichnen erneut, und das Detail soll nicht jedes Mal neu laden.
    public func detail(for id: Int) -> TaskDetailModel {
        if let model = details[id] { return model }
        let model = TaskDetailModel(
            taskID: id, tasks: tasks, writer: writer,
            mayWrite: { [weak self] in self?.canWrite ?? false },
            onUnauthorized: onUnauthorized,
            // Das Detail bleibt offen, die Liste dahinter lädt neu (Q12).
            onStatusChanged: { [weak self] in
                guard let self else { return }
                onStatusChanged()
                Task { await self.load() }
            },
            onForbidden: { [weak self] in self?.canWrite = false },
            onGone: { [weak self] in self?.close(id) }
        )
        details[id] = model
        return model
    }

    /// Die Aufgabe gibt es nicht mehr: Detail zu, Zeile weg, Hinweis in der Liste (Q8, Q12).
    public func close(_ id: Int) {
        path.removeAll { $0 == id }
        remove(id)
        notice = .gone
    }

    /// - Parameter keeping: Ids, die auch erledigt stehen bleiben: gerade in der App abgehakt (Q14).
    static func sections(_ all: [TaskSummary], today: CalendarDay, keeping: Set<Int> = []) -> [TaskSection] {
        let open = all
            .filter { $0.status != .done || keeping.contains($0.id) }
            .sorted(by: dueFirst)
        func kind(of task: TaskSummary) -> TaskSection.Kind {
            guard let due = task.due else { return .noDate }
            return due < today ? .overdue : due == today ? .today : .upcoming
        }
        let order: [TaskSection.Kind] = [.overdue, .today, .upcoming, .noDate]
        return order.compactMap { section in
            let tasks = open.filter { kind(of: $0) == section }
            return tasks.isEmpty ? nil : TaskSection(kind: section, tasks: tasks)
        }
    }
}

/// Früher fällig zuerst, am selben Tag ganztägig vor Uhrzeit, ohne Datum ans Ende.
private func dueFirst(_ lhs: TaskSummary, _ rhs: TaskSummary) -> Bool {
    switch (lhs.due, rhs.due) {
    case let (l?, r?) where l != r: l < r
    case (.some, nil): true
    case (nil, _), (_, nil): false
    default: (lhs.dueTime ?? "") < (rhs.dueTime ?? "")
    }
}
