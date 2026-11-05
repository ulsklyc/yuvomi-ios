import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 4: das Formular fürs Ändern (F3). Nur Geändertes, Folgen nach Q13.
@MainActor @Suite struct TaskFormEditingTests {
    let editor = FakeEditor()
    let stored = TaskDetail(
        id: 24, title: "Pack for the weekend trip", status: .open, priority: .medium,
        due: CalendarDay(year: 2026, month: 11, day: 7), dueTime: "09:00", assignees: ["Alex"], assigneeIDs: [1],
        description: "  - [ ] Pack sleeping bags", category: "household", createdBy: 1
    )

    final class Log {
        var outcomes: [TaskFormModel.Outcome] = []
    }

    func form(_ log: Log = Log()) -> TaskFormModel {
        TaskFormModel(editing: stored, editor: editor, onUnauthorized: {}, onFinished: { log.outcomes.append($0) })
    }

    /// Q9: Das Formular zeigt den gespeicherten Stand, ohne Änderung ist „Sichern“ aus.
    @Test func startsFromTheStoredTask() {
        let form = form()

        #expect(form.isEditing)
        #expect(form.draft == TaskDraft(stored))
        #expect(!form.hasChanges)
        #expect(!form.canSave)
    }

    /// Q9: PUT nur mit dem Titel, ohne Schlüssel. Das Detail bekommt die Antwort (Q11).
    @Test func savingSendsOnlyTheChange() async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Pack for the trip"

        await form.save()

        let sent = editor.updates.withLock { $0 }
        #expect(sent.map(\.id) == [24])
        #expect(sent.first?.changes == TaskChanges(title: "Pack for the trip"))
        #expect(editor.creates.withLock { $0.isEmpty })
        var saved = packing
        saved.title = "Pack for the trip"
        #expect(log.outcomes == [.saved(saved)])
    }

    /// Unbekanntes vom Server bleibt im Picker wählbar, sonst stünde er leer da (Review F3).
    @Test func storedValuesStayChoosable() async {
        var odd = stored
        odd.priority = .unknown
        odd.category = "garden"
        let form = TaskFormModel(editing: odd, editor: editor, onUnauthorized: {}, onFinished: { _ in })
        await form.loadOptions()

        #expect(form.priorityChoices == TaskPriority.settable + [.unknown])
        #expect(form.categoryChoices.map(\.key) == ["household", "misc", "garden"])
        #expect(self.form().priorityChoices == TaskPriority.settable)
    }

    @Test func clearingTheDateClearsTheTime() async {
        let form = form()
        form.hasDue = false

        await form.save()

        #expect(editor.updates.withLock { $0 }.first?.changes == TaskChanges(due: .clear, dueTime: .clear))
    }

    /// Q13: Gesperrt, weg oder Nur-lesen schließt das Sheet, die Folgen trägt das Detail.
    @Test(arguments: [APIError.locked, .notFound, .forbidden])
    func closingFailuresFinish(_ error: APIError) async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Mine now"
        editor.updated.withLock { $0 = .failure(error) }

        await form.save()

        #expect(log.outcomes == [.failed(error)])
    }

    /// Optionen, die das Detail schon hat, lädt das Formular nicht neu.
    @Test func givenOptionsAreNotLoadedAgain() async {
        editor.options.withLock { $0 = .success(TaskOptions(people: [], categories: [])) }
        let form = TaskFormModel(editing: stored, options: FakeEditor.household, editor: editor, onUnauthorized: {}, onFinished: { _ in })

        await form.loadOptions()

        #expect(form.options == FakeEditor.household)
    }

    /// Q4: Ohne Antwort bleibt das Sheet offen und behält die Eingaben.
    @Test func aFailureKeepsTheInputs() async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Pack for the trip"
        editor.updated.withLock { $0 = .failure(.unreachable) }

        await form.save()

        #expect(log.outcomes.isEmpty)
        #expect(form.notice == .unreachable)
        #expect(form.draft.title == "Pack for the trip")
        #expect(form.canSave)
    }
}

/// Seam 4: Bearbeiten und Löschen im Detail (F3), Rechte und Sperre vorab (Q7).
@MainActor @Suite struct TaskDetailEditingTests {
    let reading = FakeDetail(.success(packing))
    let editor = FakeEditor()
    let writer = FakeWriter()

