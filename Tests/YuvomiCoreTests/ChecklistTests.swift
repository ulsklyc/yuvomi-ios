import Testing
import YuvomiCore

/// Seam 1: dieselbe Regel wie `public/utils/markdown-checklist.js` in `v2.84.0`. Die Fälle folgen
/// `test/test-tasks-checklist.js`. Weicht die App ab, kreuzt sie eine Zeile an, die der Server
/// anders zählt oder nicht als Checkliste kennt.
@Suite struct ChecklistTests {
    @Test func countsLinesLikeTheServer() {
        let checklist = Checklist(description: "Intro\r\n- [ ] One\r- [x] Two\n\n- [ ] Three")

        #expect(checklist.lines.map(\.index) == [0, 1, 2, 3, 4])
        #expect(checklist.items.map(\.index) == [1, 2, 4])
        #expect(checklist.items.map(\.text) == ["One", "Two", "Three"])
        #expect(checklist.items.map(\.isChecked) == [false, true, false])
    }

    /// `expect` ist die rohe Zeile ohne Trenner, so wie der Server sie vergleicht.
    @Test func keepsTheRawLineForExpect() {
        let checklist = Checklist(description: "- [ ] One\r\n  * [X]   Two  ")

        #expect(checklist.lines.map(\.raw) == ["- [ ] One", "  * [X]   Two  "])
        #expect(checklist.items.last?.text == "Two  ")
        #expect(checklist.items.last?.isChecked == true)
    }

    @Test(arguments: [
        ("- [ ] a", true),
        ("* [ ] a", true),
        ("+ [x] a", true),
        ("   - [X] a", true),
        ("    - [ ] a", false),
        ("-[ ] a", false),
        ("- [ ]a", false),
        ("- [ ]", false),
        ("- [ ] ", true),
        ("- [y] a", false),
        ("- \t[ ]\ta", true),
        ("\t- [ ] a", false),
        ("1. [ ] a", false),
    ])
    func recognisesChecklistLines(line: String, isItem: Bool) {
        #expect((Checklist(description: line).items.first != nil) == isItem)
    }

    @Test func withoutDescriptionThereAreNoLines() {
        #expect(Checklist(description: nil).lines.isEmpty)
        #expect(Checklist(description: "Just text").items.isEmpty)
    }

    /// Fixtures/demo/task-checklist.json, so wie der Server sie ausliefert.
    @Test func readsTheFixtureDescription() {
        let checklist = Checklist(description: "Leave by **Friday 5 pm**.\n\n- [x] Book the cabin\n- [ ] Pack sleeping bags\n  * [X] Charge the power bank\n- [ ] Buy snacks\n-[ ] not a checklist line")

        #expect(checklist.items.map(\.index) == [2, 3, 4, 5])
        #expect(checklist.items.map(\.isChecked) == [true, false, true, false])
        #expect(checklist.lines.last?.item == nil)
    }
}
