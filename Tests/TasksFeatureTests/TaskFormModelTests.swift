import Foundation
import Testing
import YuvomiCore
@testable import TasksFeature

/// Seam 4: das Formular fürs Anlegen (F2). Sichern, Schlüssel, Fehler nach Q13 und Q14.
@MainActor @Suite struct TaskFormModelTests {
    let editor = FakeEditor()
    let today = CalendarDay(year: 2026, month: 11, day: 5)
    /// 2026-11-05 14:20 in Berlin (13:20 UTC).
    let now = Date(timeIntervalSince1970: 1_793_836_800 + 13 * 3600 + 20 * 60)
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    final class Log {
        var outcomes: [TaskFormModel.Outcome] = []
        var unauthorized = 0
        var keys = 0
    }

    func form(_ log: Log = Log()) -> TaskFormModel {
        TaskFormModel(
            editor: editor, now: { now }, timeZone: berlin,
            makeKey: { log.keys += 1; return "key-\(log.keys)" },
            onUnauthorized: { log.unauthorized += 1 },
            onFinished: { log.outcomes.append($0) }
        )
    }

    @Test func saveNeedsATitle() {
        let form = form()
        #expect(!form.canSave)

        form.draft.title = "  "
        #expect(!form.canSave)

        form.draft.title = "Water the plants"
        #expect(form.canSave)
        #expect(form.hasChanges)
    }

    @Test func titleTooLongBlocksSaving() {
        let form = form()
        form.draft.title = String(repeating: "a", count: 201)
        #expect(!form.canSave)
        #expect(form.draft.problems == [.titleTooLong])
    }

    @Test func savingCreatesAndFinishes() async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Water the plants"

        await form.save()

