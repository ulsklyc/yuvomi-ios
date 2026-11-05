import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 4, Schreiben: Abhaken, Unteraufgaben und Ankreuzen im Detail (Q12, Q13).
@MainActor @Suite struct TaskDetailWritingTests {
    let reading = FakeDetail(.success(packing))
    let writer = FakeWriter()

    final class Calls {
        var statusChanged = 0
        var forbidden = 0
        var gone = 0
        var signedOut = 0
    }
    let calls = Calls()

    func loadedDetail(mayWrite: Bool = true) async -> TaskDetailModel {
        let calls = calls
        let detail = TaskDetailModel(
            taskID: 24, tasks: reading, writer: writer,
            mayWrite: { mayWrite },
            onUnauthorized: { calls.signedOut += 1 },
            onStatusChanged: { calls.statusChanged += 1 },
            onForbidden: { calls.forbidden += 1 },
            onGone: { calls.gone += 1 }
        )
        await detail.load()
        return detail
    }

    func task(of detail: TaskDetailModel) -> TaskDetail? {
        guard case .loaded(let task) = detail.state else { return nil }
        return task
    }

    /// Abhaken lässt das Detail offen. Setzt es eine Serie fort, steht das nächste Mal da.
    @Test func checkingOffShowsTheNextTime() async {
        let next = CalendarDay(year: 2026, month: 11, day: 10)
        writer.status.withLock { $0 = .success(StatusChange(status: .done, nextDue: next)) }
        let detail = await loadedDetail()

        await detail.toggleStatus()

        #expect(task(of: detail)?.status == .done)
        #expect(detail.nextDue == next)
        #expect(writer.calls.withLock { $0 } == ["status 24 done"])
        #expect(calls.statusChanged == 1)
    }

    @Test func reopeningForgetsTheNextTime() async {
        writer.status.withLock { $0 = .success(StatusChange(status: .done, nextDue: CalendarDay(year: 2026, month: 11, day: 10))) }
        let detail = await loadedDetail()
        await detail.toggleStatus()
        writer.status.withLock { $0 = .success(StatusChange(status: .open)) }

        await detail.toggleStatus()

        #expect(task(of: detail)?.status == .open)
        #expect(detail.nextDue == nil)
        #expect(writer.calls.withLock { $0 } == ["status 24 done", "status 24 open"])
    }

    @Test func aSubtaskIsCheckedOffWithItsOwnID() async {
        let detail = await loadedDetail()

        await detail.toggleSubtask(25)

        #expect(task(of: detail)?.subtasks.first?.status == .done)
        #expect(task(of: detail)?.status == .open)
        #expect(writer.calls.withLock { $0 } == ["status 25 done"])
        #expect(calls.statusChanged == 1)
    }

    @Test func aFailedCheckOffSpringsBack() async {
        writer.status.withLock { $0 = .failure(.unreachable) }
        let detail = await loadedDetail()

        await detail.toggleStatus()
        await detail.toggleSubtask(25)

        #expect(task(of: detail) == packing)
        #expect(detail.notice == .unreachable)
        #expect(calls.statusChanged == 0)
    }

    /// Ein Neuladen während des Abhakens überschreibt den Wechsel nicht, weder solange er läuft
    /// noch wenn die Antwort des Ladens erst danach kommt (Codex-Review E3).
    @Test func aRefreshDuringCheckingOffKeepsIt() async {
        let detail = await loadedDetail()
        writer.hold()
        let writing = Task { await detail.toggleStatus() }
        await writer.untilWaiting()
        await detail.load()
        #expect(task(of: detail)?.status == .done)

        reading.gate.close()
        let loading = Task { await detail.load() }
        await reading.gate.untilWaiting()
        writer.release()
        await writing.value
        reading.gate.open()
        await loading.value

        #expect(task(of: detail)?.status == .done)
    }

    /// Ein Neuladen, das vor dem Ankreuzen begann und erst danach ankommt, nimmt den Haken
    /// nicht zurück (Codex-Review E3).
    @Test func aLoadOlderThanATickKeepsIt() async {
        writer.tick.withLock { $0 = .success("- [x] Pack sleeping bags") }
        let detail = await loadedDetail()
        reading.gate.close()
        let loading = Task { await detail.load() }
        await reading.gate.untilWaiting()

        await detail.tick(line: 0)
        reading.gate.open()
        await loading.value

        #expect(task(of: detail)?.description == "- [x] Pack sleeping bags")
    }

    /// Immer nur ein Punkt auf einmal: Jede Antwort ist die ganze Beschreibung.
    @Test func onlyOnePointIsTickedAtATime() async {
        reading.result.withLock { $0 = .success(TaskDetail(id: 24, title: "x", status: .open, priority: .none, description: "- [ ] A\n- [ ] B")) }
        writer.tick.withLock { $0 = .success("- [x] A\n- [ ] B") }
        let detail = await loadedDetail()
        writer.hold()

        let first = Task { await detail.tick(line: 0) }
        await writer.untilWaiting()
        await detail.tick(line: 1)
        writer.release()
        await first.value

        #expect(writer.calls.withLock { $0 } == ["tick 24 0 true - [ ] A"])
    }

    /// Ankreuzen schickt die Zeile, wie die Person sie sah, und übernimmt die Antwort.
    @Test func tickingTakesTheServersDescription() async {
        writer.tick.withLock { $0 = .success("- [x] Pack sleeping bags") }
        let detail = await loadedDetail()

        await detail.tick(line: 0)

        #expect(task(of: detail)?.description == "- [x] Pack sleeping bags")
        #expect(writer.calls.withLock { $0 } == ["tick 24 0 true - [ ] Pack sleeping bags"])
        #expect(calls.statusChanged == 0)
    }

