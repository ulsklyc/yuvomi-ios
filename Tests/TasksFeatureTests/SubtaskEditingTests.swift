import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 4: Unteraufgaben im Detail anhängen und löschen (F4, Q5).
@MainActor @Suite struct SubtaskEditingTests {
    let reading = FakeDetail(.success(packing))
    let editor = FakeEditor()
    let writer = FakeWriter()

    final class Calls {
        var statusChanged = 0
        var forbidden = 0
        var gone = 0
    }
    let calls = Calls()

    func loadedDetail(mayWrite: Bool = true, memberID: Int? = 1) async -> TaskDetailModel {
        let calls = calls
        let detail = TaskDetailModel(
            taskID: 24, tasks: reading, writer: writer, editor: editor,
            mayWrite: { mayWrite }, memberID: { memberID },
            onUnauthorized: {},
            onStatusChanged: { calls.statusChanged += 1 },
            onForbidden: { calls.forbidden += 1 },
            onGone: { calls.gone += 1 }
        )
        await detail.load()
        return detail
    }

    func subtasks(_ detail: TaskDetailModel) -> [Int]? {
        guard case .loaded(let task) = detail.state else { return nil }
        return task.subtasks.map(\.id)
    }

    // MARK: Anhängen

    /// Q5: nur der Titel, mit der Aufgabe als Elternteil. Die Zeile hängt sich an, das Feld
    /// leert sich, Liste und Erinnerungen gleichen ab (Q11).
    @Test func addingAppendsTheSubtask() async {
        let detail = await loadedDetail()
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()

        let sent = editor.creates.withLock { $0 }
        #expect(sent.map(\.parent) == [24])
        var expected = TaskDraft()
        expected.title = "Buy snacks"
        #expect(sent.first?.draft == expected)
        #expect(subtasks(detail) == [25, 27])
        #expect(detail.newSubtaskTitle.isEmpty)
        #expect(calls.statusChanged == 1)
    }

    /// Q14: Dieselbe Eingabe schickt denselben Schlüssel wieder, eine geänderte einen neuen.
    /// Nach dem Erfolg bekommt die nächste Unteraufgabe einen eigenen.
    @Test func theKeyFollowsTheInput() async {
        let detail = await loadedDetail()
        editor.created.withLock { $0 = .failure(.unreachable) }
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()
        await detail.addSubtask()
        detail.newSubtaskTitle = "Buy drinks"
        await detail.addSubtask()
        editor.created.withLock { $0 = .success(task(27)) }
        await detail.addSubtask()
        detail.newSubtaskTitle = "Buy drinks"
        await detail.addSubtask()

        let keys = editor.creates.withLock { $0.map(\.key) }
        #expect(keys.count == 5)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
        #expect(keys[2] == keys[3])
        #expect(keys[3] != keys[4])
    }

    /// Q4: Bei einem Fehler bleibt die Eingabe stehen, der Hinweis steht im Detail.
    @Test func aFailureKeepsTheTitle() async {
        let detail = await loadedDetail()
        editor.created.withLock { $0 = .failure(.unreachable) }
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()

        #expect(detail.newSubtaskTitle == "Buy snacks")
        #expect(detail.notice == .unreachable)
        #expect(subtasks(detail) == [25])
        #expect(calls.statusChanged == 0)
    }

    /// Q13: 409 heißt „läuft noch, gleich nochmal“.
    @Test func aRunningAttemptAsksToRetry() async {
        let detail = await loadedDetail()
        editor.created.withLock { $0 = .failure(.conflict) }
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()

        #expect(detail.notice == .stillRunning)
        #expect(detail.newSubtaskTitle == "Buy snacks")
    }

    @Test(arguments: ["", "   ", String(repeating: "x", count: 201)])
    func anInvalidTitleSendsNothing(_ title: String) async {
        let detail = await loadedDetail()
        detail.newSubtaskTitle = title

        #expect(!detail.canAddSubtask)
        await detail.addSubtask()
        #expect(editor.creates.withLock { $0.isEmpty })
    }

