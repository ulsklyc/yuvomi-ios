import Testing
import YuvomiCore

/// Seam 1: Der Entwurf eines Formulars wird zu den Feldern, die der Server bekommt (Q9, Q17).
/// Grenzen wie `server/middleware/validate.js` in `v2.85.0`: nach `trim()` gezählt, in UTF-16
/// wie JS `.length`.
@Suite struct TaskDraftTests {
    let stored = TaskDetail(
        id: 7, title: "Water the plants", status: .open, priority: .low,
        due: CalendarDay(year: 2026, month: 11, day: 6), dueTime: "18:30",
        assignees: ["Alex", "Emma"], assigneeIDs: [1, 3], description: "- [ ] Balcony",
        category: "household", createdBy: 1
    )

    @Test func startsFromTheStoredTask() {
        let draft = TaskDraft(stored)

        #expect(draft.title == "Water the plants")
        #expect(draft.due == CalendarDay(year: 2026, month: 11, day: 6))
        #expect(draft.dueTime == "18:30")
        #expect(draft.assigneeIDs == [1, 3])
        #expect(draft.priority == .low)
        #expect(draft.category == "household")
        #expect(draft.description == "- [ ] Balcony")
    }

    @Test func unchangedDraftChangesNothing() {
        let draft = TaskDraft(stored)

        #expect(draft.changes(from: TaskDraft(stored)) == TaskChanges())
        #expect(draft.changes(from: TaskDraft(stored)).isEmpty)
    }

    @Test func sendsOnlyTheChangedField() {
        let base = TaskDraft(stored)
        var draft = base

        draft.title = "Water all the plants"
        #expect(draft.changes(from: base) == TaskChanges(title: "Water all the plants"))

        draft = base
        draft.priority = .urgent
        #expect(draft.changes(from: base) == TaskChanges(priority: .urgent))

        draft = base
        draft.category = "misc"
        #expect(draft.changes(from: base) == TaskChanges(category: "misc"))

        draft = base
        draft.due = CalendarDay(year: 2026, month: 11, day: 9)
        #expect(draft.changes(from: base) == TaskChanges(due: .set(CalendarDay(year: 2026, month: 11, day: 9))))

        draft = base
        draft.dueTime = "07:00"
        #expect(draft.changes(from: base) == TaskChanges(dueTime: .set("07:00")))

        draft = base
        draft.description = "- [x] Balcony"
        #expect(draft.changes(from: base) == TaskChanges(description: .set("- [x] Balcony")))
    }

    /// Die zuerst gewählte Person ist hauptverantwortlich (Q10): Die Reihenfolge zählt.
    @Test func assigneesKeepTheirOrder() {
        let base = TaskDraft(stored)
        var draft = base
        draft.assigneeIDs = [3, 1]

        #expect(draft.changes(from: base) == TaskChanges(assigneeIDs: .set([3, 1])))
    }

    @Test func emptyFieldsClear() {
        let base = TaskDraft(stored)
        var draft = base
        draft.assigneeIDs = []
        draft.description = "  \n"

        #expect(draft.changes(from: base) == TaskChanges(assigneeIDs: .clear, description: .clear))
    }

    /// Ein Einzug am Rand entscheidet, ob eine Zeile ein Punkt der Checkliste ist: Er zählt
    /// als Änderung.
    @Test func whitespaceAroundTheDescriptionIsAChange() {
        var stored = stored
        stored.description = "    - [ ] Sleeping bag"
        let base = TaskDraft(stored)
        var draft = base
        draft.description = "- [ ] Sleeping bag"

        #expect(draft.changes(from: base) == TaskChanges(description: .set("- [ ] Sleeping bag")))
    }

    /// Von leer zu nur Leerzeichen bleibt leer.
    @Test func blankDescriptionStaysEmpty() {
        var draft = TaskDraft()
        draft.title = "Call"
        draft.description = " \n"

        #expect(draft.changes(from: TaskDraft()) == TaskChanges(title: "Call"))
    }

    /// Q17: Uhrzeit nur mit Datum. Ohne Datum geht die Uhrzeit mit weg.
    @Test func noDateClearsTheTimeToo() {
        let base = TaskDraft(stored)
        var draft = base
        draft.due = nil

        #expect(draft.changes(from: base) == TaskChanges(due: .clear, dueTime: .clear))
    }

