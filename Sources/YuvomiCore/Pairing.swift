import Foundation

/// Ein Kopplungslink `yuvomi://pair?server=<origin>&code=<code>` aus der Web-App, per QR
/// oder direkt auf demselben Gerät geöffnet (S3).
///
/// Angenommen wird nur, was der Server so baut: genau ein `server`, und zwar eine blanke
/// http(s)-Origin ohne Pfad, und genau ein nicht leerer `code`. Länge und Alphabet des Codes
/// prüft der Server, damit eine Änderung dort die App nicht bricht.
public struct PairingLink: Hashable, Sendable {
    public var server: URL
    public var code: String

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "yuvomi", url.host()?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let serverValue = Self.single("server", in: items),
              let server = ServerAddress.normalize(serverValue), server.path().isEmpty,
              let codeValue = Self.single("code", in: items)
        else { return nil }
        let code = PairingCode.normalize(codeValue)
        guard !code.isEmpty else { return nil }
        self.server = server
        self.code = code
    }

    private static func single(_ name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        return matches.count == 1 ? matches[0].value : nil
    }
}

/// Die Schreibweise, in der der Server einen Kopplungscode vergleicht
/// (`normalizePairingCode()`): ohne Leerzeichen und Bindestriche, in Großbuchstaben.
public enum PairingCode {
    public static func normalize(_ input: String) -> String {
        input.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
    }
}

/// Port zum Einlösen eines Kopplungscodes. Umgesetzt in YuvomiAPI.
///
/// Die Anfrage geht ohne `Authorization`: Ein gültiges Credential lehnt der Server dort ab.
public protocol PairingRedeeming: Sendable {
    func redeem(code: String) async throws(SignInError) -> String
}

/// Tauscht einen Kopplungscode gegen ein Credential und legt es ab.
public struct PairingFlow: Sendable {
    let server: URL
    let redeemer: any PairingRedeeming
    let store: any CredentialStore

    public init(server: URL, redeemer: any PairingRedeeming, store: any CredentialStore) {
        self.server = server
        self.redeemer = redeemer
        self.store = store
    }

    public func redeem(code: String) async throws(SignInError) -> Session {
        let credential = try await redeemer.redeem(code: PairingCode.normalize(code))
        do {
            try store.save(credential, for: server)
        } catch {
            throw .credentialNotStored
        }
        return Session(server: server, credential: credential)
    }
}

/// Was mit einem Link passiert, den iOS der App zustellt.
///
/// Bei bestehender Anmeldung wird nicht gekoppelt: Ein fremder Link soll keine Sitzung
/// ersetzen. Der Code verfällt nach fünf Minuten von selbst.
public enum IncomingLink: Hashable, Sendable {
    /// Weiter an die Anmeldung, die den Link prüft und den Server bestätigen lässt.
    case pairing(URL)
    /// Hinweis zeigen, dass zum Koppeln erst abgemeldet werden muss.
    case refusedWhileSignedIn

    public init(url: URL, current: Session?) {
        self = current == nil ? .pairing(url) : .refusedWhileSignedIn
    }
}
