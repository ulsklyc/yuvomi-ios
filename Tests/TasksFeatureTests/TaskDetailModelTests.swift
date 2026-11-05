import Foundation
import Synchronization
import Testing
@testable import TasksFeature
import YuvomiCore

/// Liefert ein Detail oder einen Fehler, umstellbar zwischen zwei Ladevorgängen.
final class FakeDetail: TaskReading, Sendable {
    let result: Mutex<Result<TaskDetail, APIError>>
    let requested = Mutex<[Int]>([])

    init(_ result: Result<TaskDetail, APIError>) {
        self.result = Mutex(result)
    }

    func tasks() async throws(APIError) -> [TaskSummary] { [] }

    let gate = Gate()

    func task(id: Int) async throws(APIError) -> TaskDetail {
        requested.withLock { $0.append(id) }
        let result = result.withLock { $0 }
        await gate.pass()
        return try result.get()
    }
}

let packing = TaskDetail(
    id: 24, title: "Pack for the weekend trip", status: .open, priority: .medium,
    description: "- [ ] Pack sleeping bags",
    subtasks: [TaskSummary(id: 25, title: "Check the car tyres", status: .open, priority: .none, due: nil, dueTime: nil, assignees: [])],
    points: 5
)

/// Seam 4, Laden: Was das Detail nach `load()` zeigt.
@MainActor @Suite struct TaskDetailModelTests {
    func model(_ reading: FakeDetail, onUnauthorized: @escaping @MainActor () -> Void = {}) -> TaskDetailModel {
        TaskDetailModel(taskID: 24, tasks: reading, writer: FakeWriter(), onUnauthorized: onUnauthorized)
    }

    @Test func loadsTheTask() async {
        let reading = FakeDetail(.success(packing))
        let detail = model(reading)
        #expect(detail.state == .loading)

        await detail.load()

        #expect(detail.state == .loaded(packing))
        #expect(reading.requested.withLock { $0 } == [24])
    }

    /// Gelöscht oder privat gestellt: kein Fehler mit „Erneut versuchen“, sondern die Auskunft.
    @Test func aDeletedTaskIsGone() async {
        let detail = model(FakeDetail(.failure(.notFound)))
        await detail.load()
        #expect(detail.state == .gone)
    }

    @Test(arguments: [(APIError.unreachable, TaskDetailModel.Problem.unreachable), (.unexpectedResponse, .unexpectedResponse), (.forbidden, .unexpectedResponse)])
    func aFailedFirstLoadShowsTheProblem(error: APIError, problem: TaskDetailModel.Problem) async {
        let detail = model(FakeDetail(.failure(error)))
        await detail.load()
        #expect(detail.state == .failed(problem))
    }

    @Test func aRevokedCredentialSignsOut() async {
        var signedOut = false
        let detail = model(FakeDetail(.failure(.unauthorized)), onUnauthorized: { signedOut = true })
        await detail.load()
        #expect(signedOut)
    }

    /// Neu laden ohne Netz: Das Detail bleibt stehen, dazu ein Hinweis.
    @Test func aFailedRefreshKeepsTheTask() async {
        let reading = FakeDetail(.success(packing))
        let detail = model(reading)
        await detail.load()
        reading.result.withLock { $0 = .failure(.unreachable) }

        await detail.load()

        #expect(detail.state == .loaded(packing))
        #expect(detail.refreshProblem == .unreachable)
    }

    /// Zurück zur Liste, bevor die Antwort da ist: Der Abbruch ist kein Verbindungsfehler.
    @Test func aCancelledLoadIsNoProblem() async {
        let detail = model(FakeDetail(.failure(.unreachable)))
        let loading = Task { await detail.load() }
        loading.cancel()
        await loading.value
        #expect(detail.state == .loading)
    }

    /// Weg ist weg, auch wenn vorher etwas zu sehen war: Die Aufgabe gibt es nicht mehr.
    @Test func aTaskDeletedWhileOpenIsGone() async {
        let reading = FakeDetail(.success(packing))
        let detail = model(reading)
        await detail.load()
        reading.result.withLock { $0 = .failure(.notFound) }

        await detail.load()

        #expect(detail.state == .gone)
    }
}

/// Der Weg aus der Liste: `path` ist die Bindung der Navigation, auch für die Mitteilung (E4).
@MainActor @Suite struct TaskListOpeningTests {
    @Test func openingATaskMakesOneDetailForIt() async {
        let list = TaskListModel(tasks: FakeDetail(.success(packing)), writer: FakeWriter(), permissions: FakePermissions(), today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {})

        list.path = [24]
        let first = list.detail(for: 24)
        let again = list.detail(for: 24)

        #expect(first === again)
        #expect(first.taskID == 24)
        #expect(list.detail(for: 25) !== first)
    }

    /// Zwei Ziele im Stapel, etwa eine Mitteilung über einem offenen Detail: Jedes behält sein Modell.
    @Test func twoOpenTasksKeepTheirDetails() async {
        let list = TaskListModel(tasks: FakeDetail(.success(packing)), writer: FakeWriter(), permissions: FakePermissions(), today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {})

        list.path = [24, 31]
        let first = list.detail(for: 24)
        let second = list.detail(for: 31)

        #expect(list.detail(for: 24) === first)
        #expect(list.detail(for: 31) === second)
    }

    /// Zurück auf der Liste: Die Modelle der geschlossenen Aufgaben fallen weg.
    @Test func closingATaskDropsItsDetail() async {
        let list = TaskListModel(tasks: FakeDetail(.success(packing)), writer: FakeWriter(), permissions: FakePermissions(), today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {})
        list.path = [24]
        let first = list.detail(for: 24)

        list.path = []
        list.path = [24]

        #expect(list.detail(for: 24) !== first)
    }
}

/// Die Beschreibung in Blöcken: Text zusammen, jeder Punkt der Checkliste für sich.
@Suite struct DescriptionBlockTests {
    @Test func groupsTextAndKeepsEachPointOnItsOwn() {
        let blocks = DescriptionBlock.blocks(of: Checklist(description: "\nLeave by **5 pm**.\nBring cash.\n\n- [x] Book\n- [ ] Pack\n\nThanks\n\n"))

        #expect(blocks == [
            .text("Leave by **5 pm**.\nBring cash."),
            .point(Checklist.Point(index: 4, raw: "- [x] Book", isChecked: true, text: "Book")),
            .point(Checklist.Point(index: 5, raw: "- [ ] Pack", isChecked: false, text: "Pack")),
            .text("Thanks"),
        ])
    }

    @Test func aBlankDescriptionHasNoBlocks() {
        #expect(DescriptionBlock.blocks(of: Checklist(description: " \n\n")).isEmpty)
        #expect(DescriptionBlock.blocks(of: Checklist(description: nil)).isEmpty)
    }
}
