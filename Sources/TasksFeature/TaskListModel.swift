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

/// Zustand der Aufgabenliste, nur lesend.
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

    /// Zählt die Ladevorgänge. Nur die Antwort des jüngsten zählt: Eine ältere, die später
    /// ankommt, zeigte sonst etwa eine gerade abgehakte Aufgabe wieder offen.
    private var generation = 0

    private let tasks: any TaskReading
    private let today: () -> CalendarDay
    private let onUnauthorized: @MainActor () -> Void

    /// - Parameters:
    ///   - today: Der Kalendertag des Geräts; in Tests fest.
    ///   - onUnauthorized: Das Credential ist widerrufen, etwa `SessionState.handle(.unauthorized, from:)`.
    public init(tasks: any TaskReading, today: @escaping () -> CalendarDay, onUnauthorized: @escaping @MainActor () -> Void) {
        self.tasks = tasks
        self.today = today
        self.onUnauthorized = onUnauthorized
    }

    public func load() async {
        generation += 1
        let mine = generation
        do throws(APIError) {
            let all = try await tasks.tasks()
            guard mine == generation else { return }
            state = .loaded(Self.sections(all, today: today()))
            refreshProblem = nil
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

    /// Das Detail zu einer Aufgabe. Solange sie im Pfad steht, behält sie ihr Modell: SwiftUI
    /// fragt beim Neuzeichnen erneut, und das Detail soll nicht jedes Mal neu laden.
    public func detail(for id: Int) -> TaskDetailModel {
        if let model = details[id] { return model }
        let model = TaskDetailModel(taskID: id, tasks: tasks, onUnauthorized: onUnauthorized)
        details[id] = model
        return model
    }

    static func sections(_ all: [TaskSummary], today: CalendarDay) -> [TaskSection] {
        let open = all
            .filter { $0.status != .done }
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
