import Foundation

/// Der eine Besitzer des Abgleichs und der Rückmeldungen: Abgleichen, Abräumen und
/// Rückmeldungen laufen strikt nacheinander.
///
/// - Abräumen bricht jeden laufenden oder wartenden Abgleich ab und läuft danach.
/// - Ein Abgleich nach dem Abräumen läuft nach dem Abräumen, er wird nicht verschluckt.
/// - Ein zweiter Abgleich für dieselbe Sitzung, während einer läuft, hängt sich an ihn an.
/// - Eine Rückmeldung läuft nach einem laufenden Abgleich und räumt danach ab: Dessen Abruf
///   kennt sie noch nicht und plant eine gerade abgehakte Aufgabe womöglich wieder ein.
/// - Jeder Abgleich sendet zuerst die gemerkten Rückmeldungen und holt danach ab.
///
/// Sonst könnte ein später Abruf nach dem Abmelden wieder planen, oder Abräumen entfernte,
/// was ein gleich danach eingeschalteter Abgleich gerade geplant hat.
@MainActor
public final class ReminderCoordinator {
    private enum Job: Equatable {
        case sync(Session)
        case clear
        case reply
    }

    /// Eine ältere Rückmeldung geht nicht mehr raus. Sonst könnte ein spätes Abhaken eine
    /// Aufgabe schließen, die jemand inzwischen wieder geöffnet hat (Q11).
    static let replyLifetime: TimeInterval = 24 * 3600

    private let makeSource: (Session) -> any UpcomingReminders
    private let makeWriter: (Session) -> any ReminderWriting
    private let scheduler: any NotificationScheduling
    private let queue: any ReplyQueue
    private let now: () -> Date
    private let onUnauthorized: @MainActor (Session) -> Void
    private let onNotCheckedOff: @MainActor (ReminderReply) async -> Void

    /// Der zuletzt angehängte Auftrag. Jeder neue wartet auf ihn.
    private var last: (job: Job, id: UUID, task: Task<Void, Never>)?
    /// Abgleiche, die noch laufen oder warten. Jeder trägt sich am Ende selbst aus, damit sich
    /// niemand an einen fertigen hängt. Abräumen bricht sie ab.
    private var syncs: [UUID: Task<Void, Never>] = [:]
    /// Rückmeldungen, die gerade gesendet werden. Abmelden bricht sie ab.
    private var replies: [UUID: Task<Void, Never>] = [:]
    /// Das sofortige Abräumen der Rückmeldungen, das neben der Reihe läuft. Abräumen wartet
    /// darauf: Sonst entfernte es nach dem Abmelden noch Mitteilungen eines neuen Kontos mit
    /// derselben Kennung.
    private var cleanups: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - onUnauthorized: Das Credential ist widerrufen, etwa `SessionState.handle(.unauthorized, from:)`.
    ///     Mitteilungen und gemerkte Rückmeldungen sind dann schon abgeräumt.
    ///   - onNotCheckedOff: Der Server lehnt das Abhaken ab (403), die Aufgabe ist weiter offen.
    ///     Der Auftrag wartet darauf: Läuft er im Hintergrund, hält iOS die App sonst an, bevor
    ///     der Hinweis geplant ist.
    public init(
        makeSource: @escaping (Session) -> any UpcomingReminders,
        makeWriter: @escaping (Session) -> any ReminderWriting,
        scheduler: any NotificationScheduling,
        queue: any ReplyQueue,
        now: @escaping () -> Date = { .now },
        onUnauthorized: @escaping @MainActor (Session) -> Void,
        onNotCheckedOff: @escaping @MainActor (ReminderReply) async -> Void
    ) {
        self.makeSource = makeSource
        self.makeWriter = makeWriter
        self.scheduler = scheduler
        self.queue = queue
        self.now = now
        self.onUnauthorized = onUnauthorized
        self.onNotCheckedOff = onNotCheckedOff
    }