    @Test func timeOffClearsOnlyTheTime() {
        let base = TaskDraft(stored)
        var draft = base
        draft.dueTime = nil

        #expect(draft.changes(from: base) == TaskChanges(dueTime: .clear))
    }

    /// Eine Uhrzeit ohne Datum gibt es nicht: Sie ändert nichts, solange das Datum fehlt.
    @Test func timeWithoutDateIsIgnored() {
        var draft = TaskDraft()
        draft.title = "Call"
        draft.dueTime = "09:00"

        #expect(draft.changes(from: TaskDraft()) == TaskChanges(title: "Call"))
    }

    /// Anlegen schickt nur, was vom leeren Formular abweicht. Was fehlt, setzt der Server
    /// (`misc`, `none`, niemand zuständig).
    @Test func newTaskSendsWhatDiffersFromTheEmptyForm() {
        var draft = TaskDraft()
        draft.title = "  Water the plants "
        draft.due = CalendarDay(year: 2026, month: 11, day: 6)
        draft.dueTime = "18:30"
        draft.assigneeIDs = [1]

        #expect(draft.changes(from: TaskDraft()) == TaskChanges(
            title: "Water the plants", due: .set(CalendarDay(year: 2026, month: 11, day: 6)),
            dueTime: .set("18:30"), assigneeIDs: .set([1])
        ))
    }

    /// Nur Leerzeichen am Rand: Der Server speichert den Titel ohnehin getrimmt.
    @Test func whitespaceAroundTheTitleIsNoChange() {
        let base = TaskDraft(stored)
        var draft = base
        draft.title = " Water the plants  "

        #expect(draft.changes(from: base).isEmpty)
    }

    @Test func titleIsRequired() {
        var draft = TaskDraft()
        #expect(draft.problems == [.titleMissing])

        draft.title = " \n "
        #expect(draft.problems == [.titleMissing])

        draft.title = "Call"
        #expect(draft.problems.isEmpty)
    }

    /// 200 Zeichen in UTF-16: Ein Emoji wie 🌱 zählt doppelt, wie in JS.
    @Test func titleLimitCountsLikeJavaScript() {
        var draft = TaskDraft()
        draft.title = String(repeating: "a", count: 200)
        #expect(draft.problems.isEmpty)

        draft.title = " " + String(repeating: "a", count: 200) + " "
        #expect(draft.problems.isEmpty)

        draft.title = String(repeating: "a", count: 199) + "🌱"
        #expect(draft.problems == [.titleTooLong])
    }

    @Test func descriptionLimitCountsLikeJavaScript() {
        var draft = TaskDraft()
        draft.title = "Call"
        draft.description = String(repeating: "a", count: 5000)
        #expect(draft.problems.isEmpty)

        draft.description = String(repeating: "a", count: 4999) + "🌱"
        #expect(draft.problems == [.descriptionTooLong])
    }
}

/// Seam 1: Kategorie-Namen wie in der Web-App (`public/pages/tasks.js`): erst die eigene
/// Übersetzung zu `label_key`, dann `name`, dann der rohe Key (Q8).
@Suite struct TaskCategoryTests {
    let translate: (String) -> String? = { ["tasks.categoryHousehold": "Haushalt"][$0] }

    @Test func builtInCategoryUsesTheTranslation() {
        let category = TaskCategory(key: "household", name: "Household", labelKey: "tasks.categoryHousehold")
        #expect(category.title(translate) == "Haushalt")
    }

    @Test func untranslatedLabelFallsBackToTheName() {
        let category = TaskCategory(key: "garden", name: "Garden", labelKey: "tasks.categoryGarden")
        #expect(category.title(translate) == "Garden")
    }

    @Test func customCategoryUsesItsName() {
        let category = TaskCategory(key: "garden", name: "Garden", labelKey: nil)
        #expect(category.title(translate) == "Garden")
    }

    @Test(arguments: [String?.none, ""])
    func withoutNameShowsTheRawKey(name: String?) {
        let category = TaskCategory(key: "garden", name: name, labelKey: nil)
        #expect(category.title(translate) == "garden")
    }
}
