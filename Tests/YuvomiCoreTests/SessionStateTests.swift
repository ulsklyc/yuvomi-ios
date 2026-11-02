import Foundation
import Testing
import YuvomiCore

/// Port-Fake: was der Server beim Abmelden des Geräts antwortet.
final class FakeRevoker: SessionRevoking, @unchecked Sendable {
    var result: Result<Void, APIError> = .success(())
    /// Läuft, während der Widerruf auf den Server wartet.
    var whileWaiting: (@Sendable () async -> Void)?
    private(set) var revoked: [Session] = []

    func revoke(_ session: Session) async throws(APIError) {
        revoked.append(session)
        await whileWaiting?()
        try result.get()
    }
}

@MainActor @Suite struct SessionStateTests {
    let server = URL(string: "https://yuvomi.example.com")!
    let store = InMemoryCredentialStore()

    @Test func restoresTheStoredCredentialAtLaunch() throws {
        try store.save("ydc_stored", for: server)
        let state = SessionState(store: store, revoker: FakeRevoker())

        state.restore(server: server)

        #expect(state.current == Session(server: server, credential: "ydc_stored"))
    }

    @Test func withoutStoredCredentialNobodyIsSignedIn() {
        let state = SessionState(store: store, revoker: FakeRevoker())
        state.restore(server: server)
        #expect(state.current == nil)
    }

    @Test(arguments: [Result<Void, APIError>.success(()), .failure(.unreachable), .failure(.unauthorized), .failure(.unexpectedResponse)])
    func signOutAlwaysForgetsTheCredential(serverAnswer: Result<Void, APIError>) async throws {
        let session = Session(server: server, credential: "ydc_stored")
        try store.save("ydc_stored", for: server)
        let revoker = FakeRevoker()
        revoker.result = serverAnswer
        let state = SessionState(store: store, revoker: revoker)
        state.signedIn(session)

        await state.signOut()

        #expect(revoker.revoked == [session])
        #expect(state.current == nil)
        #expect(try store.credential(for: server) == nil)
    }

    /// Ein widerrufenes Credential führt zurück zur Anmeldung, ohne den Server noch einmal zu fragen.
    @Test func unauthorizedAnswerSignsOutLocally() throws {
        try store.save("ydc_revoked", for: server)
        let revoker = FakeRevoker()
        let state = SessionState(store: store, revoker: revoker)
        state.restore(server: server)

        state.handle(.unauthorized)

        #expect(state.current == nil)
        #expect(try store.credential(for: server) == nil)
        #expect(revoker.revoked.isEmpty)
    }

    @Test(arguments: [APIError.unreachable, .unexpectedResponse])
    func otherFailuresKeepTheSession(error: APIError) throws {
        try store.save("ydc_stored", for: server)
        let state = SessionState(store: store, revoker: FakeRevoker())
        state.restore(server: server)

        state.handle(error)

        #expect(state.current == Session(server: server, credential: "ydc_stored"))
        #expect(try store.credential(for: server) == "ydc_stored")
    }

    /// Wer sich während eines langsamen Widerrufs neu anmeldet, bleibt angemeldet:
    /// Das Aufräumen der alten Sitzung darf die neue nicht treffen.
    @Test func newSignInDuringSlowSignOutSurvives() async throws {
        let old = Session(server: server, credential: "ydc_old")
        let new = Session(server: server, credential: "ydc_new")
        try store.save("ydc_old", for: server)
        let revoker = FakeRevoker()
        let state = SessionState(store: store, revoker: revoker)
        state.signedIn(old)
        let store = store
        revoker.whileWaiting = {
            await MainActor.run {
                try? store.save("ydc_new", for: new.server)
                state.signedIn(new)
            }
        }

        await state.signOut()

        #expect(state.current == new)
        #expect(try store.credential(for: server) == "ydc_new")
    }
}