    /// Q7: Bei Nur-lesen und bei gesperrt + fremd gibt es keine Unteraufgaben zum Anhängen
    /// oder Löschen.
    @Test(arguments: [false, true])
    func noSubtaskEditingWithoutTheRight(lockedByOthers: Bool) async {
        if lockedByOthers {
            var task = packing
            task.isLocked = true
            task.createdBy = 3
            reading.result.withLock { $0 = .success(task) }
        }
        let detail = await loadedDetail(mayWrite: lockedByOthers)
        detail.newSubtaskTitle = "Buy snacks"

        #expect(!detail.canAddSubtask)
        await detail.addSubtask()
        await detail.deleteSubtask(25)
        #expect(editor.creates.withLock { $0.isEmpty })
        #expect(editor.deletes.withLock { $0.isEmpty })
    }

    /// Q5: 404 heißt, die Aufgabe selbst ist weg. Das Detail schließt.
    @Test func aGoneParentClosesTheDetail() async {
        let detail = await loadedDetail()
        editor.created.withLock { $0 = .failure(.notFound) }
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()

        #expect(detail.state == .gone)
        #expect(calls.gone == 1)
    }

    /// Q5, Q13: 403 `task_locked` heißt, die Aufgabe ist inzwischen gesperrt. Hinweis, das
    /// Detail lädt neu.
    @Test func aLockedParentReloads() async {
        let detail = await loadedDetail()
        editor.created.withLock { $0 = .failure(.locked) }
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()

        #expect(detail.notice == .locked)
        #expect(reading.requested.withLock { $0 } == [24, 24])
    }

    @Test func forbiddenSwitchesToReadOnly() async {
        let detail = await loadedDetail()
        editor.created.withLock { $0 = .failure(.forbidden) }
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()

        #expect(detail.notice == .readOnly)
        #expect(calls.forbidden == 1)
    }

    /// Während das Anhängen läuft, geht kein zweites los, auch nicht per Return-Taste.
    @Test func addingOnlyOnce() async {
        let detail = await loadedDetail()
        editor.gate.close()
        detail.newSubtaskTitle = "Buy snacks"
        let first = Task { await detail.addSubtask() }
        await editor.gate.untilWaiting()

        #expect(detail.isAddingSubtask)
        #expect(!detail.canAddSubtask)
        await detail.addSubtask()
        editor.gate.open()
        await first.value

        #expect(editor.creates.withLock { $0.count } == 1)
        #expect(!detail.isAddingSubtask)
    }

    /// Ein Laden, das vor dem Anhängen begann, nimmt die neue Unteraufgabe nicht wieder weg.
    @Test func aPendingLoadKeepsTheNewSubtask() async {
        let detail = await loadedDetail()
        reading.gate.close()
        let loading = Task { await detail.load() }
        await reading.gate.untilWaiting()
        detail.newSubtaskTitle = "Buy snacks"

        await detail.addSubtask()
        reading.gate.open()
        await loading.value

        #expect(subtasks(detail) == [25, 27])
    }

    /// Ein Laden, das die neue Unteraufgabe schon kennt, bevor POST antwortet: Sie steht nur
    /// einmal da (Review F4).
    @Test func aLoadThatKnowsTheSubtaskKeepsOneRow() async {
        let detail = await loadedDetail()
        editor.gate.close()
        detail.newSubtaskTitle = "Buy snacks"
        let adding = Task { await detail.addSubtask() }
        await editor.gate.untilWaiting()
        var known = packing
        known.subtasks.append(task(27))
        reading.result.withLock { $0 = .success(known) }
        await detail.load()

        editor.gate.open()
        await adding.value

        #expect(subtasks(detail) == [25, 27])
    }

    // MARK: Löschen

    /// Q5: Löschen nach der Rückfrage der View. Ohne Hinweis „gibt es nicht mehr“, Liste und
    /// Erinnerungen gleichen ab.
    @Test func deletingRemovesTheSubtask() async {
        let detail = await loadedDetail()

        await detail.deleteSubtask(25)

        #expect(editor.deletes.withLock { $0 } == [25])
        #expect(subtasks(detail) == [])
        #expect(detail.notice == nil)
        #expect(calls.statusChanged == 1)
    }

