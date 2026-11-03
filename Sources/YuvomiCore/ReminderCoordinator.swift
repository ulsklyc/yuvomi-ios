import Foundation

/// Der eine Besitzer des Abgleichs: Abgleichen und Abräumen laufen strikt nacheinander.
///
/// - Abräumen bricht jeden laufenden oder wartenden Abgleich ab und läuft danach.
/// - Ein Abgleich nach dem Abräumen läuft nach dem Abräumen, er wird nicht verschluckt.
/// - Ein zweiter Abgleich für dieselbe Sitzung, während einer läuft, hängt sich an ihn an.
///
/// Sonst könnte ein später Abruf nach dem Abmelden wieder planen, oder Abräumen entfernte,
/// was ein gleich danach eingeschalteter Abgleich gerade geplant hat.
@MainActor
public final class ReminderCoordinator {
    private enum Job: Equatable {
        case sync(Session)
        case clear
    }

    private let makeSource: (Session) -> any UpcomingReminders
    private let scheduler: any NotificationScheduling
    private let now: () -> Date
    private let onUnauthorized: @MainActor (Session) -> Void

    /// Der zuletzt angehängte Auftrag. Jeder neue wartet auf ihn.
    private var last: (job: Job, id: UUID, task: Task<Void, Never>)?
    /// Abgleiche, die noch laufen oder warten. Jeder trägt sich am Ende selbst aus, damit sich
    /// niemand an einen fertigen hängt. Abräumen bricht sie ab.
    private var syncs: [UUID: Task<Void, Never>] = [:]

    /// - Parameter onUnauthorized: Das Credential ist widerrufen, etwa `SessionState.handle(.unauthorized, from:)`.
    ///   Die Mitteilungen sind dann schon abgeräumt.
    public init(
        makeSource: @escaping (Session) -> any UpcomingReminders,
        scheduler: any NotificationScheduling,
        now: @escaping () -> Date = { .now },
        onUnauthorized: @escaping @MainActor (Session) -> Void
    ) {
        self.makeSource = makeSource
        self.scheduler = scheduler
        self.now = now
        self.onUnauthorized = onUnauthorized
    }

    public func sync(_ session: Session) async {
        if let last, last.job == .sync(session), syncs[last.id] != nil, !last.task.isCancelled {
            return await last.task.value
        }
        let previous = last?.task
        let sync = ReminderSync(source: makeSource(session), scheduler: scheduler)
        let now = now
        let scheduler = scheduler
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.syncs[id] = nil }
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await sync.run(now: now())
            } catch APIError.unauthorized {
                // Im selben Auftrag abräumen: Startet iOS die App nur für den Hintergrund,
                // reagiert keine View auf das Ende der Sitzung.
                await ReminderSync.clear(scheduler: scheduler)
                self?.onUnauthorized(session)
            } catch {
                // Netzfehler versucht der nächste Abgleich.
            }
        }
        last = (.sync(session), id, task)
        syncs[id] = task
        await task.value
    }

    /// Für einen Hintergrund-Task, dem iOS die Zeit nimmt: laufende Abgleiche abbrechen,
    /// ohne abzuräumen.
    public func cancelSyncs() {
        syncs.values.forEach { $0.cancel() }
    }

    public func clear() async {
        syncs.values.forEach { $0.cancel() }
        let previous = last?.task
        let scheduler = scheduler
        let task = Task {
            await previous?.value
            await ReminderSync.clear(scheduler: scheduler)
        }
        last = (.clear, UUID(), task)
        await task.value
    }
}