    final class Calls {
        var statusChanged = 0
        var forbidden = 0
        var gone = 0
        var deleted = 0
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
            onGone: { calls.gone += 1 },
            onDeleted: { calls.deleted += 1 }
        )
        await detail.load()
        return detail
    }

    func locked(by creator: Int?) -> TaskDetail {
        var task = packing
        task.isLocked = true
        task.createdBy = creator
        return task
    }

    @Test func editingIsOffWhenReadOnly() async {
        let detail = await loadedDetail(mayWrite: false)

        #expect(!detail.canEdit)
        detail.startEditing()
        #expect(detail.form == nil)
    }

    /// Q7: Gesperrt und von jemand anderem angelegt: kein Bearbeiten, kein Löschen.
    @Test func lockedByOthersHidesEditing() async {
        reading.result.withLock { $0 = .success(locked(by: 3)) }
        let detail = await loadedDetail()

        #expect(!detail.canEdit)
        await detail.delete()
        #expect(editor.deletes.withLock { $0.isEmpty })
    }

    /// Q7: Die eigene gesperrte Aufgabe lässt sich ändern.
    @Test func ownLockedTaskStaysEditable() async {
        reading.result.withLock { $0 = .success(locked(by: 1)) }
        let detail = await loadedDetail()

        #expect(detail.canEdit)
    }

    /// F1: Fehlt die Angabe, wer sie angelegt hat, gilt eine gesperrte Aufgabe als fremd.
    @Test func lockedWithoutCreatorCountsAsForeign() async {
        reading.result.withLock { $0 = .success(locked(by: nil)) }
        let detail = await loadedDetail()

        #expect(!detail.canEdit)
    }

    /// Q11: Sheet zu, das Detail zeigt die Antwort, Liste und Erinnerungen gleichen ab.
    @Test func savingShowsTheAnswer() async {
        let detail = await loadedDetail()
        detail.startEditing()
        #expect(detail.form?.draft == TaskDraft(packing))
        detail.form?.draft.title = "Pack for the trip"

        await detail.form?.save()

        #expect(detail.form == nil)
        guard case .loaded(let task) = detail.state else {
            Issue.record("nicht geladen")
            return
        }
        #expect(task.title == "Pack for the trip")
        #expect(calls.statusChanged == 1)
    }

    /// Ein Abhaken, das beim Sichern noch läuft, gilt auch über der Antwort (Review F3).
    @Test func aRunningCheckOffSurvivesTheAnswer() async {
        let detail = await loadedDetail()
        writer.hold()
        let checking = Task { await detail.toggleStatus() }
        await writer.untilWaiting()
        detail.startEditing()
        detail.form?.draft.title = "Pack for the trip"

        await detail.form?.save()

        guard case .loaded(let task) = detail.state else {
            Issue.record("nicht geladen")
            return
        }
        #expect(task.title == "Pack for the trip")
        #expect(task.status == .done)
        writer.release()
        await checking.value
    }

    /// Issue #35: Solange ein Ankreuzen läuft, öffnet „Bearbeiten“ nichts. Sonst überschriebe
    /// seine Antwort eine gerade gesicherte Beschreibung.
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

    /// Ein Laden, das beim Löschen noch lief, meldet danach kein „gibt es nicht mehr“
    /// (Codex-Review F3).
    @Test func deletingCancelsAPendingLoad() async {
        let detail = await loadedDetail()
        reading.result.withLock { $0 = .failure(.notFound) }
        reading.gate.close()
        let loading = Task { await detail.load() }
        await reading.gate.untilWaiting()

        await detail.delete()
        reading.gate.open()
        await loading.value

        #expect(calls.deleted == 1)
        #expect(calls.gone == 0)
    }

    /// Q13: gesperrt beim Sichern: Hinweis, Sheet zu, das Detail lädt neu.
    @Test func lockedOnSaveReloads() async {
        let detail = await loadedDetail()
        detail.startEditing()
        detail.form?.draft.title = "Mine now"
        editor.updated.withLock { $0 = .failure(.locked) }

        await detail.form?.save()

        #expect(detail.form == nil)
        #expect(detail.notice == .locked)
        #expect(reading.requested.withLock { $0 } == [24, 24])
    }

    @Test func goneOnSaveClosesTheDetail() async {
        let detail = await loadedDetail()
        detail.startEditing()
        detail.form?.draft.title = "Still here?"
        editor.updated.withLock { $0 = .failure(.notFound) }

        await detail.form?.save()

        #expect(detail.form == nil)
        #expect(detail.state == .gone)
        #expect(calls.gone == 1)
    }

    @Test func forbiddenOnSaveSwitchesToReadOnly() async {
        let detail = await loadedDetail()
        detail.startEditing()
        detail.form?.draft.title = "Call"
        editor.updated.withLock { $0 = .failure(.forbidden) }

        await detail.form?.save()

        #expect(detail.form == nil)
        #expect(detail.notice == .readOnly)
        #expect(calls.forbidden == 1)
    }

    /// Q3: Löschen schließt das Detail über den Besitzer.
    @Test func deletingClosesTheDetail() async {
        let detail = await loadedDetail()

        await detail.delete()

        #expect(editor.deletes.withLock { $0 } == [24])
        #expect(calls.deleted == 1)
        #expect(calls.gone == 0)
    }

    /// Q3: 404 beim Löschen gilt als Erfolg.
    @Test func deletingWhatIsGoneCountsAsDeleted() async {
        editor.deleted.withLock { $0 = .failure(.notFound) }
        let detail = await loadedDetail()

        await detail.delete()

        #expect(calls.deleted == 1)
        #expect(detail.notice == nil)
    }

    @Test func aFailedDeleteKeepsTheDetail() async {
        editor.deleted.withLock { $0 = .failure(.unreachable) }
        let detail = await loadedDetail()

        await detail.delete()

        #expect(calls.deleted == 0)
        #expect(detail.notice == .unreachable)
        #expect(detail.state == .loaded(packing))
    }

    /// Q13: Inzwischen gesperrt: Hinweis, das Detail lädt neu.
    @Test func lockedOnDeleteReloads() async {
        editor.deleted.withLock { $0 = .failure(.locked) }
        let detail = await loadedDetail()

        await detail.delete()

        #expect(calls.deleted == 0)
        #expect(detail.notice == .locked)
        #expect(reading.requested.withLock { $0 } == [24, 24])
    }

    /// Während das Löschen läuft, geht kein zweites los.
    @Test func deletingOnlyOnce() async {
        editor.gate.close()
        let detail = await loadedDetail()
        let first = Task { await detail.delete() }
        await editor.gate.untilWaiting()

        #expect(detail.isDeleting)
        await detail.delete()
        editor.gate.open()
        await first.value

        #expect(editor.deletes.withLock { $0 } == [24])
        #expect(!detail.isDeleting)
    }

    /// Q8: Das Detail zeigt die Kategorie mit dem Namen aus `meta/options`.
    @Test func theCategoryComesFromTheOptions() async {
        editor.options.withLock {
            $0 = .success(TaskOptions(people: [], categories: [TaskCategory(key: "garden", name: "Garten", labelKey: nil)]))
        }
        let detail = await loadedDetail()

        #expect(detail.category(for: "garden").localizedTitle == "Garten")
        #expect(detail.category(for: "unknown").localizedTitle == "unknown")
    }
}

