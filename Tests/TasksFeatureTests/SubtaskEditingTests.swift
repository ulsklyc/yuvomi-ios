import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 4: Unteraufgaben im Detail anhängen und löschen (F4, Q5).
@MainActor @Suite struct SubtaskEditingTests {
    let reading = FakeDetail(.success(packing))
    let editor = FakeEditor()

    final class Calls {
        var statusChanged = 0
        var forbidden = 0
        var gone = 0
    }
    let calls = Calls()

    func loadedDetail(mayWrite: Bool = true, memberID: Int? = 1) async -> TaskDetailModel {
        let calls = calls
        let detail = TaskDetailModel(
            taskID: 24, tasks: reading, writer: FakeWriter(), editor: editor,
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

/// Issue #35: Solange ein Ankreuzen läuft, öffnet „Bearbeiten“ nichts. Sonst überschriebe
/// seine Antwort eine gerade gesicherte Beschreibung.
@MainActor @Suite struct EditingWhileTickingTests {
    let writer = FakeWriter()

    func loadedDetail() async -> TaskDetailModel {
        let detail = TaskDetailModel(
            taskID: 24, tasks: FakeDetail(.success(packing)), writer: writer, editor: FakeEditor(),
            memberID: { 1 }, onUnauthorized: {}
        )
        await detail.load()
        return detail
    }

    @Test func editingWaitsForARunningTick() async {
        let detail = await loadedDetail()
        writer.tick.withLock { $0 = .success("- [x] Pack sleeping bags") }
        writer.hold()
        let ticking = Task { await detail.tick(line: 0) }
        await writer.untilWaiting()

        detail.startEditing()
        #expect(detail.form == nil)

        writer.release()
        await ticking.value
        detail.startEditing()
        #expect(detail.form?.draft.description == "- [x] Pack sleeping bags")
    }

    /// Umgekehrt: Bei offenem Formular kreuzt das Detail nichts an.
    @Test func noTickWhileEditing() async {
        let detail = await loadedDetail()
        detail.startEditing()

        await detail.tick(line: 0)

        #expect(writer.calls.withLock { $0.isEmpty })
    }
}
