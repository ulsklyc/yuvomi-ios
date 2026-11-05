import YuvomiCore

/// Statuswechsel, die eine Antwort von `GET` noch nicht kennen kann.
///
/// Eine Antwort beim Laden zeigt den Stand vom Beginn der Anfrage. Ein Abhaken, das noch läuft
/// oder erst danach fertig wurde, fehlt darin. Wie ein Journal in einer Web-App: Jeder Wechsel
/// bekommt eine laufende Nummer, und das Laden legt alles über die Antwort, was nach seinem
/// Beginn kam (Codex-Review E3).
struct StatusOverlay {
    private var pending: [Int: TaskStatus] = [:]
    private var confirmed: [(seq: Int, id: Int, status: TaskStatus)] = []
    private var seq = 0

    /// Ids, deren Wechsel gerade läuft.
    var writing: Set<Int> { Set(pending.keys) }

    /// Der Stand, den ein Laden beim Start festhält.
    var mark: Int { seq }

    func isWriting(_ id: Int) -> Bool { pending[id] != nil }

    mutating func begin(_ id: Int, to target: TaskStatus) {
        pending[id] = target
    }

    /// Ende eines Wechsels: mit dem Status, den der Server bestätigt, oder `nil` bei einem Fehler.
    mutating func finish(_ id: Int, confirmed status: TaskStatus?) {
        pending[id] = nil
        guard let status else { return }
        seq += 1
        confirmed.append((seq, id, status))
    }

    /// Was über eine Antwort gehört, deren Anfrage bei `mark` begann: alles danach Bestätigte und
    /// alles noch Laufende. Älteres kennt die Antwort schon und fällt weg.
    mutating func statuses(since mark: Int) -> [Int: TaskStatus] {
        confirmed.removeAll { $0.seq <= mark }
        var result: [Int: TaskStatus] = [:]
        for entry in confirmed { result[entry.id] = entry.status }
        result.merge(pending) { _, running in running }
        return result
    }
}