    /// Das nächste `expect` kommt aus dem Text nach der letzten Antwort.
    @Test func theNextTickExpectsTheLastText() async {
        writer.tick.withLock { $0 = .success("- [x] Pack sleeping bags") }
        let detail = await loadedDetail()
        await detail.tick(line: 0)
        writer.tick.withLock { $0 = .success("- [ ] Pack sleeping bags") }

        await detail.tick(line: 0)

        #expect(writer.calls.withLock { $0 }.last == "tick 24 0 false - [x] Pack sleeping bags")
    }

    /// Während die Anfrage läuft, steht der Haken schon, und das Kästchen ist gesperrt.
    @Test func aTickIsShownAtOnceAndLocked() async {
        writer.tick.withLock { $0 = .success("- [x] Pack sleeping bags") }
        let detail = await loadedDetail()
        writer.hold()

        let ticking = Task { await detail.tick(line: 0) }
        await writer.untilWaiting()
        #expect(detail.ticking == [0: true])
        await detail.tick(line: 0)
        writer.release()
        await ticking.value

        #expect(writer.calls.withLock { $0 }.count == 1)
        #expect(detail.ticking.isEmpty)
    }

    /// 409: Die Beschreibung hat sich geändert. Das Detail lädt neu, statt falsch zu haken.
    @Test func aConflictReloads() async {
        writer.tick.withLock { $0 = .failure(.conflict) }
        let detail = await loadedDetail()
        let changed = TaskDetail(id: 24, title: packing.title, status: .open, priority: .medium, description: "- [ ] Pack sleeping bags\n- [ ] Pack food")
        reading.result.withLock { $0 = .success(changed) }

        await detail.tick(line: 0)

        #expect(detail.state == .loaded(changed))
        #expect(detail.notice == .changed)
        #expect(detail.ticking.isEmpty)
        #expect(reading.requested.withLock { $0 } == [24, 24])
    }

    @Test func aFailedTickSpringsBack() async {
        writer.tick.withLock { $0 = .failure(.unreachable) }
        let detail = await loadedDetail()

        await detail.tick(line: 0)

        #expect(task(of: detail) == packing)
        #expect(detail.ticking.isEmpty)
        #expect(detail.notice == .unreachable)
    }

    /// Nur die Unteraufgabe ist weg: Sie verschwindet, das Detail bleibt offen.
    @Test func aDeletedSubtaskLeavesOnlyTheSubtask() async {
        writer.status.withLock { $0 = .failure(.notFound) }
        let detail = await loadedDetail()

        await detail.toggleSubtask(25)

        #expect(task(of: detail)?.subtasks.isEmpty == true)
        #expect(detail.notice == .gone)
        #expect(calls.gone == 0)
    }

    /// Ein Neuladen, das vor dem 404 einer Unteraufgabe begann und erst danach ankommt, holt sie
    /// nicht zurück (Issue #24).
    @Test func aLoadOlderThanADeletedSubtaskKeepsItAway() async {
        writer.status.withLock { $0 = .failure(.notFound) }
        let detail = await loadedDetail()
        reading.gate.close()
        let loading = Task { await detail.load() }
        await reading.gate.untilWaiting()

        await detail.toggleSubtask(25)
        reading.gate.open()
        await loading.value

        #expect(task(of: detail)?.subtasks.isEmpty == true)
    }

    /// Scheitert das Neuladen nach einem 409, steht der Fehler da, nicht „Hier ist sie neu“.
    @Test func aConflictWhoseReloadFailsSaysSo() async {
        writer.tick.withLock { $0 = .failure(.conflict) }
        let detail = await loadedDetail()
        reading.result.withLock { $0 = .failure(.unreachable) }

        await detail.tick(line: 0)

        #expect(detail.notice == nil)
        #expect(detail.refreshProblem == .unreachable)
    }

    /// 403: Hinweis, und die Liste schaltet auf Nur-lesen.
    @Test func forbiddenSwitchesToReadOnly() async {
        writer.status.withLock { $0 = .failure(.forbidden) }
        let detail = await loadedDetail()

        await detail.toggleStatus()

        #expect(task(of: detail) == packing)
        #expect(detail.notice == .readOnly)
        #expect(calls.forbidden == 1)
    }

    /// 404 beim Schreiben schließt das Detail, den Hinweis zeigt die Liste.
    @Test func aDeletedTaskClosesTheDetail() async {
        writer.tick.withLock { $0 = .failure(.notFound) }
        let detail = await loadedDetail()

        await detail.tick(line: 0)

        #expect(calls.gone == 1)
    }

    @Test func readOnlyMeansNoWriting() async {
        let detail = await loadedDetail(mayWrite: false)

        await detail.toggleStatus()
        await detail.toggleSubtask(25)
        await detail.tick(line: 0)

        #expect(writer.calls.withLock { $0 }.isEmpty)
    }

    @Test func aRevokedCredentialSignsOut() async {
        writer.status.withLock { $0 = .failure(.unauthorized) }
        let detail = await loadedDetail()

        await detail.toggleStatus()

        #expect(calls.signedOut == 1)
    }

    /// Eine Zeile ohne Kästchen lässt sich nicht ankreuzen.
    @Test func onlyChecklistLinesCanBeTicked() async {
        reading.result.withLock { $0 = .success(TaskDetail(id: 24, title: "x", status: .open, priority: .none, description: "Leave early\n- [ ] Pack")) }
        let detail = await loadedDetail()

        await detail.tick(line: 0)
        await detail.tick(line: 7)

        #expect(writer.calls.withLock { $0 }.isEmpty)
    }
}
