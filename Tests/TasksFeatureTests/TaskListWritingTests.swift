import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 3: Abhaken und Wieder öffnen in der Liste, Nur-lesen und Fehler nach Q13.
@MainActor @Suite struct TaskListWritingTests {
    let writer = FakeWriter()

    let reading = FakeTasks(.success([task(1), task(2)]), detail: packing)

    func loadedList(
        _ tasks: [TaskSummary] = [task(1), task(2)],
        permissions: FakePermissions = FakePermissions(),
        onUnauthorized: @escaping @MainActor () -> Void = {},
        onStatusChanged: @escaping @MainActor () -> Void = {}
    ) async -> TaskListModel {
        let list = TaskListModel(
            tasks: reading, writer: writer, permissions: permissions,
            today: { CalendarDay(year: 2026, month: 11, day: 3) },
            onUnauthorized: onUnauthorized, onStatusChanged: onStatusChanged
        )
        reading.result = .success(tasks)
        await list.load()
        return list
    }

    /// Ein Laden, das vor dem Abhaken begann und erst danach ankommt, kennt den Haken nicht.
    /// Er bleibt trotzdem stehen (Codex-Review E3).
    @Test func aLoadOlderThanAFinishedWriteKeepsTheCheckMark() async {
        let list = await loadedList()
        reading.gate.close()
        let loading = Task { await list.load() }
        await reading.gate.untilWaiting()

        await list.toggle(1)
        reading.gate.open()
        await loading.value

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1, status: .done), task(2)])]))
    }

    /// Wieder öffnen, während ein Laden die Aufgabe noch als erledigt liefert: Die Zeile bleibt
    /// offen stehen, statt beim Filtern der erledigten zu verschwinden (Codex-Review E3).
    @Test func aLoadDuringReopeningKeepsTheRow() async {
        let list = await loadedList()
        await list.toggle(1)
        reading.result = .success([task(1, status: .done), task(2)])
        writer.status.withLock { $0 = .success(StatusChange(status: .open)) }
        writer.hold()
        let reopening = Task { await list.toggle(1) }
        await writer.untilWaiting()

        await list.load()
        writer.release()
        await reopening.value

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1), task(2)])]))
    }

    /// Abhaken in der Liste, während das Detail derselben Aufgabe offen ist: Das Detail lädt
    /// danach neu und bietet „Wieder öffnen“ an (Codex-Review E3).
    @Test func checkingOffInTheListRefreshesItsOpenDetail() async {
        let list = await loadedList([task(24), task(2)])
        let detail = list.detail(for: 24)
        await detail.load()
        var done = packing
        done.status = .done
        reading.detail = done

        await list.toggle(24)

        #expect(detail.state == .loaded(done))
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

    /// Lädt die Liste, während das Abhaken noch läuft, bleibt der Haken stehen: Die Antwort
    /// von `/tasks` kann älter sein als das Abhaken.
    @Test func aLoadDuringAWriteKeepsTheCheckMark() async {
        let list = await loadedList()
        writer.hold()

        let writing = Task { await list.toggle(1) }
        await writer.untilWaiting()
        await list.load()
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1, status: .done), task(2)])]))
        writer.release()
        await writing.value

        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1, status: .done), task(2)])]))
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

    /// Das Detail aus der Liste: 404 schließt es und nimmt die Zeile weg, 403 schaltet die
    /// ganze Liste auf Nur-lesen.
    @Test func aDetailThatIsGoneClosesInTheList() async {
        let list = await loadedList([task(24), task(2)])
        list.path = [24]
        let detail = list.detail(for: 24)
        await detail.load()
        writer.status.withLock { $0 = .failure(.notFound) }

        await detail.toggleStatus()

        #expect(list.path.isEmpty)
        #expect(list.notice == .gone)
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(2)])]))
    }

    /// Abhaken im Detail, zurück zur Liste und wieder hinein, bevor der Server antwortet: Das
    /// neue Detail lud womöglich vorher und lädt nach dem Wechsel neu (Codex-Review E3).
    @Test func aReopenedDetailRefreshesAfterTheEarlierWrite() async {
        let list = await loadedList([task(24), task(2)])
        list.path = [24]
        let first = list.detail(for: 24)
        await first.load()
        writer.hold()
        let writing = Task { await first.toggleStatus() }
        await writer.untilWaiting()

        list.path = []
        list.path = [24]
        let second = list.detail(for: 24)
        await second.load()
        var done = packing
        done.status = .done
        reading.detail = done
        writer.release()
        await writing.value
        for _ in 0..<100 where second.state != .loaded(done) { await Task.yield() }

        #expect(second !== first)
        #expect(second.state == .loaded(done))
    }

    /// Ebenso beim Ankreuzen: Das neu geöffnete Detail lädt nach der Antwort neu (Codex-Review E3).
    @Test func aReopenedDetailRefreshesAfterAnEarlierTick() async {
        let list = await loadedList([task(24), task(2)])
        list.path = [24]
        let first = list.detail(for: 24)
        await first.load()
        writer.tick.withLock { $0 = .success("- [x] Pack sleeping bags") }
        writer.hold()
        let ticking = Task { await first.tick(line: 0) }
        await writer.untilWaiting()

        list.path = []
        list.path = [24]
        let second = list.detail(for: 24)
        await second.load()
        var ticked = packing
        ticked.description = "- [x] Pack sleeping bags"
        reading.detail = ticked
        writer.release()
        await ticking.value
        for _ in 0..<100 where second.state != .loaded(ticked) { await Task.yield() }

        #expect(second.state == .loaded(ticked))
    }

    @Test func aForbiddenDetailMakesTheListReadOnly() async {
        let list = await loadedList([task(24)])
        list.path = [24]
        let detail = list.detail(for: 24)
        await detail.load()
        writer.status.withLock { $0 = .failure(.forbidden) }

        await detail.toggleStatus()

        #expect(list.canWrite == false)
        #expect(detail.canWrite == false)
    }
}
