import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Port-Fake: was `GET /tasks` liefert.
final class FakeTasks: TaskReading, @unchecked Sendable {
    var result: Result<[TaskSummary], APIError>

    init(_ result: Result<[TaskSummary], APIError>) {
        self.result = result
    }

    func tasks() async throws(APIError) -> [TaskSummary] { try result.get() }
    func task(id: Int) async throws(APIError) -> TaskDetail { throw .notFound }
}

func task(_ id: Int, due: CalendarDay? = nil, time: String? = nil, status: TaskStatus = .open) -> TaskSummary {
    TaskSummary(id: id, title: "Aufgabe \(id)", status: status, priority: .none, due: due, dueTime: time, assignees: [])
}

@MainActor @Suite struct TaskListModelTests {
    let today = CalendarDay(year: 2026, month: 11, day: 3)

    func model(_ tasks: FakeTasks, onUnauthorized: @escaping @MainActor () -> Void = {}) -> TaskListModel {
        TaskListModel(tasks: tasks, writer: FakeWriter(), permissions: FakePermissions(), today: { today }, onUnauthorized: onUnauthorized)
    }

    @Test func openTasksAreGroupedByDueDate() async {
        let list = model(FakeTasks(.success([
            task(1, due: CalendarDay(year: 2026, month: 11, day: 10)),
            task(2),
            task(3, due: CalendarDay(year: 2026, month: 11, day: 3), time: "18:00"),
            task(4, due: CalendarDay(year: 2026, month: 10, day: 30)),
            task(5, due: CalendarDay(year: 2026, month: 11, day: 3), status: .done),
            task(6, due: CalendarDay(year: 2026, month: 11, day: 3), time: "08:30", status: .inProgress),
            task(7, due: CalendarDay(year: 2026, month: 11, day: 4)),
        ])))

        await list.load()

        #expect(list.state == .loaded([
            TaskSection(kind: .overdue, tasks: [task(4, due: CalendarDay(year: 2026, month: 10, day: 30))]),
            TaskSection(kind: .today, tasks: [
                task(6, due: CalendarDay(year: 2026, month: 11, day: 3), time: "08:30", status: .inProgress),
                task(3, due: CalendarDay(year: 2026, month: 11, day: 3), time: "18:00"),
            ]),
            TaskSection(kind: .upcoming, tasks: [
                task(7, due: CalendarDay(year: 2026, month: 11, day: 4)),
                task(1, due: CalendarDay(year: 2026, month: 11, day: 10)),
            ]),
            TaskSection(kind: .noDate, tasks: [task(2)]),
        ]))
    }

    /// Ein unbekannter Status gilt nicht als erledigt: Die Aufgabe bleibt in der Liste.
    @Test func aTaskWithAnUnknownStatusStaysInTheList() async {
        let list = model(FakeTasks(.success([task(1, status: .unknown), task(2, status: .done)])))
        await list.load()
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1, status: .unknown)])]))
    }

    @Test func onlyDoneTasksLeaveAnEmptyList() async {
        let list = model(FakeTasks(.success([task(1, status: .done)])))
        await list.load()
        #expect(list.state == .loaded([]))
    }

    @Test(arguments: [(APIError.unreachable, TaskListModel.Problem.unreachable), (.unexpectedResponse, .unexpectedResponse)])
    func failedFirstLoadShowsTheProblem(error: APIError, expected: TaskListModel.Problem) async {
        let list = model(FakeTasks(.failure(error)))
        await list.load()
        #expect(list.state == .failed(expected))
    }

    @Test func revokedCredentialSignsOut() async {
        var signedOut = false
        let list = model(FakeTasks(.failure(.unauthorized)), onUnauthorized: { signedOut = true })

        await list.load()

        #expect(signedOut)
    }

    /// Pull-to-refresh ohne Netz: Die Liste bleibt stehen, dazu ein Hinweis.
    @Test func failedRefreshKeepsTheList() async {
        let tasks = FakeTasks(.success([task(2)]))
        let list = model(tasks)
        await list.load()
        tasks.result = .failure(.unreachable)

        await list.load()

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(2)])]))
        #expect(list.refreshProblem == .unreachable)

        tasks.result = .success([task(2)])
        await list.load()
        #expect(list.refreshProblem == nil)
    }
}

/// Port-Fake: Jeder Aufruf hat seine eigene Antwort, und der erste wartet, bis der Test ihn
/// freigibt. So kommt eine ältere Antwort nach einer jüngeren an.
final class SlowFirstTasks: TaskReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var release: CheckedContinuation<Void, Never>?
    private var released = false
    let first: [TaskSummary]
    let later: [TaskSummary]

    init(first: [TaskSummary], later: [TaskSummary]) {
        self.first = first
        self.later = later
    }

    func task(id: Int) async throws(APIError) -> TaskDetail { throw .notFound }

    func tasks() async throws(APIError) -> [TaskSummary] {
        let call = lock.withLock { calls += 1; return calls }
        guard call == 1 else { return later }
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if released { return true }
                release = continuation
                return false
            }
            if resume { continuation.resume() }
        }
        return first
    }

    func releaseFirst() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { release = nil }
            return release
        }
        continuation?.resume()
    }
}

@MainActor @Suite struct TaskListModelOrderTests {
    /// Eine ältere Antwort, die erst nach einer jüngeren ankommt, überschreibt sie nicht.
    /// Sonst zeigte die Liste nach dem Abhaken eine erledigte Aufgabe wieder offen.
    @Test func aSlowOlderAnswerDoesNotOverwriteANewerOne() async {
        let tasks = SlowFirstTasks(first: [task(1), task(2)], later: [task(2)])
        let list = TaskListModel(tasks: tasks, writer: FakeWriter(), permissions: FakePermissions(), today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {})

        let older = Task { await list.load() }
        for _ in 0..<10 { await Task.yield() }
        await list.load()
        tasks.releaseFirst()
        await older.value

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(2)])]))
    }
}
