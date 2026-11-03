import Foundation
import Testing
import YuvomiCore

/// Port-Fake: was der Server als kommende Erinnerungen liefert.
final class FakeUpcomingReminders: UpcomingReminders, @unchecked Sendable {
    var result: Result<[UpcomingReminder], APIError> = .success([])
    /// Läuft, während der Abruf auf den Server wartet.
    var whileWaiting: (@Sendable () async -> Void)?
    private(set) var windows: [ClosedRange<Date>] = []

    func upcoming(from: Date, to: Date) async throws(APIError) -> [UpcomingReminder] {
        windows.append(from...to)
        await whileWaiting?()
        return try result.get()
    }
}

/// Port-Fake: die geplanten Mitteilungen auf dem Gerät, samt fremder.
final class FakeScheduler: NotificationScheduling, @unchecked Sendable {
    var planned: [String: PlannedNotification] = [:]
    /// Kennungen anderer Herkunft, die der Abgleich nicht anfassen darf.
    var foreign: Set<String> = []
    /// Schon zugestellt, in der Mitteilungszentrale.
    var delivered: Set<String> = []
    /// Läuft, während der Abgleich die geplanten Mitteilungen liest.
    var whilePending: () -> Void = {}

    func pending() async -> Set<String> {
        whilePending()
        return Set(planned.keys).union(foreign)
    }

    func delivered() async -> Set<String> { delivered }

    func plan(_ notifications: [PlannedNotification]) async {
        for notification in notifications { planned[notification.id] = notification }
    }

    func remove(_ ids: Set<String>) async {
        for id in ids { planned[id] = nil; foreign.remove(id); delivered.remove(id) }
    }
}

@Suite struct ReminderSyncTests {
    /// 2026-11-03 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_707_200)
    let source = FakeUpcomingReminders()
    let scheduler = FakeScheduler()

    var sync: ReminderSync { ReminderSync(source: source, scheduler: scheduler) }

    func reminder(_ id: Int, in seconds: TimeInterval, kind: ReminderOrigin = .task, title: String = "Strom zahlen") -> UpcomingReminder {
        UpcomingReminder(id: id, origin: kind, title: title, firesAt: now.addingTimeInterval(seconds))
    }

    @Test func plansTheUpcomingRemindersOfTheNextFourteenDays() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200, kind: .event, title: "Elternabend")])

        try await sync.run(now: now)

        // Genau 14 × 86400 s: über die Zeitumstellung wäre ein Kalendertag eine Stunde länger.
        #expect(source.windows == [now...Date(timeIntervalSince1970: 1_793_707_200 + 1_209_600)])
        #expect(scheduler.planned == [
            "reminder.1": PlannedNotification(id: "reminder.1", origin: .task, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600)),
            "reminder.2": PlannedNotification(id: "reminder.2", origin: .event, title: "Elternabend", firesAt: now.addingTimeInterval(7200)),
        ])
    }

    @Test func removesWhatIsNoLongerUpcomingAndLeavesForeignNotifications() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200)])
        try await sync.run(now: now)
        scheduler.foreign = ["other.1"]

        source.result = .success([reminder(2, in: 7200)])
        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.2"])
        #expect(scheduler.foreign == ["other.1"])
    }

    @Test func aChangedReminderReplacesItsNotification() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200)])
        try await sync.run(now: now)

        source.result = .success([reminder(1, in: 3600), reminder(2, in: 9000, title: "Strom zahlen, Rest")])
        try await sync.run(now: now)

        #expect(scheduler.planned.count == 2)
        #expect(scheduler.planned["reminder.2"] == PlannedNotification(
            id: "reminder.2", origin: .task, title: "Strom zahlen, Rest", firesAt: now.addingTimeInterval(9000)
        ))
    }

    @Test func plansOnlyTheEarliestSixty() async throws {
        // Unsortiert geliefert: Die Kappung darf sich nicht auf die Reihenfolge des Servers verlassen.
        source.result = .success((1...70).reversed().map { reminder($0, in: TimeInterval($0) * 600) })

        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == Set((1...60).map { "reminder.\($0)" }))
    }

    @Test func leavesOutWhatIsDueWithinFiveSeconds() async throws {
        source.result = .success([reminder(1, in: 4), reminder(2, in: 5), reminder(3, in: -60)])

        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.2"])
    }

    @Test(arguments: [APIError.unauthorized, .unreachable, .unexpectedResponse])
    func aFailedFetchLeavesThePlannedNotificationsAndReportsTheError(error: APIError) async throws {
        source.result = .success([reminder(1, in: 3600)])
        try await sync.run(now: now)

        source.result = .failure(error)
        await #expect(throws: error) { try await sync.run(now: now) }

        #expect(Set(scheduler.planned.keys) == ["reminder.1"])
    }

    @Test func clearRemovesEveryReminderButNothingForeign() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200)])
        try await sync.run(now: now)
        scheduler.foreign = ["other.1"]

        await sync.clear()

        #expect(scheduler.planned.isEmpty)
        #expect(scheduler.foreign == ["other.1"])
    }

    /// Was schon geplant ist und gleich fällt, bleibt stehen: Entfernen hieße, es zu verpassen.
    @Test func keepsAPlannedNotificationThatIsAboutToFire() async throws {
        source.result = .success([reminder(1, in: 3600)])
        try await sync.run(now: now)

        try await sync.run(now: now.addingTimeInterval(3597))

        #expect(Set(scheduler.planned.keys) == ["reminder.1"])
    }

    @Test func clearAlsoRemovesDeliveredNotifications() async throws {
        scheduler.delivered = ["reminder.7", "other.2"]

        await sync.clear()

        #expect(scheduler.delivered == ["other.2"])
    }

    /// Abmelden bricht einen laufenden Abgleich ab, bevor es abräumt. Kommt die Antwort danach,
    /// darf sie nichts mehr planen.
    @Test func aCancelledSyncPlansNothing() async throws {
        source.result = .success([reminder(1, in: 3600)])
        source.whileWaiting = { withUnsafeCurrentTask { $0?.cancel() } }

        try await sync.run(now: now)

        #expect(scheduler.planned.isEmpty)
    }

    /// Nimmt iOS dem Hintergrund-Task die Zeit, während der Abgleich bei iOS liest, hört er auf:
    /// nichts entfernen, nichts planen.
    @Test func aSyncCancelledWhileReadingThePlannedNotificationsStops() async throws {
        await scheduler.plan([PlannedNotification(id: "reminder.9", origin: .event, title: "Filmabend", firesAt: now.addingTimeInterval(7200))])
        source.result = .success([reminder(1, in: 3600)])
        scheduler.whilePending = { withUnsafeCurrentTask { $0?.cancel() } }

        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.9"])
    }
}
