import Foundation
import Testing
import YuvomiCore

/// Hält fest, in welcher Reihenfolge Server-Aufrufe ankommen.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] { lock.withLock { storage } }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}

/// Port-Fake: der Server beim Zurückschreiben.
final class FakeWriter: ReminderWriting, @unchecked Sendable {
    var dismissResult: Result<Void, APIError> = .success(())
    var checkOffResult: Result<Void, APIError> = .success(())
    /// Läuft, während ein Aufruf auf den Server wartet.
    var whileSending: (@Sendable () async -> Void)?
    let log: EventLog

    init(log: EventLog) {
        self.log = log
    }

    func dismiss(reminder id: Int) async throws(APIError) {
        log.append("dismiss \(id)")
        await whileSending?()
        // Wie `URLSession`: Ein abgebrochener Aufruf kommt ohne Antwort zurück.
        if Task.isCancelled { throw .unreachable }
        try dismissResult.get()
    }

    func checkOff(task id: Int) async throws(APIError) {
        log.append("checkOff \(id)")
        await whileSending?()
        if Task.isCancelled { throw .unreachable }
        try checkOffResult.get()
    }
}

/// Wahr nur beim ersten Aufruf.
final class FirstTime: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.withLock {
            defer { used = true }
            return !used
        }
    }
}

/// Port-Fake: die Warteschlange im Speicher.
@MainActor final class FakeReplyQueue: ReplyQueue {
    private(set) var replies: [ReminderReply] = []

    func append(_ reply: ReminderReply) { replies.append(reply) }
    func replace(_ reply: ReminderReply, with new: ReminderReply) { replies = replies.map { $0 == reply ? new : $0 } }
    func remove(_ reply: ReminderReply) { replies.removeAll { $0 == reply } }
    func removeAll() { replies = [] }
}

@MainActor @Suite struct ReminderReplyTests {
    /// 2026-11-03 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_793_707_200)
    let session = Session(server: URL(string: "https://yuvomi.example.com")!, credential: "ydc_test")
    let log = EventLog()
    let source = FakeUpcomingReminders()
    let writer: FakeWriter
    let scheduler = FakeScheduler()
    let queue = FakeReplyQueue()
    let gate = Gate()

    init() {
        writer = FakeWriter(log: log)
        let log = log
        source.whileWaiting = { log.append("fetch") }
    }

    func coordinator(
        makeWriter: ((Session) -> any ReminderWriting)? = nil,
        onUnauthorized: @escaping @MainActor (Session) -> Void = { _ in },
        onNotCheckedOff: @escaping @MainActor (ReminderReply) async -> Void = { _ in }
    ) -> ReminderCoordinator {
        let source = source
        let writer = writer
        return ReminderCoordinator(
            makeSource: { _ in source },
            makeWriter: makeWriter ?? { _ in writer },
            scheduler: scheduler,
            queue: queue,
            now: { [now] in now },
            onUnauthorized: onUnauthorized,
            onNotCheckedOff: onNotCheckedOff
        )
    }

    func reply(_ kind: ReminderReply.Kind, reminder: Int = 1, entity: Int = 101, origin: ReminderOrigin = .task, ago: TimeInterval = 60) -> ReminderReply {
        ReminderReply(kind: kind, reminderID: reminder, origin: origin, entityID: entity, title: "Strom zahlen", at: now.addingTimeInterval(-ago))
    }

