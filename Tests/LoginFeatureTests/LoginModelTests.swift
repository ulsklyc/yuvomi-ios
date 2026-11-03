import Foundation
import Testing
import YuvomiCore
@testable import LoginFeature

/// Port-Fake: was `/version` und `/auth/oidc/config` antworten.
struct FakeProbe: ServerProbe {
    var version: Result<ServerVersion, ServerProbeError> = .success(ServerVersion(product: "yuvomi", clientAPI: 1, appName: "Familie Muster"))
    var options: Result<SignInOptions, ServerProbeError> = .success(SignInOptions(passwordLoginEnabled: true))

    func version(at server: URL) async throws(ServerProbeError) -> ServerVersion { try version.get() }
    func signInOptions(at server: URL) async throws(ServerProbeError) -> SignInOptions { try options.get() }
}

/// Port-Fake: was der Server auf Passwort und Code antwortet.
final class FakeGateway: SignInGateway, @unchecked Sendable {
    var passwordResult: Result<PasswordStep, SignInError> = .success(.signedIn(credential: "ydc_new"))
    var codeResult: Result<String, SignInError> = .success("ydc_after_2fa")
    /// Läuft, während die Anmeldung auf den Server wartet.
    var whileWaiting: (@MainActor () async -> Void)?
    private(set) var signIns = 0

    func signIn(username: String, password: String) async throws(SignInError) -> PasswordStep {
        signIns += 1
        let waiting = whileWaiting
        whileWaiting = nil
        await waiting?()
        return try passwordResult.get()
    }
    func verifySecondFactor(code: String) async throws(SignInError) -> String { try codeResult.get() }
}

/// Merkt sich, welche Sitzung an die App ging.
@MainActor final class SignedIn {
    var sessions: [Session] = []
}

@MainActor @Suite struct LoginModelTests {
    let server = URL(string: "https://yuvomi.example.com")!

    func model(probe: FakeProbe = FakeProbe()) -> LoginModel {
        LoginModel(check: ServerCheck(probe: probe), makeFlow: { _ in fatalError("kein Anmeldeversuch erwartet") }, onSignedIn: { _ in })
    }

    @Test func checkedAddressLeadsToThePasswordForm() async {
        let login = model()
        login.address = "yuvomi.example.com"

        await login.submitAddress()

        #expect(login.step == .password(server: server, appName: "Familie Muster"))
        #expect(login.problem == nil)
    }

    @Test func serverWithoutPasswordLoginShowsTheSSOHint() async {
        let login = model(probe: FakeProbe(options: .success(SignInOptions(passwordLoginEnabled: false))))
        login.address = "yuvomi.example.com"

        await login.submitAddress()

        #expect(login.step == .ssoOnly(appName: "Familie Muster"))
    }

    @Test(arguments: [
        ("", FakeProbe(), LoginModel.Problem.invalidAddress),
        ("yuvomi.example.com", FakeProbe(version: .failure(.unreachable)), .unreachable),
        ("yuvomi.example.com", FakeProbe(version: .failure(.unexpectedResponse)), .notYuvomi),
        ("yuvomi.example.com", FakeProbe(version: .success(ServerVersion(product: "yuvomi", clientAPI: 0, appName: "x"))), .tooOld),
    ])
    func failedCheckStaysOnTheAddressWithAProblem(address: String, probe: FakeProbe, expected: LoginModel.Problem) async {
        let login = model(probe: probe)
        login.address = address

        await login.submitAddress()

        #expect(login.step == .address)
        #expect(login.problem == expected)
        #expect(!login.isWorking)
    }

    /// Ein Modell, das schon beim Passwort steht.
    func passwordStep(gateway: FakeGateway, signedIn: SignedIn) async -> LoginModel {
        let login = LoginModel(
            check: ServerCheck(probe: FakeProbe()),
            makeFlow: { SignInFlow(server: $0, gateway: gateway, store: InMemoryCredentialStore()) },
            onSignedIn: { signedIn.sessions.append($0) }
        )
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.username = "alex"
        login.password = "demo1234"
        return login
    }

    @Test func passwordSignsIn() async {
        let signedIn = SignedIn()
        let login = await passwordStep(gateway: FakeGateway(), signedIn: signedIn)

        await login.submitPassword()

        #expect(signedIn.sessions == [Session(server: server, credential: "ydc_new")])
    }

    @Test func secondFactorAsksForTheCodeThenSignsIn() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        let signedIn = SignedIn()
        let login = await passwordStep(gateway: gateway, signedIn: signedIn)

        await login.submitPassword()
        #expect(login.step == .code)
        #expect(signedIn.sessions.isEmpty)

        login.code = "123456"
        await login.submitCode()

        #expect(signedIn.sessions == [Session(server: server, credential: "ydc_after_2fa")])
    }

    @Test func wrongPasswordStaysWithAProblemAndClearsThePassword() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .failure(.invalidCredentials)
        let signedIn = SignedIn()
        let login = await passwordStep(gateway: gateway, signedIn: signedIn)

        await login.submitPassword()

        #expect(login.step == .password(server: server, appName: "Familie Muster"))
        #expect(login.problem == .invalidCredentials)
        #expect(login.password.isEmpty)
        #expect(login.username == "alex")
        #expect(signedIn.sessions.isEmpty)
    }

    @Test func wrongCodeStaysOnTheCode() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        gateway.codeResult = .failure(.invalidCode)
        let login = await passwordStep(gateway: gateway, signedIn: SignedIn())
        await login.submitPassword()
        login.code = "000000"

        await login.submitCode()

        #expect(login.step == .code)
        #expect(login.problem == .invalidCode)
        #expect(login.code.isEmpty)
    }

    @Test func backFromPasswordReturnsToTheAddress() async {
        let login = await passwordStep(gateway: FakeGateway(), signedIn: SignedIn())
        login.back()
        #expect(login.step == .address)
        #expect(login.password.isEmpty)
        #expect(login.address == "yuvomi.example.com")
    }

    /// Zurück während der Anfrage zählt nicht: Die Antwort des Servers bestimmt den Schritt.
    @Test func backIsIgnoredWhileSigningIn() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        let login = await passwordStep(gateway: gateway, signedIn: SignedIn())
        gateway.whileWaiting = { login.back() }

        await login.submitPassword()

        #expect(login.step == .code)
        login.back()
        #expect(login.step == .password(server: server, appName: "Familie Muster"))
    }

    /// Zweimal „Los“ auf der Tastatur schickt nur eine Anfrage.
    @Test func secondSubmitWhileSigningInIsIgnored() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        let login = await passwordStep(gateway: gateway, signedIn: SignedIn())
        gateway.whileWaiting = { await login.submitPassword() }

        await login.submitPassword()

        #expect(gateway.signIns == 1)
        login.back()
        #expect(login.step == .password(server: server, appName: "Familie Muster"))
    }
}