    public func sync(_ session: Session) async {
        if let last, last.job == .sync(session), syncs[last.id] != nil, !last.task.isCancelled {
            return await last.task.value
        }
        let sync = ReminderSync(source: makeSource(session), scheduler: scheduler)
        let writer = makeWriter(session)
        await enqueue(.sync(session), in: \.syncs) { coordinator in
            guard await coordinator.send(with: writer, for: session) else { return }
            guard !Task.isCancelled else { return }
            do {
                try await sync.run(now: coordinator.now(), replies: coordinator.queue.replies)
            } catch APIError.unauthorized {
                // Im selben Auftrag abräumen: Startet iOS die App nur für den Hintergrund,
                // reagiert keine View auf das Ende der Sitzung.
                await coordinator.revoke(session)
            } catch {
                // Netzfehler versucht der nächste Abgleich.
            }
        }
    }

    /// Antippen, Wegwischen oder „Erledigt“ an einer Mitteilung. Die Rückmeldung ist sofort
    /// gemerkt, die Mitteilungen der Aufgabe sind danach vom Gerät weg, und der Server bekommt
    /// sie, sobald er erreichbar ist.
    ///
    /// - Parameters:
    ///   - session: Ohne Anmeldung gibt es niemanden, an den sie ginge. Dann räumt die App nur
    ///     auf dem Gerät auf.
    ///   - keepWithoutSession: Die Anmeldung ist nur gerade nicht lesbar, etwa vor dem ersten
    ///     Entsperren nach einem Neustart. Dann bleibt die Rückmeldung gemerkt, und der nächste
    ///     Abgleich nach der Anmeldung sendet sie.
    public func reply(_ reply: ReminderReply, session: Session?, keepWithoutSession: Bool = false) async {
        // Gemerkt, bevor irgendetwas wartet: Nimmt iOS der App gleich die Zeit, geht sie beim
        // nächsten Abgleich raus.
        if session != nil || keepWithoutSession { queue.append(reply) }
        let writer = session.map(makeWriter)
        // Sofort vom Gerät, auch wenn vor dem Auftrag ein langsamer Abgleich wartet (Q5). Ohne
        // darauf zu warten: Der Auftrag muss eingetragen sein, bevor irgendetwas wartet, sonst
        // bricht ein Abmelden ihn nicht ab, und er sendet später mit dem alten Credential.
        let cleanup = UUID()
        let immediately = Task {
            await removeNotifications(of: reply)
            cleanups[cleanup] = nil
        }
        cleanups[cleanup] = immediately
        await enqueue(.reply, in: \.replies) { coordinator in
            // Im Auftrag noch einmal: Ein Abgleich, der vor ihm lief, kannte die Rückmeldung
            // nicht und hat die Aufgabe womöglich wieder eingeplant.
            await immediately.value
            await coordinator.removeNotifications(of: reply)
            guard let session, let writer, !Task.isCancelled else { return }
            _ = await coordinator.send(with: writer, for: session)
        }
    }

    /// Nach dem Abhaken alle Mitteilungen der Aufgabe, beim Verwerfen nur diese eine.
    private func removeNotifications(of reply: ReminderReply) async {
        if reply.kind == .checkOff, reply.origin == .task {
            await ReminderSync.remove(origin: reply.origin, entityID: reply.entityID, scheduler: scheduler)
        } else {
            await scheduler.remove([ReminderSync.id(reminder: reply.reminderID, origin: reply.origin, entityID: reply.entityID)])
        }
    }

    /// Sendet nur die gemerkten Rückmeldungen, ohne abzugleichen. Für den ausgeschalteten
    /// Schalter: Die Person hat schon gehandelt.
    public func sendReplies(_ session: Session) async {
        let writer = makeWriter(session)
        await enqueue(.reply, in: \.replies) { coordinator in
            _ = await coordinator.send(with: writer, for: session)
        }
    }

    /// Für einen Hintergrund-Task, dem iOS die Zeit nimmt: laufende Abgleiche und Rückmeldungen
    /// abbrechen, ohne abzuräumen. Gemerkte Rückmeldungen bleiben.
    public func cancelRunning() {
        syncs.values.forEach { $0.cancel() }
        replies.values.forEach { $0.cancel() }
    }

