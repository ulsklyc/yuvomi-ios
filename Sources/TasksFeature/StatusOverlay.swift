import Observation
import YuvomiCore

/// Statuswechsel, die eine Antwort von `GET` noch nicht kennen kann.
///
/// Eine Antwort beim Laden zeigt den Stand vom Beginn der Anfrage. Ein Abhaken, das noch läuft
/// oder erst danach fertig wurde, fehlt darin. Wie ein Journal in einer Web-App: Jeder Wechsel
/// bekommt eine laufende Nummer, und das Laden legt alles über die Antwort, was nach seinem
/// Beginn kam (Codex-Review E3).
///
/// Eine je Liste, geteilt mit jedem Detail: So sieht das Detail ein Abhaken aus der Liste,
/// und keines der beiden schreibt dieselbe Aufgabe ein zweites Mal dazwischen. Wie ein Store,
/// den zwei Komponenten abonnieren.
@MainActor @Observable
final class StatusOverlay {
    private var pending: [Int: TaskStatus] = [:]
    /// Aufgaben, deren Ankreuzen gerade läuft, aus welchem Detail auch immer. Jede Antwort ist die
    /// ganze Beschreibung: Zwei auf einmal überschrieben sich (Issue #23).
    private var ticking: Set<Int> = []
    @ObservationIgnored private var confirmed: [(seq: Int, id: Int, status: TaskStatus)] = []
    /// Aufgaben und Unteraufgaben, die beim Schreiben mit 404 antworteten, mit derselben Zählung.
    /// Ein Laden, das davor begann, kennt sie noch (Issue #24).
    @ObservationIgnored private var removed: [(seq: Int, id: Int)] = []
    @ObservationIgnored private var seq = 0

    /// So viele bestätigte Wechsel bleiben im Journal. Ein Laden, während dessen mehr Wechsel
    /// fertig werden, ist nicht zu erwarten.
    private static let kept = 64

    /// Ids, deren Wechsel gerade läuft. Ihr Kreis ist so lange gesperrt (Q13).
    var writing: Set<Int> { Set(pending.keys) }

    /// Der Stand, den ein Laden beim Start festhält.
    var mark: Int { seq }

    func isWriting(_ id: Int) -> Bool { pending[id] != nil }

    func isTicking(_ id: Int) -> Bool { ticking.contains(id) }

    /// Beginnt ein Ankreuzen der Aufgabe. `false`, wenn schon eines läuft.
    func beginTick(_ id: Int) -> Bool {
        ticking.insert(id).inserted
    }

    func finishTick(_ id: Int) {
        ticking.remove(id)
    }

    func begin(_ id: Int, to target: TaskStatus) {
        pending[id] = target
    }

    /// Ende eines Wechsels: mit dem Status, den der Server bestätigt, oder `nil` bei einem Fehler.
    func finish(_ id: Int, confirmed status: TaskStatus?) {
        pending[id] = nil
        guard let status else { return }
        seq += 1
        confirmed.append((seq, id, status))
        if confirmed.count > Self.kept { confirmed.removeFirst(confirmed.count - Self.kept) }
    }

    /// Die Aufgabe oder Unteraufgabe gibt es nicht mehr (404).
    func markGone(_ id: Int) {
        seq += 1
        removed.append((seq, id))
        if removed.count > Self.kept { removed.removeFirst(removed.count - Self.kept) }
    }

    /// Was eine Antwort, deren Anfrage bei `mark` begann, noch zeigt, obwohl es weg ist.
    func gone(since mark: Int) -> Set<Int> {
        Set(removed.lazy.filter { $0.seq > mark }.map(\.id))
    }

    /// Was über eine Antwort gehört, deren Anfrage bei `mark` begann: alles danach Bestätigte und
    /// alles noch Laufende. Älteres kennt die Antwort schon.
    func statuses(since mark: Int) -> [Int: TaskStatus] {
        var result: [Int: TaskStatus] = [:]
        for entry in confirmed where entry.seq > mark { result[entry.id] = entry.status }
        result.merge(pending) { _, running in running }
        return result
    }
}