    /// Wie beim Löschen der Aufgabe (Q3): 404 gilt als gelöscht.
    @Test func deletingWhatIsGoneCountsAsDeleted() async {
        let detail = await loadedDetail()
        editor.deleted.withLock { $0 = .failure(.notFound) }

        await detail.deleteSubtask(25)

        #expect(subtasks(detail) == [])
        #expect(detail.notice == nil)
        #expect(detail.state != .gone)
    }

    @Test func aFailedDeleteKeepsTheSubtask() async {
        let detail = await loadedDetail()
        editor.deleted.withLock { $0 = .failure(.unreachable) }

        await detail.deleteSubtask(25)

        #expect(subtasks(detail) == [25])
        #expect(detail.notice == .unreachable)
        #expect(calls.statusChanged == 0)
    }

    @Test func aLockedSubtaskReloads() async {
        let detail = await loadedDetail()
        editor.deleted.withLock { $0 = .failure(.locked) }

        await detail.deleteSubtask(25)

        #expect(detail.notice == .locked)
        #expect(subtasks(detail) == [25])
        #expect(reading.requested.withLock { $0 } == [24, 24])
    }

    /// Ein Laden, das vor dem Löschen begann, bringt die Unteraufgabe nicht zurück.
    @Test func aPendingLoadDoesNotBringItBack() async {
        let detail = await loadedDetail()
        reading.gate.close()
        let loading = Task { await detail.load() }
        await reading.gate.untilWaiting()

        await detail.deleteSubtask(25)
        reading.gate.open()
        await loading.value

        #expect(subtasks(detail) == [])
    }

    /// Solange ihr Statuswechsel läuft, lässt sie sich nicht löschen. Sonst meldete dessen 404
    /// danach „gibt es nicht mehr“ (Review F4).
    @Test func noDeleteWhileItsStatusIsWriting() async {
        let detail = await loadedDetail()
        writer.hold()
        let toggling = Task { await detail.toggleSubtask(25) }
        await writer.untilWaiting()

        await detail.deleteSubtask(25)
        writer.release()
        await toggling.value

        #expect(editor.deletes.withLock { $0.isEmpty })
    }

    /// Während eine Unteraufgabe gelöscht wird, geht für sie kein zweites Löschen los.
    @Test func deletingASubtaskOnlyOnce() async {
        let detail = await loadedDetail()
        editor.gate.close()
        let first = Task { await detail.deleteSubtask(25) }
        await editor.gate.untilWaiting()

        #expect(detail.deletingSubtasks == [25])
        await detail.deleteSubtask(25)
        editor.gate.open()
        await first.value

        #expect(editor.deletes.withLock { $0 } == [25])
        #expect(detail.deletingSubtasks.isEmpty)
    }
}

/// Seam 4: Unteraufgaben im Detail und die Liste dahinter (F4).
@MainActor @Suite struct SubtaskListTests {
    let reading = FakeTasks(.success([task(24), task(1)]), detail: packing)

    /// Ein Laden der Liste, das vor dem Löschen einer Unteraufgabe begann, meldet danach kein
    /// „gibt es nicht mehr“: Das Neuladen nach dem Löschen löst es ab (Review F4).
    @Test func deletingASubtaskDuringAListLoadShowsNoNotice() async {
        let list = TaskListModel(
            tasks: reading, writer: FakeWriter(), editor: FakeEditor(), permissions: FakePermissions(),
            today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {}
        )
        await list.load()
        list.path = [24]
        let detail = list.detail(for: 24)
        await detail.load()
        reading.gate.close()
        let loading = Task { await list.load() }
        await reading.gate.untilWaiting()

        await detail.deleteSubtask(25)
        reading.gate.open()
        await loading.value

        #expect(list.notice == nil)
    }
}
