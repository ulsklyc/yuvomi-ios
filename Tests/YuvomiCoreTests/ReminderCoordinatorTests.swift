import Foundation
import Testing
import YuvomiCore

/// Hält den Abruf fest, bis der Test das Tor öffnet. So lassen sich Aufträge mitten im
/// Abruf dazwischenschieben.
final class Gate: @unchecked Sendable {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume() } else { waiting.append(continuation); lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let all = waiting
        waiting = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}

@MainActor @Suite struct ReminderCoordinatorTests {
    /// 2026-11-03 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_707_200)
    let session = Session(server: URL(string: "https://yuvomi.example.com")!, credential: "ydc_test")
    let source = FakeUpcomingReminders()
    let scheduler = FakeScheduler()
    let gate = Gate()

    func coordinator(onUnauthorized: @escaping @MainActor (Session) -> Void = { _ in }) -> ReminderCoordinator {
        source.result = .success([UpcomingReminder(id: 1, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600))])
        let gate = gate
        source.whileWaiting = { await gate.wait() }
        let source = source
        return ReminderCoordinator(
            makeSource: { _ in source },
            makeWriter: { _ in FakeWriter(log: EventLog()) },
            scheduler: scheduler,
            queue: FakeReplyQueue(),
            now: { [now] in now },
            onUnauthorized: onUnauthorized,
            onNotCheckedOff: { _ in }
        )
    }

    /// Lässt gestartete Aufträge bis zu ihrem ersten Warten laufen.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func switchingOffAndOnQuicklyEndsWithPlannedReminders() async {
        let reminders = coordinator()
        let first = Task { await reminders.sync(session) }
        await settle()
        let off = Task { await reminders.clear() }
        let on = Task { await reminders.sync(session) }
        await settle()

        gate.open()
        _ = await (first.value, off.value, on.value)

        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.101"])
    }

    @Test func signingOutDuringTheFetchLeavesNothingBehind() async {
        let reminders = coordinator()
        let sync = Task { await reminders.sync(session) }
        await settle()
        let signOut = Task { await reminders.clear() }
        await settle()

        gate.open()
        _ = await (sync.value, signOut.value)

        #expect(scheduler.planned.isEmpty)
    }

    @Test func aSecondSyncWhileOneRunsJoinsIt() async {
        let reminders = coordinator()
        let first = Task { await reminders.sync(session) }
        let second = Task { await reminders.sync(session) }
        await settle()

        gate.open()
        _ = await (first.value, second.value)

        #expect(source.windows.count == 1)
        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.101"])
    }

    /// Anhängen nur an einen laufenden Abgleich. Sonst gliche nach dem ersten Abgleich nichts
    /// mehr ab, auch nach einem Netzfehler nicht.
    @Test func aSyncAfterAFinishedOneFetchesAgain() async {
        let reminders = coordinator()
        gate.open()

        await reminders.sync(session)
        await reminders.sync(session)

        #expect(source.windows.count == 2)
    }

    @Test func aRevokedCredentialIsReported() async {
        var revoked: [Session] = []
        let reminders = coordinator { revoked.append($0) }
        source.result = .failure(.unauthorized)
        gate.open()

        await reminders.sync(session)

        #expect(revoked == [session])
    }

    /// Startet iOS die App nur für den Hintergrund-Abgleich, gibt es keine View, die auf das
    /// Ende der Sitzung reagiert. Der Abgleich räumt selbst ab.
    @Test func aRevokedCredentialLeavesNothingBehind() async {
        await scheduler.plan([PlannedNotification(id: "reminder.9.event.109", reminderID: 9, origin: .event, entityID: 109, title: "Filmabend", firesAt: now.addingTimeInterval(7200))])
        let reminders = coordinator()
        source.result = .failure(.unauthorized)
        gate.open()

        await reminders.sync(session)

        #expect(scheduler.planned.isEmpty)
    }
}
