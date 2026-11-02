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
}
