/// Ein Feld einer Eingabe, bei dem der Server zwischen "weglassen" und `null` unterscheidet.
///
/// Der Generator kennt nur Optionals und lässt `nil` weg. Ein Termin-Ende ließe sich damit
/// nie entfernen (S5, docs/plans/phase-0-server.md). Vergleich JS: `undefined` gegen `null`.
enum Patch<Value: Codable & Hashable & Sendable>: Hashable, Sendable {
    /// Wird nicht gesendet, der Server lässt den gespeicherten Wert stehen.
    case unset
    /// Wird als `null` gesendet und leert das Feld.
    case clear
    /// Wird mit diesem Wert gesendet.
    case set(Value)
}

extension KeyedEncodingContainer {
    mutating func encode<Value>(_ patch: Patch<Value>, forKey key: Key) throws {
        switch patch {
        case .unset: break
        case .clear: try encodeNil(forKey: key)
        case .set(let value): try encode(value, forKey: key)
        }
    }
}

extension KeyedDecodingContainer {
    func decode<Value>(_: Patch<Value>.Type, forKey key: Key) throws -> Patch<Value> {
        guard contains(key) else { return .unset }
        if try decodeNil(forKey: key) { return .clear }
        return .set(try decode(Value.self, forKey: key))
    }
}
