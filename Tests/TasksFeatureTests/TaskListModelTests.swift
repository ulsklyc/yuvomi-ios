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
}

func task(_ id: Int, due: CalendarDay? = nil, time: String? = nil, status: TaskStatus = .open) -> TaskSummary {
    TaskSummary(id: id, title: "Aufgabe \(id)", status: status, priority: .none, due: due, dueTime: time, assignees: [])
}

@MainActor @Suite struct TaskListModelTests {
    let today = CalendarDay(year: 2026, month: 11, day: 3)

    func model(_ tasks: FakeTasks, onUnauthorized: @escaping @MainActor () -> Void = {}) -> TaskListModel {
        TaskListModel(tasks: tasks, today: { today }, onUnauthorized: onUnauthorized)
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
