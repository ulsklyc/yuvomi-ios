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
    /// Läuft, während iOS Mitteilungen entfernt.
    var whileRemoving: (@Sendable () async -> Void)?

    func pending() async -> Set<String> {
        whilePending()
        return Set(planned.keys).union(foreign)
    }

    func delivered() async -> Set<String> { delivered }

    func plan(_ notifications: [PlannedNotification]) async {
        for notification in notifications { planned[notification.id] = notification }
    }

    func remove(_ ids: Set<String>) async {
        await whileRemoving?()
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
        UpcomingReminder(id: id, origin: kind, entityID: 100 + id, title: title, firesAt: now.addingTimeInterval(seconds))
    }

    @Test func plansTheUpcomingRemindersOfTheNextFourteenDays() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200, kind: .event, title: "Elternabend")])

        try await sync.run(now: now)

        // Genau 14 × 86400 s: über die Zeitumstellung wäre ein Kalendertag eine Stunde länger.
        #expect(source.windows == [now...Date(timeIntervalSince1970: 1_793_707_200 + 1_209_600)])
        #expect(scheduler.planned == [
            "reminder.1.task.101": PlannedNotification(
                id: "reminder.1.task.101", reminderID: 1, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600)
            ),
            "reminder.2.event.102": PlannedNotification(
                id: "reminder.2.event.102", reminderID: 2, origin: .event, entityID: 102, title: "Elternabend", firesAt: now.addingTimeInterval(7200)
            ),
        ])
    }

    /// Ein unbekannter Typ wird trotzdem geplant; den allgemeinen Text wählt der Planer.
    @Test func plansAReminderOfAnUnknownType() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200, kind: .unknown, title: "")])

        try await sync.run(now: now)

        #expect(scheduler.planned["reminder.2.unknown.102"] == PlannedNotification(
            id: "reminder.2.unknown.102", reminderID: 2, origin: .unknown, entityID: 102, title: "", firesAt: now.addingTimeInterval(7200)
        ))
        #expect(scheduler.planned.count == 2)
        #expect(ReminderSync.parse("reminder.2.unknown.102")?.origin == .unknown)
    }

    @Test func removesWhatIsNoLongerUpcomingAndLeavesForeignNotifications() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200)])
        try await sync.run(now: now)
        scheduler.foreign = ["other.1"]

        source.result = .success([reminder(2, in: 7200)])
        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.2.task.102"])
        #expect(scheduler.foreign == ["other.1"])
    }

    @Test func aChangedReminderReplacesItsNotification() async throws {
        source.result = .success([reminder(1, in: 3600), reminder(2, in: 7200)])
        try await sync.run(now: now)

        source.result = .success([reminder(1, in: 3600), reminder(2, in: 9000, title: "Strom zahlen, Rest")])
        try await sync.run(now: now)

        #expect(scheduler.planned.count == 2)
        #expect(scheduler.planned["reminder.2.task.102"] == PlannedNotification(
            id: "reminder.2.task.102", reminderID: 2, origin: .task, entityID: 102, title: "Strom zahlen, Rest", firesAt: now.addingTimeInterval(9000)
        ))
    }

    @Test func plansOnlyTheEarliestSixty() async throws {
        // Unsortiert geliefert: Die Kappung darf sich nicht auf die Reihenfolge des Servers verlassen.
        source.result = .success((1...70).reversed().map { reminder($0, in: TimeInterval($0) * 600) })

        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == Set((1...60).map { "reminder.\($0).task.\(100 + $0)" }))
    }

    @Test func leavesOutWhatIsDueWithinFiveSeconds() async throws {
        source.result = .success([reminder(1, in: 4), reminder(2, in: 5), reminder(3, in: -60)])

        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.2.task.102"])
    }

    @Test(arguments: [APIError.unauthorized, .unreachable, .unexpectedResponse])
    func aFailedFetchLeavesThePlannedNotificationsAndReportsTheError(error: APIError) async throws {
        source.result = .success([reminder(1, in: 3600)])
        try await sync.run(now: now)

        source.result = .failure(error)
        await #expect(throws: error) { try await sync.run(now: now) }

        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.101"])
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

        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.101"])
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
        await scheduler.plan([PlannedNotification(id: "reminder.9.event.109", reminderID: 9, origin: .event, entityID: 109, title: "Filmabend", firesAt: now.addingTimeInterval(7200))])
        source.result = .success([reminder(1, in: 3600)])
        scheduler.whilePending = { withUnsafeCurrentTask { $0?.cancel() } }

        try await sync.run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.9.event.109"])
    }
}

@Suite struct ReminderSyncRepliesTests {
    /// 2026-11-03 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_707_200)
    let source = FakeUpcomingReminders()
    let scheduler = FakeScheduler()

