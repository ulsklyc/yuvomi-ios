import Testing
import YuvomiCore

/// Q7 und Q8: wer eine Aufgabe ändern darf, und welche Kategorie zu einem Key gehört.
@Suite struct TaskRulesTests {
    func task(locked: Bool, by creator: Int?) -> TaskDetail {
        TaskDetail(id: 1, title: "Call", status: .open, priority: .none, isLocked: locked, createdBy: creator)
    }

    @Test func anUnlockedTaskIsEditableByAnyone() {
        #expect(task(locked: false, by: 3).isEditable(by: 1))
        #expect(task(locked: false, by: nil).isEditable(by: nil))
    }

    @Test func aLockedTaskOnlyByItsCreator() {
        #expect(task(locked: true, by: 1).isEditable(by: 1))
        #expect(!task(locked: true, by: 3).isEditable(by: 1))
        #expect(!task(locked: true, by: 1).isEditable(by: nil))
    }

    /// F1: Fehlt die Angabe, wer sie angelegt hat, gilt sie als fremd.
    @Test func aLockedTaskWithoutCreatorIsForeign() {
        #expect(!task(locked: true, by: nil).isEditable(by: nil))
        #expect(!task(locked: true, by: nil).isEditable(by: 1))
    }

    @Test func aCategoryIsLookedUpByKey() {
        let garden = TaskCategory(key: "garden", name: "Garten", labelKey: nil)
        let options = TaskOptions(people: [], categories: [garden])

        #expect(options.category(for: "garden") == garden)
        #expect(options.category(for: "gone") == TaskCategory(key: "gone", name: nil, labelKey: nil))
    }
}
