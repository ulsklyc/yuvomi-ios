import Foundation

/// Zugriff auf die Antworten aus `Fixtures/demo` (Server `v2.84.0`, siehe `Fixtures/README.md`).
/// Der Fixture-Transport, der sie durch den generierten Client schickt, folgt mit A2.
public enum Fixtures {
    /// Ordner mit den JSON-Dateien im Ressourcen-Bundle.
    public static var directory: URL {
        Bundle.module.url(forResource: "demo", withExtension: nil)!
    }

    /// Rohdaten einer Antwort, `name` ohne Endung, etwa `"version"`.
    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: "\(name).json"))
    }

    /// Rohdaten einer abgeleiteten Testvariante aus `Fixtures/derived`, `name` ohne Endung.
    /// Keine echte Server-Antwort: eine Datei aus `demo` mit gezielt geänderten Werten.
    public static func derived(_ name: String) throws -> Data {
        let folder = Bundle.module.url(forResource: "derived", withExtension: nil)!
        return try Data(contentsOf: folder.appending(path: "\(name).json"))
    }
}