        let sent = editor.creates.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent.first?.draft.title == "Water the plants")
        #expect(sent.first?.parent == nil)
        #expect(sent.first?.key == "key-1")
        #expect(log.outcomes == [.created])
        #expect(form.notice == nil)
    }

    /// Q4, Q14: Ohne Antwort bleibt das Formular mit den Eingaben offen. Der zweite Versuch
    /// schickt denselben Schlüssel, so legt der Server nicht doppelt an.
    @Test func aFailureKeepsInputsAndKey() async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Water the plants"
        editor.created.withLock { $0 = .failure(.unreachable) }

        await form.save()

        #expect(form.notice == .unreachable)
        #expect(form.draft.title == "Water the plants")
        #expect(log.outcomes.isEmpty)

        editor.created.withLock { $0 = .success(task(27)) }
        await form.save()

        #expect(editor.creates.withLock { $0.map(\.key) } == ["key-1", "key-1"])
        #expect(log.outcomes == [.created])
    }

    /// Ändert die Person nach einem Fehler etwas, ist es eine andere Anfrage: Mit dem alten
    /// Schlüssel antwortete der Server 24 Stunden lang mit 409.
    @Test func aChangedDraftAfterAFailureGetsANewKey() async {
        let form = form()
        form.draft.title = "Water the plants"
        editor.created.withLock { $0 = .failure(.unreachable) }
        await form.save()

        form.draft.title = "Water all the plants"
        await form.save()

        #expect(editor.creates.withLock { $0.map(\.key) } == ["key-1", "key-2"])
    }

    /// Nur Leerzeichen am Rand ändern den Body nicht: derselbe Schlüssel.
    @Test func whitespaceOnlyEditsKeepTheKey() async {
        let form = form()
        form.draft.title = "Water the plants"
        editor.created.withLock { $0 = .failure(.unreachable) }
        await form.save()

        form.draft.title = "Water the plants "
        await form.save()

        #expect(editor.creates.withLock { $0.map(\.key) } == ["key-1", "key-1"])
    }

    @Test(arguments: [
        (APIError.conflict, TaskNotice.stillRunning),
        (.unexpectedResponse, .unexpectedResponse),
        (.unreachable, .unreachable),
    ])
    func failuresStayInTheForm(error: APIError, notice: TaskNotice) async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Call"
        editor.created.withLock { $0 = .failure(error) }

        await form.save()

        #expect(form.notice == notice)
        #expect(log.outcomes.isEmpty)
        #expect(form.canSave)
    }

    /// Q13: 403 ohne Sperre heißt Nur-lesen. Das Formular geht zu, die Liste schaltet um.
    @Test func forbiddenFinishesReadOnly() async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Call"
        editor.created.withLock { $0 = .failure(.forbidden) }

        await form.save()

        #expect(log.outcomes == [.readOnly])
    }

    @Test func unauthorizedSignsOut() async {
        let log = Log()
        let form = form(log)
        form.draft.title = "Call"
        editor.created.withLock { $0 = .failure(.unauthorized) }

        await form.save()

        #expect(log.unauthorized == 1)
        #expect(log.outcomes.isEmpty)
    }

    /// Während die Anfrage läuft, ist „Sichern“ aus. Ein zweiter Tipp legt nicht doppelt an.
    @Test func savingTwiceSendsOnce() async {
        let form = form()
        form.draft.title = "Call"
        editor.gate.close()

        let first = Task { await form.save() }
        await editor.gate.untilWaiting()
        #expect(form.isSaving)
        #expect(!form.canSave)
        await form.save()
        editor.gate.open()
        await first.value

        #expect(editor.creates.withLock { $0.count } == 1)
        #expect(!form.isSaving)
    }

    @Test func optionsOfferPeopleAndCategories() async {
        let form = form()
        await form.loadOptions()

        #expect(form.options == FakeEditor.household)
        #expect(form.assignablePeople == FakeEditor.household.people)
    }

    /// Q10: Bei einer Person allein gibt es nichts zuzuweisen.
    @Test func aSinglePersonHouseholdHidesAssignees() async {
        editor.options.withLock { $0 = .success(TaskOptions(people: [TaskOptions.Person(id: 1, name: "Alex")], categories: [])) }
        let form = form()
        await form.loadOptions()

        #expect(form.assignablePeople == nil)
    }

    /// Ohne Optionen bleibt das Formular nutzbar: Titel und der Rest gehen auch so.
    @Test func optionsFailingLeavesTheFormUsable() async {
        editor.options.withLock { $0 = .failure(.unreachable) }
        let form = form()
        await form.loadOptions()

        #expect(form.options == nil)
        #expect(form.assignablePeople == nil)
    }

    @Test func optionsForbiddenFinishesReadOnly() async {
        let log = Log()
        editor.options.withLock { $0 = .failure(.forbidden) }
        let form = form(log)
        await form.loadOptions()

        #expect(log.outcomes == [.readOnly])
    }

    /// Q17: Das Datum beginnt heute, die Uhrzeit zur nächsten vollen Stunde.
    @Test func dateAndTimeSwitches() {
        let form = form()

        form.hasDue = true
        #expect(form.draft.due == today)
        #expect(!form.hasTime)

        form.hasTime = true
        #expect(form.draft.dueTime == "15:00")

        form.hasDue = false
        #expect(form.draft.due == nil)
        #expect(form.draft.dueTime == nil)
        #expect(!form.hasTime)
    }

    /// Die Wähler rechnen in derselben Zeitzone wie der Vorschlag.
    @Test func pickersRoundTripInTheModelsTimeZone() {
        let form = form()
        form.hasDue = true
        form.hasTime = true

        let day = form.dueDate, time = form.dueTimeDate
        form.dueDate = day
        form.dueTimeDate = time

        #expect(form.draft.due == today)
        #expect(form.draft.dueTime == "15:00")
    }

    /// Am Tag der Zeitumstellung gibt es 02:00 nicht: Der Vorschlag nach 01:10 ist 03:00.
    @Test func suggestionSkipsTheMissingHour() {
        // 2026-03-29 01:10 in Berlin, die Uhr springt um 02:00 auf 03:00.
        let springForward = Date(timeIntervalSince1970: 1_774_743_000)
        let form = TaskFormModel(editor: editor, now: { springForward }, timeZone: berlin, onUnauthorized: {}, onFinished: { _ in })

        form.hasDue = true
        form.hasTime = true

        #expect(form.draft.dueTime == "03:00")
    }

    /// Der Zeitwähler hängt am gewählten Tag, nicht an heute: 02:30 am Tag nach der
    /// Umstellung gibt es, auch wenn es heute fehlt.
    @Test func timePickerUsesTheDueDay() {
        let springForward = Date(timeIntervalSince1970: 1_774_743_000)
        let form = TaskFormModel(editor: editor, now: { springForward }, timeZone: berlin, onUnauthorized: {}, onFinished: { _ in })
        form.draft.due = CalendarDay(year: 2026, month: 3, day: 30)
        form.draft.dueTime = "02:30"

        let shown = CalendarDay.gregorian(berlin).dateComponents([.year, .month, .day, .hour, .minute], from: form.dueTimeDate)

        #expect(shown.day == 30)
        #expect(shown.hour == 2)
        #expect(shown.minute == 30)
    }

    /// Nach 23 Uhr gibt es keine nächste Stunde mehr am selben Tag.
    @Test func lateTimeStaysOnTheDay() {
        // 23:10 in Berlin.
        let late = now.addingTimeInterval(8 * 3600 + 50 * 60)
        let form = TaskFormModel(editor: editor, now: { late }, timeZone: berlin, onUnauthorized: {}, onFinished: { _ in })

        form.hasDue = true
        form.hasTime = true

        #expect(form.draft.dueTime == "23:59")
    }

    /// Q10: Die zuerst gewählte Person ist hauptverantwortlich.
    @Test func assigneesKeepTheOrderOfChoosing() {
        let form = form()

        form.toggleAssignee(3)
        form.toggleAssignee(1)
        #expect(form.draft.assigneeIDs == [3, 1])

        form.toggleAssignee(3)
        #expect(form.draft.assigneeIDs == [1])
    }

    /// Q18: Ab 4500 Zeichen ein Zähler.
    @Test func descriptionCounterFrom4500() {
        let form = form()
        form.draft.description = String(repeating: "a", count: 4499)
        #expect(form.descriptionCount == nil)

        form.draft.description = String(repeating: "a", count: 4500)
        #expect(form.descriptionCount == 4500)
    }
}

