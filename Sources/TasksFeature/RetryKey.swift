import Foundation

/// Der `Idempotency-Key` fürs Anlegen (Q14), für Formular und Unteraufgaben gleich.
///
/// Dieselbe Anfrage schickt denselben Schlüssel wieder, so legt der Server nicht doppelt an.
/// Eine andere braucht einen neuen: Mit dem alten antwortete der Server 24 Stunden lang 409.
/// Wie ein kleiner Cache in JS: `last?.input === input ? last.key : makeKey()`.
struct RetryKey<Input: Equatable> {
    private var last: (input: Input, key: String)?
    private let makeKey: () -> String

    init(makeKey: @escaping () -> String = { UUID().uuidString }) {
        self.makeKey = makeKey
    }

    /// Der Schlüssel für diesen Versuch.
    mutating func key(for input: Input) -> String {
        if let last, last.input == input { return last.key }
        let key = makeKey()
        last = (input, key)
        return key
    }

    /// Nach dem Erfolg: Der nächste Versuch ist eine neue Anfrage.
    mutating func reset() {
        last = nil
    }
}
