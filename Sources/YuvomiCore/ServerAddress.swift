import Foundation

/// Macht aus einer Eingabe die Basisadresse eines Servers, oder `nil`, wenn das nicht geht.
///
/// Ohne Schema gilt https. Ein ausdrücklich eingetipptes http bleibt; ATS lässt es nur im
/// lokalen Netz durch. Ein Pfad bleibt (Installation unter einem Unterpfad), der Schrägstrich
/// am Ende fällt weg. Schema und Host werden klein geschrieben, damit derselbe Server immer
/// dieselbe Adresse und damit denselben Keychain-Eintrag hat.
enum ServerAddress {
    static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        let withScheme = trimmed.range(of: "://") == nil ? "https://\(trimmed)" : trimmed
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }
}