/// Seam 4: „+“ in der Liste (F2).
@MainActor @Suite struct TaskListCreatingTests {
    let editor = FakeEditor()
    let reading = FakeTasks(.success([task(1)]))

    func list(permissions: FakePermissions = FakePermissions(), onStatusChanged: @escaping @MainActor () -> Void = {}) async -> TaskListModel {
        let list = TaskListModel(
            tasks: reading, writer: FakeWriter(), editor: editor, permissions: permissions,
            today: { CalendarDay(year: 2026, month: 11, day: 3) }, onUnauthorized: {}, onStatusChanged: onStatusChanged
        )
        await list.load()
        return list
    }

    @Test func plusOpensAnEmptyForm() async {
        let list = await list()

        list.startCreating()

        #expect(list.form?.draft == TaskDraft())
    }

    /// Q7: Bei Nur-lesen gibt es kein „+“.
    @Test func readOnlyHasNoForm() async {
        let list = await list(permissions: FakePermissions(result: .success(false)))

        list.startCreating()

        #expect(list.form == nil)
    }

    /// Q11: Sheet zu, Liste lädt neu, die Erinnerungen gleichen ab.
    @Test func savingClosesAndReloads() async {
        var changed = 0
        let list = await list(onStatusChanged: { changed += 1 })
        list.startCreating()
        list.form?.draft.title = "Water the plants"
        reading.result = .success([task(1), task(27)])

        await list.form?.save()

        #expect(list.form == nil)
        #expect(list.state == .loaded([TaskSection(kind: .noDate, tasks: [task(1), task(27)])]))
        #expect(changed == 1)
    }

    @Test func forbiddenSwitchesToReadOnly() async {
        let list = await list()
        list.startCreating()
        list.form?.draft.title = "Call"
        editor.created.withLock { $0 = .failure(.forbidden) }

        await list.form?.save()

        #expect(list.form == nil)
        #expect(!list.canWrite)
        #expect(list.notice == .readOnly)
    }

    @Test func cancelClosesWithoutSending() async {
        let list = await list()
        list.startCreating()
        list.form?.draft.title = "Call"

        list.form = nil

        #expect(editor.creates.withLock { $0.isEmpty })
    }
}
