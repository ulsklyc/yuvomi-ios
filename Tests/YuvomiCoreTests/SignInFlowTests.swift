import Foundation
import Testing
import YuvomiCore

/// Port-Fake: Was der Server auf Passwort und Code antworten würde.
final class FakeGateway: SignInGateway, @unchecked Sendable {
    var passwordResult: Result<PasswordStep, SignInError> = .success(.signedIn(credential: "ydc_new"))
    var codeResult: Result<String, SignInError> = .success("ydc_after_2fa")

    func signIn(username: String, password: String) async throws(SignInError) -> PasswordStep {
        try passwordResult.get()
    }

    func verifySecondFactor(code: String) async throws(SignInError) -> String {
        try codeResult.get()
    }
}

@Suite struct SignInFlowTests {
    let server = URL(string: "https://yuvomi.example.com")!
    let store = InMemoryCredentialStore()

    @Test func passwordWithoutSecondFactorStoresTheCredential() async throws {
        let flow = SignInFlow(server: server, gateway: FakeGateway(), store: store)

        let step = try await flow.submitPassword(username: "alex", password: "demo1234")

        #expect(step == .signedIn(Session(server: server, credential: "ydc_new")))
        #expect(try store.credential(for: server) == "ydc_new")
    }

    @Test func secondFactorCompletesTheSignIn() async throws {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        let flow = SignInFlow(server: server, gateway: gateway, store: store)

        #expect(try await flow.submitPassword(username: "alex", password: "demo1234") == .needsSecondFactor)
        #expect(try store.credential(for: server) == nil)

        let session = try await flow.submitCode("123456")
        #expect(session == Session(server: server, credential: "ydc_after_2fa"))
        #expect(try store.credential(for: server) == "ydc_after_2fa")
    }

    @Test func failuresStoreNothing() async throws {
        let gateway = FakeGateway()
        gateway.passwordResult = .failure(.invalidCredentials)
        gateway.codeResult = .failure(.invalidCode)
        let flow = SignInFlow(server: server, gateway: gateway, store: store)

        await #expect(throws: SignInError.invalidCredentials) { try await flow.submitPassword(username: "alex", password: "falsch") }
        await #expect(throws: SignInError.invalidCode) { try await flow.submitCode("000000") }
        #expect(try store.credential(for: server) == nil)
    }

    @Test func keychainFailureIsReported() async {
        let flow = SignInFlow(server: server, gateway: FakeGateway(), store: BrokenStore())
        await #expect(throws: SignInError.credentialNotStored) { try await flow.submitPassword(username: "alex", password: "demo1234") }
    }
}

struct BrokenStore: CredentialStore {
    struct Failure: Error {}
    func credential(for server: URL) throws -> String? { throw Failure() }
    func save(_ credential: String, for server: URL) throws { throw Failure() }
    func delete(for server: URL) throws { throw Failure() }
}
