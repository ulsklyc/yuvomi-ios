import Foundation

/// Wie man sich an einem bereiten Server anmeldet.
public enum SignInMethod: Hashable, Sendable {
    case password
    /// Passwort-Login ist abgeschaltet (SSO-only). Bis Slice 2 zeigt die App hier nur einen Hinweis.
    case pairingOnly
}

public enum ServerCheckResult: Hashable, Sendable {
    case ready(server: URL, appName: String, signIn: SignInMethod)
    /// Ein Yuvomi, aber ohne den Vertrag `client_api >= 1`. Höhere Werte gelten (Q17).
    case tooOld
    /// Antwortet, ist aber kein Yuvomi.
    case notYuvomi
    /// Keine Verbindung zum Server.
    case unreachable
    /// Die Eingabe ergibt keine http(s)-Adresse mit Host.
    case invalidAddress
}

/// Prüft eine eingegebene Serveradresse, bevor jemand ein Passwort eintippt.
public struct ServerCheck: Sendable {
    let probe: any ServerProbe

    public init(probe: any ServerProbe) {
        self.probe = probe
    }

    public func run(address: String) async -> ServerCheckResult {
        guard let server = ServerAddress.normalize(address) else { return .invalidAddress }
        let version: ServerVersion
        do {
            version = try await probe.version(at: server)
        } catch .unreachable {
            return .unreachable
        } catch {
            return .notYuvomi
        }

        switch version.product {
        case "yuvomi":
            break
        case nil where version.appName != nil:
            // Yuvomi vor v2.83.0 nennt nur `app_name`, noch kein `product`.
            return .tooOld
        default:
            return .notYuvomi
        }
        guard let clientAPI = version.clientAPI, clientAPI >= 1 else { return .tooOld }

        let options: SignInOptions
        do {
            options = try await probe.signInOptions(at: server)
        } catch .unreachable {
            return .unreachable
        } catch {
            return .notYuvomi
        }
        return .ready(
            server: server,
            appName: version.appName ?? "",
            signIn: options.passwordLoginEnabled ? .password : .pairingOnly
        )
    }
}