    /// Räumt alle Mitteilungen von Yuvomi ab.
    ///
    /// - Parameter keepingReplies: `true` für den ausgeschalteten Schalter. Abmelden und
    ///   Widerruf vergessen auch die gemerkten Rückmeldungen, damit nichts für ein altes Konto
    ///   rausgeht.
    public func clear(keepingReplies: Bool = false) async {
        syncs.values.forEach { $0.cancel() }
        if !keepingReplies {
            replies.values.forEach { $0.cancel() }
            queue.removeAll()
        }
        let previous = last?.task
        let pendingCleanups = Array(cleanups.values)
        let scheduler = scheduler
        let task = Task {
            await previous?.value
            for cleanup in pendingCleanups { await cleanup.value }
            await ReminderSync.clear(scheduler: scheduler)
        }
        last = (.clear, UUID(), task)
        await task.value
    }

    /// Hängt einen Auftrag hinter den letzten und trägt ihn bis zu seinem Ende ein.
    private func enqueue(
        _ job: Job,
        in running: ReferenceWritableKeyPath<ReminderCoordinator, [UUID: Task<Void, Never>]>,
        _ body: @escaping @MainActor (ReminderCoordinator) async -> Void
    ) async {
        let previous = last?.task
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?[keyPath: running][id] = nil }
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await body(self)
        }
        last = (job, id, task)
        self[keyPath: running][id] = task
        await task.value
    }

    private enum Outcome {
        case sent, refused, revoked
        /// Keine Antwort: Die übrigen versucht erst der nächste Abgleich.
        case unreachable
        /// Eine unerwartete Antwort zu dieser einen: Sie bleibt, die übrigen gehen trotzdem.
        case failed
    }

    /// Sendet die gemerkten Rückmeldungen der Reihe nach. `false`, wenn das Credential
    /// widerrufen ist: Dann ist schon alles abgeräumt.
    private func send(with writer: any ReminderWriting, for session: Session) async -> Bool {
        for reply in queue.replies {
            guard !Task.isCancelled else { return true }
            guard now().timeIntervalSince(reply.at) <= Self.replyLifetime else {
                queue.remove(reply)
                continue
            }
            let outcome = await deliver(reply, with: writer)
            // Abgebrochen, etwa durch Abmelden: kein Hinweis und kein Abräumen mehr für ein
            // Konto, das womöglich schon weg ist.
            guard !Task.isCancelled else { return true }
            switch outcome {
            case .sent:
                // `deliver` hat den Eintrag schon entfernt.
                break
            case .refused:
                queue.remove(reply)
                await onNotCheckedOff(reply)
            case .failed:
                continue
            case .unreachable:
                return true
            case .revoked:
                await revoke(session)
                return false
            }
        }
        return true
    }

    /// Beim Abhaken erst der Status, dann das Verwerfen. Ist die Aufgabe abgehakt, wird die
    /// Rückmeldung zum reinen Verwerfen: Ein zweiter Versuch hakte sonst eine Aufgabe erneut
    /// ab, die jemand inzwischen wieder geöffnet hat.
    private func deliver(_ reply: ReminderReply, with writer: any ReminderWriting) async -> Outcome {
        var reply = reply
        if reply.kind == .checkOff, reply.origin == .task {
            do throws(APIError) {
                try await writer.checkOff(task: reply.entityID)
            } catch .unauthorized {
                return .revoked
            } catch .forbidden {
                // Nur lesen erlaubt: Die Aufgabe bleibt offen, also auch nicht verwerfen. Die
                // Web-App mahnt sie weiter an.
                return .refused
            } catch .notFound {
                // Gelöscht oder nicht mehr sichtbar. Still, aber die Erinnerung trotzdem verwerfen.
            } catch {
                return Self.outcome(of: error)
            }
            var dismiss = reply
            dismiss.kind = .dismiss
            queue.replace(reply, with: dismiss)
            reply = dismiss
        }
        do throws(APIError) {
            try await writer.dismiss(reminder: reply.reminderID)
        } catch .unauthorized {
            return .revoked
        } catch .forbidden, .notFound {
            // Kalender nur lesend, oder die Erinnerung ist weg: still (Q6).
        } catch {
            return Self.outcome(of: error)
        }
        if reply.kind == .dismiss { queue.remove(reply) }
        return .sent
    }

    private static func outcome(of error: APIError) -> Outcome {
        error == .unreachable ? .unreachable : .failed
    }

    private func revoke(_ session: Session) async {
        queue.removeAll()
        await ReminderSync.clear(scheduler: scheduler)
        onUnauthorized(session)
    }
}