    func planned(_ reminder: Int, _ origin: ReminderOrigin, _ entity: Int) -> PlannedNotification {
        PlannedNotification(
            id: ReminderSync.id(reminder: reminder, origin: origin, entityID: entity), reminderID: reminder,
            origin: origin, entityID: entity, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600)
        )
    }

    /// Lässt gestartete Aufträge bis zu ihrem ersten Warten laufen.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Bis `condition` gilt, höchstens aber für `limit` Runden: Danach prüft der Test und scheitert.
    func until(limit: Int = 10_000, _ condition: () -> Bool) async {
        var round = 0
        while !condition(), round < limit {
            await Task.yield()
            round += 1
        }
    }

    // MARK: Abhaken und Verwerfen

    @Test func checkingOffSetsTheTaskDoneThenDismissesAndClearsTheWholeTask() async {
        await scheduler.plan([planned(1, .task, 101), planned(3, .task, 101), planned(2, .task, 102)])
        scheduler.delivered = [ReminderSync.id(reminder: 1, origin: .task, entityID: 101)]

        await coordinator().reply(reply(.checkOff), session: session)

        #expect(log.events == ["checkOff 101", "dismiss 1"])
        #expect(Set(scheduler.planned.keys) == ["reminder.2.task.102"])
        #expect(scheduler.delivered.isEmpty)
        #expect(queue.replies.isEmpty)
    }

    /// Verwerfen heißt „gesehen“: nur diese Mitteilung, die übrigen Erinnerungen bleiben.
    @Test func dismissingTouchesOnlyThisReminder() async {
        await scheduler.plan([planned(1, .task, 101), planned(3, .task, 101)])

        await coordinator().reply(reply(.dismiss), session: session)

        #expect(log.events == ["dismiss 1"])
        #expect(Set(scheduler.planned.keys) == ["reminder.3.task.101"])
        #expect(queue.replies.isEmpty)
    }

    /// Ein Termin kennt kein „erledigt“: Auch eine falsch gebaute Rückmeldung verwirft nur.
    @Test func anEventIsNeverCheckedOff() async {
        await coordinator().reply(reply(.checkOff, reminder: 4, entity: 9, origin: .event), session: session)

        #expect(log.events == ["dismiss 4"])
    }

    /// Ohne Anmeldung gibt es niemanden, an den die Rückmeldung ginge.
    @Test func withoutASessionOnlyTheDeviceIsCleared() async {
        await scheduler.plan([planned(1, .task, 101)])

        await coordinator().reply(reply(.checkOff), session: nil)

        #expect(log.events.isEmpty)
        #expect(scheduler.planned.isEmpty)
        #expect(queue.replies.isEmpty)
    }

    /// Vor dem ersten Entsperren ist die Anmeldung nicht lesbar: Die Rückmeldung bleibt
    /// gemerkt und geht mit dem nächsten Abgleich raus (Befund von Codex zu #8).
    @Test func aReplyWhileTheSessionIsUnreadableWaitsForTheNextSync() async {
        await scheduler.plan([planned(1, .task, 101)])
        let reminders = coordinator()

        await reminders.reply(reply(.checkOff), session: nil, keepWithoutSession: true)
        #expect(log.events.isEmpty)
        #expect(scheduler.planned.isEmpty)
        #expect(queue.replies == [reply(.checkOff)])

        await reminders.sync(session)
        #expect(log.events == ["checkOff 101", "dismiss 1", "fetch"])
        #expect(queue.replies.isEmpty)
    }

    // MARK: Fehler

    @Test func withoutNetworkTheReplyWaitsForTheNextSyncAndGoesFirst() async {
        writer.checkOffResult = .failure(.unreachable)
        let reminders = coordinator()
        await reminders.reply(reply(.checkOff), session: session)
        #expect(queue.replies.count == 1)

        writer.checkOffResult = .success(())
        await reminders.sync(session)

        #expect(log.events == ["checkOff 101", "checkOff 101", "dismiss 1", "fetch"])
        #expect(queue.replies.isEmpty)
    }

    /// Scheitert das Senden, darf der Abruf danach die abgehakte Aufgabe nicht wieder einplanen.
    @Test func aSyncDoesNotReplanAnAnsweredTask() async {
        writer.checkOffResult = .failure(.unexpectedResponse)
        source.result = .success([
            UpcomingReminder(id: 3, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600)),
            UpcomingReminder(id: 2, origin: .task, entityID: 102, title: "Müll", firesAt: now.addingTimeInterval(3600)),
        ])
        let reminders = coordinator()
        await reminders.reply(reply(.checkOff), session: session)

        await reminders.sync(session)

        #expect(log.events.last == "fetch")
        #expect(Set(scheduler.planned.keys) == ["reminder.2.task.102"])
        #expect(queue.replies.count == 1)
    }

    @Test func aRevokedCredentialForgetsTheRepliesAndClearsEverything() async {
        await scheduler.plan([planned(2, .event, 9)])
        writer.dismissResult = .failure(.unauthorized)
        var revoked: [Session] = []
        let reminders = coordinator(onUnauthorized: { revoked.append($0) })
        await reminders.reply(reply(.dismiss), session: session)

        #expect(revoked == [session])
        #expect(queue.replies.isEmpty)
        #expect(scheduler.planned.isEmpty)
    }

    /// Ein Widerruf beim Senden vor dem Abgleich: kein Abruf mehr mit dem alten Credential.
    @Test func aSyncStopsWhenSendingFindsTheCredentialRevoked() async {
        writer.checkOffResult = .failure(.unreachable)
        var revoked: [Session] = []
        let reminders = coordinator(onUnauthorized: { revoked.append($0) })
        await reminders.reply(reply(.checkOff), session: session)

        writer.checkOffResult = .failure(.unauthorized)
        await reminders.sync(session)

        #expect(!log.events.contains("fetch"))
        #expect(revoked == [session])
    }

    /// Nur lesen erlaubt: Die Aufgabe bleibt offen, die Person erfährt es, und die Erinnerung
    /// bleibt am Server, damit die Web-App weiter mahnt.
    @Test func aRefusedCheckOffIsAnnouncedAndNotDismissed() async {
        writer.checkOffResult = .failure(.forbidden)
        var announced: [ReminderReply] = []
        let answer = reply(.checkOff)

        await coordinator(onNotCheckedOff: { announced.append($0) }).reply(answer, session: session)

        #expect(log.events == ["checkOff 101"])
        #expect(announced == [answer])
        #expect(queue.replies.isEmpty)
    }

    /// Gelöscht oder nicht mehr sichtbar: still, die Erinnerung trotzdem verwerfen.
    @Test func aMissingTaskIsSilentAndStillDismissed() async {
        writer.checkOffResult = .failure(.notFound)
        var announced: [ReminderReply] = []

        await coordinator(onNotCheckedOff: { announced.append($0) }).reply(reply(.checkOff), session: session)

        #expect(log.events == ["checkOff 101", "dismiss 1"])
        #expect(announced.isEmpty)
        #expect(queue.replies.isEmpty)
    }

    @Test(arguments: [APIError.forbidden, .notFound])
    func aRefusedDismissIsDroppedSilently(error: APIError) async {
        writer.dismissResult = .failure(error)
        var announced: [ReminderReply] = []

        await coordinator(onNotCheckedOff: { announced.append($0) }).reply(reply(.dismiss), session: session)

        #expect(announced.isEmpty)
        #expect(queue.replies.isEmpty)
    }

    /// Ein spätes Abhaken könnte eine inzwischen wieder geöffnete Aufgabe schließen.
    @Test func aReplyOlderThanADayIsDroppedUnsent() async {
        writer.dismissResult = .failure(.unreachable)
        writer.checkOffResult = .failure(.unreachable)
        let reminders = coordinator()
        await reminders.reply(reply(.checkOff, reminder: 1, ago: 24 * 3600 + 1), session: session)
        await reminders.reply(reply(.dismiss, reminder: 2, ago: 24 * 3600), session: session)
        writer.dismissResult = .success(())
        writer.checkOffResult = .success(())
        let before = log.events.count

        await reminders.sendReplies(session)

        #expect(Array(log.events.dropFirst(before)) == ["dismiss 2"])
        #expect(queue.replies.isEmpty)
    }

    /// Abgehakt, aber das Verwerfen kam nicht an: Der nächste Versuch hakt nicht noch einmal ab.
    /// Sonst schlösse er eine Aufgabe, die jemand inzwischen wieder geöffnet hat.
    @Test func afterACheckOffOnlyTheDismissIsRetried() async {
        writer.dismissResult = .failure(.unreachable)
        let reminders = coordinator()
        await reminders.reply(reply(.checkOff), session: session)
        #expect(queue.replies == [reply(.dismiss)])

        writer.dismissResult = .success(())
        await reminders.sendReplies(session)

        #expect(log.events == ["checkOff 101", "dismiss 1", "dismiss 1"])
        #expect(queue.replies.isEmpty)
    }

    /// Eine Antwort, die der Server immer wieder ablehnt, hält die übrigen nicht auf.
    @Test func anUnexpectedAnswerDoesNotBlockTheOthers() async {
        writer.dismissResult = .failure(.unreachable)
        let reminders = coordinator()
        await reminders.reply(reply(.dismiss, reminder: 1), session: session)
        await reminders.reply(reply(.dismiss, reminder: 2), session: session)
        writer.dismissResult = .failure(.unexpectedResponse)
        writer.checkOffResult = .success(())
        let before = log.events.count

        await reminders.sendReplies(session)

        #expect(Array(log.events.dropFirst(before)) == ["dismiss 1", "dismiss 2"])
        #expect(queue.replies.count == 2)
    }

    /// Ohne Netz hört das Senden beim ersten Versuch auf, der Rest wartet auf den nächsten Abgleich.
    @Test func withoutNetworkSendingStopsAtTheFirst() async {
        writer.dismissResult = .failure(.unreachable)
        let reminders = coordinator()
        await reminders.reply(reply(.dismiss, reminder: 1), session: session)
        await reminders.reply(reply(.dismiss, reminder: 2), session: session)
        let before = log.events.count

        await reminders.sendReplies(session)

        #expect(Array(log.events.dropFirst(before)) == ["dismiss 1"])
    }

    // MARK: Reihenfolge mit Abräumen

    /// Die Mitteilungen gehen sofort, auch wenn vor der Rückmeldung ein langsamer Abgleich wartet.
    @Test func theDeviceIsClearedBeforeAWaitingSyncEnds() async {
        let gate = gate
        let log = log
        source.whileWaiting = { log.append("fetch"); await gate.wait() }
        await scheduler.plan([planned(3, .task, 101)])
        let reminders = coordinator()
        let sync = Task { await reminders.sync(session) }
        await gate.untilWaiting()

        let answer = Task { await reminders.reply(reply(.checkOff), session: session) }
        await until { scheduler.planned.isEmpty }
        #expect(scheduler.planned.isEmpty)

        gate.open()
        _ = await (sync.value, answer.value)
    }

    /// Abmelden, während ein abgelehntes Abhaken unterwegs ist: kein Hinweis für das alte Konto.
    @Test func noAnnouncementAfterSigningOut() async {
        let gate = gate
        writer.whileSending = { await gate.wait() }
        writer.checkOffResult = .failure(.forbidden)
        var announced: [ReminderReply] = []
        let reminders = coordinator(onNotCheckedOff: { announced.append($0) })
        let sending = Task { await reminders.reply(reply(.checkOff), session: session) }
        await gate.untilWaiting()

        let signOut = Task { await reminders.clear() }
        // clear() leert die Warteschlange, bevor es wartet: Daran ist zu sehen, dass es lief.
        await until { queue.replies.isEmpty }
        gate.open()
        _ = await (sending.value, signOut.value)

        #expect(announced.isEmpty)
    }


    /// Abmelden, während eine Rückmeldung auf den Server wartet: Danach geht für das alte
    /// Konto nichts mehr raus.
    @Test func signingOutWhileSendingForgetsTheReplies() async {
        let gate = gate
        writer.whileSending = { await gate.wait() }
        let reminders = coordinator()
        let sending = Task { await reminders.reply(reply(.checkOff), session: session) }
        await gate.untilWaiting()

        let signOut = Task { await reminders.clear() }
        // clear() leert die Warteschlange, bevor es wartet: Daran ist zu sehen, dass es lief.
        await until { queue.replies.isEmpty }
        gate.open()
        _ = await (sending.value, signOut.value)
        await reminders.sync(session)

        #expect(queue.replies.isEmpty)
        #expect(log.events == ["checkOff 101", "fetch"])
    }

    /// Abmelden, während die Rückmeldung von Konto A noch die Mitteilungen entfernt, und gleich
    /// danach meldet sich Konto B an: Der Auftrag von A darf B's Rückmeldungen nicht senden
    /// (Befund von Codex zu #7).
    @Test func aReplyOfTheOldAccountNeverSendsTheNewOne() async {
        let gate = gate
        scheduler.whileRemoving = { await gate.wait() }
        let accountA = session
        let accountB = Session(server: session.server, credential: "ydc_b")
        let writerA = FakeWriter(log: EventLog())
        let writerB = FakeWriter(log: EventLog())
        let reminders = coordinator(makeWriter: { $0 == accountA ? writerA : writerB })

        let first = Task { await reminders.reply(reply(.dismiss, reminder: 1), session: accountA) }
        await gate.untilWaiting()
        let signOut = Task { await reminders.clear() }
        // clear() leert die Warteschlange, bevor es wartet: Daran ist zu sehen, dass es lief.
        await until { queue.replies.isEmpty }
        let second = Task { await reminders.reply(reply(.dismiss, reminder: 2), session: accountB) }
        await settle()
        gate.open()
        _ = await (first.value, signOut.value, second.value)

        #expect(writerA.log.events.isEmpty)
        #expect(writerB.log.events == ["dismiss 2"])
        #expect(queue.replies.isEmpty)
    }

    /// Das sofortige Abräumen einer Rückmeldung hängt noch bei iOS, als sich die Person abmeldet
    /// und Konto B sich anmeldet. Kommt es danach frei, darf es B's Mitteilung mit derselben
    /// Kennung nicht entfernen (Befund von Codex zu #7).
    @Test func aLateCleanupOfTheOldAccountKeepsTheNewOnesNotifications() async {
        let fetch = Gate()
        let removal = Gate()
        let first = FirstTime()
        let log = log
        source.whileWaiting = { log.append("fetch"); await fetch.wait() }
        scheduler.whileRemoving = { if first.take() { await removal.wait() } }
        source.result = .success([UpcomingReminder(id: 1, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600))])
        await scheduler.plan([planned(1, .task, 101)])
        let reminders = coordinator()
        let syncA = Task { await reminders.sync(session) }
        await fetch.untilWaiting()
        let replyA = Task { await reminders.reply(reply(.checkOff), session: session) }
        await removal.untilWaiting()

        let signOut = Task { await reminders.clear() }
        fetch.open()
        await settle()
        let accountB = Session(server: session.server, credential: "ydc_b")
        let syncB = Task { await reminders.sync(accountB) }
        // Bis B geplant hat oder lange genug, falls die Reihenfolge B warten lässt.
        for _ in 0..<200 where scheduler.planned.isEmpty { await Task.yield() }
        removal.open()
        _ = await (syncA.value, replyA.value, signOut.value, syncB.value)

        #expect(Set(scheduler.planned.keys) == ["reminder.1.task.101"])
    }

    /// Schalter aus räumt nur die Mitteilungen ab: Die Person hat schon gehandelt.
    @Test func switchingOffKeepsTheReplies() async {
        writer.dismissResult = .failure(.unreachable)
        let reminders = coordinator()
        await reminders.reply(reply(.dismiss), session: session)

        await reminders.clear(keepingReplies: true)
        writer.dismissResult = .success(())
        await reminders.sendReplies(session)

        #expect(log.events == ["dismiss 1", "dismiss 1"])
        #expect(queue.replies.isEmpty)
    }

    /// Nimmt iOS die Zeit, bleibt die Rückmeldung für das nächste Mal.
    @Test func cancellingWhileSendingKeepsTheReply() async {
        let gate = gate
        writer.whileSending = { await gate.wait() }
        let reminders = coordinator()
        let sending = Task { await reminders.reply(reply(.checkOff), session: session) }
        await gate.untilWaiting()

        reminders.cancelRunning()
        gate.open()
        await sending.value

        #expect(log.events == ["checkOff 101"])
        #expect(queue.replies == [reply(.checkOff)])
    }

    /// Ein laufender Abgleich kennt die Rückmeldung noch nicht und plant die Aufgabe wieder ein.
    /// Die Rückmeldung läuft nach ihm und räumt danach ab.
    @Test func aReplyDuringASyncClearsWhatTheSyncPlanned() async {
        let gate = gate
        let log = log
        source.whileWaiting = { log.append("fetch"); await gate.wait() }
        source.result = .success([UpcomingReminder(id: 3, origin: .task, entityID: 101, title: "Strom zahlen", firesAt: now.addingTimeInterval(3600))])
        let reminders = coordinator()
        let sync = Task { await reminders.sync(session) }
        await gate.untilWaiting()

        let answer = Task { await reminders.reply(reply(.checkOff), session: session) }
        await settle()
        gate.open()
        _ = await (sync.value, answer.value)

        #expect(scheduler.planned.isEmpty)
        #expect(log.events == ["fetch", "checkOff 101", "dismiss 1"])
    }
}