    func reminder(_ id: Int, entity: Int, origin: ReminderOrigin = .task) -> UpcomingReminder {
        UpcomingReminder(id: id, origin: origin, entityID: entity, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600 + TimeInterval(id)))
    }

    func reply(_ kind: ReminderReply.Kind, reminder: Int, entity: Int, origin: ReminderOrigin = .task) -> ReminderReply {
        ReminderReply(kind: kind, reminderID: reminder, origin: origin, entityID: entity, title: "Strom zahlen", at: now)
    }

    @Test func theIdentifierCarriesReminderOriginAndEntity() {
        let id = ReminderSync.id(reminder: 7, origin: .event, entityID: 12)

        #expect(id == "reminder.7.event.12")
        let parsed = ReminderSync.parse(id)
        #expect(parsed?.reminder == 7)
        #expect(parsed?.origin == .event)
        #expect(parsed?.entityID == 12)
    }

    /// Kennungen aus Slice 3 und fremde gehören zu keiner Aufgabe.
    @Test(arguments: ["reminder.7", "reminder.7.note.12", "reminder.x.task.12", "other.7.task.12", "reminder.7.task.12.1"])
    func otherIdentifiersAreNotParsed(id: String) {
        #expect(ReminderSync.parse(id) == nil)
    }

    /// Ein Hinweis wie „Nicht abgehakt“ bleibt beim Abgleich, geht aber beim Abräumen mit.
    @Test func aNoticeSurvivesTheSyncButNotTheClear() async throws {
        scheduler.planned["reminder.notice.1"] = PlannedNotification(id: "reminder.notice.1", reminderID: 0, origin: .task, entityID: 0, title: "x", firesAt: now)
        source.result = .success([])

        try await ReminderSync(source: source, scheduler: scheduler).run(now: now)
        #expect(Set(scheduler.planned.keys) == ["reminder.notice.1"])

        await ReminderSync.clear(scheduler: scheduler)
        #expect(scheduler.planned.isEmpty)
    }

    /// Ein Abgleich nach dem Update ersetzt die Kennungen aus Slice 3.
    @Test func anOldIdentifierIsReplaced() async throws {
        scheduler.planned["reminder.1"] = PlannedNotification(id: "reminder.1", reminderID: 1, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600))
        source.result = .success([reminder(1, entity: 101)])

        try await ReminderSync(source: source, scheduler: scheduler).run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.101"])
    }

    /// Was der Server noch nicht weiß, plant der Abgleich nicht wieder ein: die verworfene
    /// Erinnerung und jede Erinnerung einer abgehakten Aufgabe. Verwerfen lässt die übrigen
    /// Erinnerungen derselben Aufgabe stehen.
    @Test func leavesOutWhatTheServerHasNotHeardYet() async throws {
        source.result = .success([
            reminder(1, entity: 101), reminder(2, entity: 101),
            reminder(3, entity: 102), reminder(4, entity: 102),
            reminder(5, entity: 101, origin: .event),
        ])

        try await ReminderSync(source: source, scheduler: scheduler).run(now: now, replies: [
            reply(.checkOff, reminder: 1, entity: 101),
            reply(.dismiss, reminder: 3, entity: 102),
        ])

        #expect(Set(scheduler.planned.keys) == ["reminder.4.task.102", "reminder.5.event.101"])
    }

    /// Aufgaben und Termine zählen getrennt: Ein Termin 101 ist nicht die Aufgabe 101.
    @Test func onlyACheckedOffTaskIsLeftOut() async throws {
        source.result = .success([reminder(1, entity: 9)])

        try await ReminderSync(source: source, scheduler: scheduler).run(now: now, replies: [
            reply(.checkOff, reminder: 2, entity: 9, origin: .event),
        ])

        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.9"])
    }

    /// Beim ersten Abgleich nach dem Update: Eine alte Kennung, die gleich fällt, bleibt stehen.
    @Test func anOldIdentifierAboutToFireIsKept() async throws {
        scheduler.planned["reminder.1"] = PlannedNotification(id: "reminder.1", reminderID: 1, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3))
        source.result = .success([UpcomingReminder(id: 1, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3))])

        try await ReminderSync(source: source, scheduler: scheduler).run(now: now)

        #expect(Set(scheduler.planned.keys) == ["reminder.1"])
    }

    @Test func removesThePlannedAndDeliveredNotificationsOfOneTask() async {
        await scheduler.plan([
            PlannedNotification(id: "reminder.1.task.101", reminderID: 1, origin: .task, entityID: 101, title: "a", firesAt: now),
            PlannedNotification(id: "reminder.2.task.102", reminderID: 2, origin: .task, entityID: 102, title: "b", firesAt: now),
            PlannedNotification(id: "reminder.3.event.101", reminderID: 3, origin: .event, entityID: 101, title: "c", firesAt: now),
        ])
        scheduler.delivered = ["reminder.4.task.101", "reminder.5.task.102", "other.1"]

        await ReminderSync.remove(origin: .task, entityID: 101, scheduler: scheduler)

        #expect(Set(scheduler.planned.keys) == ["reminder.2.task.102", "reminder.3.event.101"])
        #expect(scheduler.delivered == ["reminder.5.task.102", "other.1"])
    }
}
