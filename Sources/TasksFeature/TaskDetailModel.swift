import Foundation
import Observation
import YuvomiCore

/// Zustand des Details einer Aufgabe. Eines je geöffneter Aufgabe, gebaut von `TaskListModel`.
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
    public private(set) var state: State = .loading
    /// Neuladen ist gescheitert, das alte Detail bleibt sichtbar.
    public private(set) var refreshProblem: Problem?

    /// Wie in `TaskListModel`: Nur die Antwort des jüngsten Ladevorgangs zählt.
    private var generation = 0
    private let tasks: any TaskReading
    private let onUnauthorized: @MainActor () -> Void

    public init(taskID: Int, tasks: any TaskReading, onUnauthorized: @escaping @MainActor () -> Void) {
        self.taskID = taskID
        self.tasks = tasks
        self.onUnauthorized = onUnauthorized
    }

    public func load() async {
        generation += 1
        let mine = generation
        // Nach einem Fehler zeigt „Erneut versuchen“ wieder den Ladekreis.
        if case .failed = state { state = .loading }
        do throws(APIError) {
            let task = try await tasks.task(id: taskID)
            guard mine == generation else { return }
            state = .loaded(task)
            refreshProblem = nil
        } catch .unauthorized {
            onUnauthorized()
        } catch .notFound {
            guard mine == generation else { return }
            state = .gone
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
}
