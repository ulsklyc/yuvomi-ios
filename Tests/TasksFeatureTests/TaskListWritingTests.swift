import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 3: Abhaken und Wieder öffnen in der Liste, Nur-lesen und Fehler nach Q13.
@MainActor @Suite struct TaskListWritingTests {
    let writer = FakeWriter()

    func loadedList(
        _ tasks: [TaskSummary] = [task(1), task(2)],
        permissions: FakePermissions = FakePermissions(),
        onUnauthorized: @escaping @MainActor () -> Void = {},
        onStatusChanged: @escaping @MainActor () -> Void = {}
    ) async -> TaskListModel {
        let list = TaskListModel(
            tasks: FakeTasks(.success(tasks)), writer: writer, permissions: permissions,
            today: { CalendarDay(year: 2026, month: 11, day: 3) },
            onUnauthorized: onUnauthorized, onStatusChanged: onStatusChanged
        )
        await list.load()
        return list
    }

    /// Abgehakt bleibt die Zeile stehen, bis die Liste das nächste Mal lädt (Q2, Q14).
    @Test func checkingOffKeepsTheRowCrossedOut() async {
        var changed = 0
        let list = await loadedList(onStatusChanged: { changed += 1 })

        await list.toggle(1)

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1, status: .done), task(2)])]))
        #expect(writer.calls.withLock { $0 } == ["status 1 done"])
        #expect(changed == 1)
    }

    @Test func tappingAgainReopens() async {
        let list = await loadedList()
        await list.toggle(1)
        writer.status.withLock { $0 = .success(StatusChange(status: .open)) }

        await list.toggle(1)

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1), task(2)])]))
        #expect(writer.calls.withLock { $0 } == ["status 1 done", "status 1 open"])
    }

    /// „In Arbeit“ hakt direkt ab (Q6).
    @Test func aTaskInProgressIsCheckedOff() async {
        let list = await loadedList([task(1, status: .inProgress)])
        await list.toggle(1)
        #expect(writer.calls.withLock { $0 } == ["status 1 done"])
    }

    /// Optimistisch: Der Haken steht sofort, die Zeile ist gesperrt, bis die Antwort da ist.
    @Test func theRowIsLockedWhileWriting() async {
        let list = await loadedList()
        writer.hold()

        let writing = Task { await list.toggle(1) }
        await writer.untilWaiting()
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1, status: .done), task(2)])]))
        #expect(list.writing == [1])
        await list.toggle(1)
        writer.release()
        await writing.value

        #expect(writer.calls.withLock { $0 } == ["status 1 done"])
        #expect(list.writing.isEmpty)
    }

    @Test(arguments: [(APIError.unreachable, TaskNotice.unreachable), (.unexpectedResponse, .unexpectedResponse), (.conflict, .unexpectedResponse)])
    func aFailedWriteSpringsBack(error: APIError, notice: TaskNotice) async {
        var changed = 0
        let list = await loadedList(onStatusChanged: { changed += 1 })
        writer.status.withLock { $0 = .failure(error) }

        await list.toggle(1)

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1), task(2)])]))
        #expect(list.notice == notice)
        #expect(changed == 0)
    }

    /// 403: zurück, Hinweis, und ab jetzt keine Kreise mehr.
    @Test func forbiddenSwitchesToReadOnly() async {
        let list = await loadedList()
        writer.status.withLock { $0 = .failure(.forbidden) }

        await list.toggle(1)
        await list.toggle(2)

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1), task(2)])]))
        #expect(list.notice == .readOnly)
        #expect(list.canWrite == false)
        #expect(writer.calls.withLock { $0 } == ["status 1 done"])
    }

    @Test func aDeletedTaskLeavesTheList() async {
        let list = await loadedList()
        writer.status.withLock { $0 = .failure(.notFound) }

        await list.toggle(1)

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(2)])]))
        #expect(list.notice == .gone)
    }

    @Test func aRevokedCredentialSignsOut() async {
        var signedOut = false
        let list = await loadedList(onUnauthorized: { signedOut = true })
        writer.status.withLock { $0 = .failure(.unauthorized) }

        await list.toggle(1)

        #expect(signedOut)
    }

    /// Mit `tasks: read` bietet die Liste kein Abhaken an (Q4).
    @Test func readPermissionMeansNoCheckingOff() async {
        let list = await loadedList(permissions: FakePermissions(result: .success(false)))

        await list.toggle(1)

        #expect(list.canWrite == false)
        #expect(writer.calls.withLock { $0 }.isEmpty)
    }

    /// Scheitert `/auth/me`, gilt Schreiben als erlaubt: Der Server prüft ohnehin.
    @Test func unknownPermissionsAllowWriting() async {
        let list = await loadedList(permissions: FakePermissions(result: .failure(.unreachable)))
        #expect(list.canWrite)
    }

    /// Ein neuer Versuch räumt den alten Hinweis weg.
    @Test func theNextWriteClearsTheNotice() async {
        let list = await loadedList()
        writer.status.withLock { $0 = .failure(.unreachable) }
        await list.toggle(1)
        writer.status.withLock { $0 = .success(StatusChange(status: .done)) }

        await list.toggle(1)

        #expect(list.notice == nil)
    }
}
