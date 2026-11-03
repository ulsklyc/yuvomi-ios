import Foundation
import Observation

/// Port: meldet ein Gerät beim Server ab (`DELETE /auth/devices/current`).
public protocol SessionRevoking: Sendable {
    func revoke(_ session: Session) async throws(APIError)
}

/// Wer gerade angemeldet ist. Die App zeigt danach Anmeldung oder Aufgaben.
@MainActor @Observable
public final class SessionState {
    public private(set) var current: Session?

    private let store: any CredentialStore
    private let revoker: any SessionRevoking

    public init(store: any CredentialStore, revoker: any SessionRevoking) {
        self.store = store
        self.revoker = revoker
    }

    /// Beim Start: das Credential aus dem Keychain, falls eines da ist. Lässt sich der
    /// Keychain nicht lesen, gilt das wie keine Anmeldung.
    public func restore(server: URL) {
        current = (try? store.credential(for: server)).flatMap { $0 }.map { Session(server: server, credential: $0) }
    }

    /// Nach `SignInFlow`, der das Credential schon gespeichert hat.
    public func signedIn(_ session: Session) {
        current = session
    }

    /// Vergisst das Credential und meldet das Gerät danach beim Server ab. Lokal zuerst,
    /// damit Abmelden auf dem Gerät immer gelingt und das Aufräumen nach dem `await` keine
    /// Sitzung trifft, die inzwischen neu angemeldet wurde. Ein Credential, das auf dem
    /// Server übrig bleibt, kann der Nutzer in der Web-App widerrufen.
    public func signOut() async {
        guard let session = current else { return }
        forget(session)
        try? await revoker.revoke(session)
    }

    /// Für Fehler aus jedem Aufruf mit dem Credential: Ein 401 heißt, es ist widerrufen.
    /// Andere Fehler ändern an der Anmeldung nichts, ebenso späte Antworten aus einer
    /// Sitzung, die inzwischen abgemeldet oder ersetzt ist.
    public func handle(_ error: APIError, from session: Session) {
        guard error == .unauthorized, session == current else { return }
        forget(session)
    }

    private func forget(_ session: Session) {
        try? store.delete(for: session.server)
        current = nil
    }
}
