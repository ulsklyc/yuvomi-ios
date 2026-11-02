import Foundation

/// Was ein Server vor der Anmeldung über sich sagt (`GET /version`).
///
/// Alle Felder sind optional: Ein alter Yuvomi kennt `product` und `client_api` nicht,
/// ein fremder Server keines davon. Was daraus folgt, entscheidet `ServerCheck`.
public struct ServerVersion: Hashable, Sendable {
    public var product: String?
    public var clientAPI: Int?
    public var appName: String?

    public init(product: String?, clientAPI: Int?, appName: String?) {
        self.product = product
        self.clientAPI = clientAPI
        self.appName = appName
    }
}

/// Welche Anmeldewege der Server anbietet (`GET /auth/oidc/config`).
public struct SignInOptions: Hashable, Sendable {
    public var passwordLoginEnabled: Bool

    public init(passwordLoginEnabled: Bool) {
        self.passwordLoginEnabled = passwordLoginEnabled
    }
}

public enum ServerProbeError: Error, Hashable, Sendable {
    /// Keine Verbindung: falscher Host, kein Netz, Zertifikat, Zeitüberschreitung.
    case unreachable
    /// Eine Antwort kam, aber keine, die ein Yuvomi so gibt (HTML, anderer Status, kein JSON).
    case unexpectedResponse
}

/// Port für die anonymen Abfragen vor der Anmeldung. Umgesetzt in YuvomiAPI.
public protocol ServerProbe: Sendable {
    func version(at server: URL) async throws(ServerProbeError) -> ServerVersion
    func signInOptions(at server: URL) async throws(ServerProbeError) -> SignInOptions
}
