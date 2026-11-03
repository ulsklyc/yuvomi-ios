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
        do throws(APIError) {
            state = .loaded(Self.sections(try await tasks.tasks(), today: today()))
            refreshProblem = nil
        } catch .unauthorized {
            onUnauthorized()
        } catch {
            let problem: Problem = error == .unreachable ? .unreachable : .unexpectedResponse
            if case .loaded = state {
                refreshProblem = problem
            } else {
                state = .failed(problem)
            }
        }
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
