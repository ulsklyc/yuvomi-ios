import Testing
@testable import TasksFeature

/// Die Sperre fürs Ankreuzen gilt je Aufgabe, nicht für alle (Issue #23).
@MainActor @Suite struct StatusOverlayTests {
    @Test func tickingLocksOnlyItsOwnTask() {
        let overlay = StatusOverlay()

        #expect(overlay.beginTick(1))
        #expect(!overlay.beginTick(1))
        #expect(overlay.beginTick(2))
        overlay.finishTick(1)
        #expect(!overlay.isTicking(1))
        #expect(overlay.isTicking(2))
        #expect(overlay.beginTick(1))
    }
}