/// Seam 4: Folgen von Ändern und Löschen in der Liste (F3).
@MainActor @Suite struct TaskListEditingTests {
    let editor = FakeEditor()
    let reading = FakeTasks(.success([task(24), task(1)]), detail: packing)

    func list(permissions: FakePermissions = FakePermissions(), onStatusChanged: @escaping @MainActor () -> Void = {}) async -> TaskListModel {
        let list = TaskListModel(
            tasks: reading, writer: FakeWriter(), editor: editor, permissions: permissions,
            today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {}, onStatusChanged: onStatusChanged
        )
        await list.load()
        return list
    }

    /// Q11: Detail zu, Zeile weg, kein Hinweis „gibt es nicht mehr“, Erinnerungen gleichen ab.
    @Test func deletingRemovesTheRow() async {
        var changed = 0
        let list = await list(onStatusChanged: { changed += 1 })
        list.path = [24]
        let detail = list.detail(for: 24)
        await detail.load()

        await detail.delete()

        #expect(list.path.isEmpty)
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1)])]))
        #expect(list.notice == nil)
        #expect(changed == 1)
    }

    /// Auch wenn währenddessen ein Laden der Liste läuft: Wer selbst löscht, bekommt keinen
    /// Hinweis „gibt es nicht mehr“ (Review F3).
    @Test func deletingDuringALoadShowsNoNotice() async {
        let list = await list()
        list.path = [24]
        let detail = list.detail(for: 24)
        await detail.load()
        reading.gate.close()
        let loading = Task { await list.load() }
        await reading.gate.untilWaiting()

        await detail.delete()
        reading.gate.open()
        await loading.value

        #expect(list.notice == nil)
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1)])]))
    }

    /// Q7: Die Liste kennt die eigene Id aus `/auth/me` und gibt sie dem Detail.
    @Test func theDetailKnowsWhoIsAsking() async {
        var mine = packing
        mine.isLocked = true
        mine.createdBy = 7
        reading.detail = mine
        let list = await list(permissions: FakePermissions(id: 7))
        list.path = [24]
        let detail = list.detail(for: 24)
        await detail.load()

        #expect(detail.canEdit)
    }
}