@MainActor @Suite struct UserDefaultsReplyQueueTests {
    let defaults = UserDefaults(suiteName: "test.replies.\(UUID())")!

    func reply(_ id: Int, _ kind: ReminderReply.Kind = .dismiss) -> ReminderReply {
        ReminderReply(kind: kind, reminderID: id, origin: .task, entityID: 100 + id, title: "Aufgabe \(id)", at: Date(timeIntervalSince1970: 1_793_707_200))
    }

    @Test func repliesSurviveANewQueueInOrder() {
        let first = UserDefaultsReplyQueue(defaults: defaults)
        first.append(reply(1, .checkOff))
        first.append(reply(2))

        #expect(UserDefaultsReplyQueue(defaults: defaults).replies == [reply(1, .checkOff), reply(2)])
    }

    @Test func removesOneOrAll() {
        let queue = UserDefaultsReplyQueue(defaults: defaults)
        queue.append(reply(1))
        queue.append(reply(2))

        queue.remove(reply(1))
        #expect(queue.replies == [reply(2)])

        queue.removeAll()
        #expect(queue.replies.isEmpty)
    }

    /// Etwa aus einer künftigen Version: lieber eine Rückmeldung verlieren als hängen bleiben.
    @Test func anUnreadableEntryCountsAsEmpty() {
        defaults.set(Data("kaputt".utf8), forKey: "reminders.replies")

        #expect(UserDefaultsReplyQueue(defaults: defaults).replies.isEmpty)
    }
}
