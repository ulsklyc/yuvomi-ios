import Testing
import YuvomiCore

@Suite struct SubtaskProgressTests {
    @Test func withoutSubtasksThereIsNoProgress() {
        #expect(SubtaskProgress(done: 0, total: 0) == nil)
    }

    @Test func doneStaysWithinTheTotal() {
        #expect(SubtaskProgress(done: 2, total: 5).map { [$0.done, $0.total] } == [2, 5])
        #expect(SubtaskProgress(done: 7, total: 5)?.done == 5)
        #expect(SubtaskProgress(done: -1, total: 5)?.done == 0)
    }
}
