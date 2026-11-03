import Foundation

/// Ein angemeldetes Gerät: Server und Device Credential.
public struct Session: Hashable, Sendable {
    public var server: URL
    public var credential: String

    public init(server: URL, credential: String) {
        self.server = server
        self.credential = credential
    }
}

/// Was der Server auf ein richtiges Passwort antwortet.
public enum PasswordStep: Hashable, Sendable {
    /// Ohne 2FA: Das Credential ist schon ausgestellt.
    case signedIn(credential: String)
    /// Mit 2FA: weiter mit `verifySecondFactor(code:)` im selben Anmeldeversuch.
    case needsSecondFactor
}

public enum SignInError: Error, Hashable, Sendable {
    /// Benutzername oder Passwort falsch.
    case invalidCredentials
    /// 2FA- oder Wiederherstellungscode falsch, oder der Anmeldeversuch ist abgelaufen.
    case invalidCode
    /// Kopplungscode unbekannt, abgelaufen, schon benutzt, oder das Konto darf kein Gerät
    /// mehr haben. Der Server unterscheidet das absichtlich nicht (`invalid_pairing_code`).
    case invalidPairingCode
    /// Das Konto darf sich hier nicht anmelden oder bekommt kein Device Credential
    /// (deaktiviert, Personal, Gast, Display; S2).
    case notAllowed
    /// Zu viele Versuche, später erneut.
    case rateLimited
    case unreachable
    case unexpectedResponse
    /// Das Credential kam an, ließ sich aber nicht im Keychain ablegen.
    case credentialNotStored
}

/// Port für einen Anmeldeversuch an einem Server. Umgesetzt in YuvomiAPI.
///
/// Ein Exemplar gehört zu genau einem Versuch: Es hält Cookie und CSRF-Token zwischen
/// Passwort, Code und dem Ausstellen des Credentials.
public protocol SignInGateway: Sendable {
    func signIn(username: String, password: String) async throws(SignInError) -> PasswordStep
    func verifySecondFactor(code: String) async throws(SignInError) -> String
}

/// Was die Anmeldung als Nächstes braucht.
public enum SignInStep: Hashable, Sendable {
    case signedIn(Session)
    case needsSecondFactor
}

/// Führt durch Passwort und gegebenenfalls 2FA und legt das Credential ab.
public struct SignInFlow: Sendable {
    let server: URL
    let gateway: any SignInGateway
    let store: any CredentialStore

    public init(server: URL, gateway: any SignInGateway, store: any CredentialStore) {
        self.server = server
        self.gateway = gateway
        self.store = store
    }

    public func submitPassword(username: String, password: String) async throws(SignInError) -> SignInStep {
        switch try await gateway.signIn(username: username, password: password) {
        case .signedIn(let credential):
            return .signedIn(try keep(credential))
        case .needsSecondFactor:
            return .needsSecondFactor
        }
    }

    /// Zweiter Schritt nach `.needsSecondFactor`: TOTP- oder Wiederherstellungscode.
    public func submitCode(_ code: String) async throws(SignInError) -> Session {
        try keep(try await gateway.verifySecondFactor(code: code))
    }

    private func keep(_ credential: String) throws(SignInError) -> Session {
        do {
            try store.save(credential, for: server)
        } catch {
            throw .credentialNotStored
        }
        return Session(server: server, credential: credential)
    }
}
