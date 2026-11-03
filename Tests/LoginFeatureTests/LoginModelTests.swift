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

/// Port-Fake: was der Server auf einen Kopplungscode antwortet.
final class FakeRedeemer: PairingRedeeming, @unchecked Sendable {
    var result: Result<String, SignInError> = .success("ydc_paired")
    private(set) var codes: [String] = []

    func redeem(code: String) async throws(SignInError) -> String {
        codes.append(code)
        return try result.get()
    }
}

/// Merkt sich, welche Sitzung an die App ging.
@MainActor final class SignedIn {
    var sessions: [Session] = []
}

@MainActor @Suite struct LoginModelTests {
    let server = URL(string: "https://yuvomi.example.com")!

    func model(probe: FakeProbe = FakeProbe()) -> LoginModel {
        LoginModel(
            check: ServerCheck(probe: probe),
            makeFlow: { _ in fatalError("kein Anmeldeversuch erwartet") },
            makePairing: { _ in fatalError("keine Kopplung erwartet") },
            onSignedIn: { _ in }
        )
    }

    @Test func checkedAddressLeadsToThePasswordForm() async {
        let login = model()
        login.address = "yuvomi.example.com"

        await login.submitAddress()

        #expect(login.step == .password(server: server, appName: "Familie Muster"))
        #expect(login.problem == nil)
    }

    @Test func serverWithoutPasswordLoginAsksForAPairingCode() async {
        let login = model(probe: FakeProbe(options: .success(SignInOptions(passwordLoginEnabled: false))))
        login.address = "yuvomi.example.com"

        await login.submitAddress()

        #expect(login.step == .pairing(server: server, appName: "Familie Muster"))
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
            makePairing: { _ in fatalError("keine Kopplung erwartet") },
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

    /// Leere Felder gehen nicht an den Server: Er antwortet darauf mit 400, und die App
    /// zeigte „Der Server hat unerwartet geantwortet“ (gesehen im Simulator, A6).
    @Test(arguments: [("", "demo1234"), ("  ", "demo1234"), ("alex", "")])
    func emptyFieldsAreNotSent(username: String, password: String) async {
        let gateway = FakeGateway()
        let login = await passwordStep(gateway: gateway, signedIn: SignedIn())
        login.username = username
        login.password = password

        #expect(!login.canSubmitPassword)
        await login.submitPassword()

        #expect(gateway.signIns == 0)
        #expect(login.problem == nil)
    }

    @Test func emptyCodeIsNotSent() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        gateway.codeResult = .failure(.invalidCode)
        let login = await passwordStep(gateway: gateway, signedIn: SignedIn())
        await login.submitPassword()
        login.code = " "

        #expect(!login.canSubmitCode)
        await login.submitCode()

        #expect(login.problem == nil)
    }

    // MARK: Kopplung

    /// Ein Modell mit Gateway und Redeemer, das noch bei der Adresse steht.
    func pairingModel(
        probe: FakeProbe = FakeProbe(),
        gateway: FakeGateway = FakeGateway(),
        redeemer: FakeRedeemer,
        signedIn: SignedIn
    ) -> LoginModel {
        LoginModel(
            check: ServerCheck(probe: probe),
            makeFlow: { SignInFlow(server: $0, gateway: gateway, store: InMemoryCredentialStore()) },
            makePairing: { PairingFlow(server: $0, redeemer: redeemer, store: InMemoryCredentialStore()) },
            onSignedIn: { signedIn.sessions.append($0) }
        )
    }

    static let ssoOnly = FakeProbe(options: .success(SignInOptions(passwordLoginEnabled: false)))

    @Test func typedPairingCodeSignsIn() async {
        let redeemer = FakeRedeemer()
        let signedIn = SignedIn()
        let login = pairingModel(probe: Self.ssoOnly, redeemer: redeemer, signedIn: signedIn)
        login.address = "yuvomi.example.com"
        await login.submitAddress()

        login.pairingCode = "acde-34fg hj"
        await login.submitPairingCode()

        #expect(redeemer.codes == ["ACDE34FGHJ"])
        #expect(signedIn.sessions == [Session(server: server, credential: "ydc_paired")])
    }

    /// Ein ungültiger Code ist verbraucht oder falsch: Feld leeren. Bei Netzfehlern und
    /// zu vielen Versuchen bleibt er stehen, damit ein zweiter Versuch ohne neuen Code geht.
    @Test(arguments: [
        (SignInError.invalidPairingCode, LoginModel.Problem.invalidPairingCode, ""),
        (.rateLimited, .rateLimited, "ACDE34FGHJ"),
        (.unreachable, .unreachable, "ACDE34FGHJ"),
    ])
    func refusedPairingCodeStaysOnTheCode(error: SignInError, expected: LoginModel.Problem, remaining: String) async {
        let redeemer = FakeRedeemer()
        redeemer.result = .failure(error)
        let signedIn = SignedIn()
        let login = pairingModel(probe: Self.ssoOnly, redeemer: redeemer, signedIn: signedIn)
        login.address = "yuvomi.example.com"
        await login.submitAddress()

        login.pairingCode = "ACDE34FGHJ"
        await login.submitPairingCode()

        #expect(login.step == .pairing(server: server, appName: "Familie Muster"))
        #expect(login.problem == expected)
        #expect(login.pairingCode == remaining)
        #expect(signedIn.sessions.isEmpty)
    }

    @Test func passwordStepOffersThePairingCodeAndBackReturnsToIt() async {
        let login = pairingModel(redeemer: FakeRedeemer(), signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()

        login.startPairing()
        #expect(login.step == .pairing(server: server, appName: "Familie Muster"))

        login.pairingCode = "ACDE"
        login.back()
        #expect(login.step == .password(server: server, appName: "Familie Muster"))
        #expect(login.pairingCode == "")
    }

    @Test func backFromPairingWithoutPasswordLoginReturnsToTheAddress() async {
        let login = pairingModel(probe: Self.ssoOnly, redeemer: FakeRedeemer(), signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()

        login.back()

        #expect(login.step == .address)
    }

    @Test(arguments: ["", "  ", " - "])
    func emptyPairingCodeIsNotSent(input: String) async {
        let redeemer = FakeRedeemer()
        let login = pairingModel(probe: Self.ssoOnly, redeemer: redeemer, signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.pairingCode = input

        #expect(!login.canSubmitPairingCode)
        await login.submitPairingCode()

        #expect(redeemer.codes.isEmpty)
    }

    // MARK: Link und QR

    let link = URL(string: "yuvomi://pair?server=https%3A%2F%2Fyuvomi.example.com&code=ACDE34FGHJ")!

    /// Erst nach der Bestätigung geht der Code an den Server: `yuvomi://` ist nicht exklusiv,
    /// und jede Seite kann einen Link mit fremdem Server bauen (S3).
    @Test func linkAsksToConfirmTheServerBeforeRedeeming() async {
        let redeemer = FakeRedeemer()
        let signedIn = SignedIn()
        let login = pairingModel(redeemer: redeemer, signedIn: signedIn)

        await login.openPairingLink(link)

        #expect(login.step == .confirmPairing(server: server, appName: "Familie Muster", code: "ACDE34FGHJ"))
        #expect(redeemer.codes.isEmpty)

        await login.confirmPairing()

        #expect(redeemer.codes == ["ACDE34FGHJ"])
        #expect(signedIn.sessions == [Session(server: server, credential: "ydc_paired")])
    }

    @Test func invalidLinkStaysOnTheAddressWithAProblem() async {
        let login = pairingModel(redeemer: FakeRedeemer(), signedIn: SignedIn())

        await login.openPairingLink(URL(string: "yuvomi://pair?code=ACDE34FGHJ")!)

        #expect(login.step == .address)
        #expect(login.problem == .invalidPairingLink)
    }

    /// Der Server aus dem Link wird geprüft wie eine eingetippte Adresse und steht danach
    /// im Feld, damit die Meldung zu sehen ist, auf welchen Server sie sich bezieht.
    @Test func linkToAServerThatFailsTheCheckShowsTheSameProblem() async {
        let login = pairingModel(
            probe: FakeProbe(version: .success(ServerVersion(product: "yuvomi", clientAPI: 0, appName: "x"))),
            redeemer: FakeRedeemer(),
            signedIn: SignedIn()
        )

        await login.openPairingLink(link)

        #expect(login.step == .address)
        #expect(login.problem == .tooOld)
        #expect(login.address == "https://yuvomi.example.com")
    }

    /// Q9: Egal woher der Code kam, nach `invalid_pairing_code` geht es zur Code-Eingabe
    /// für denselben Server. Von dort geht ein neuer Scan oder das Abtippen.
    @Test func refusedLinkCodeLeadsToTheCodeEntry() async {
        let redeemer = FakeRedeemer()
        redeemer.result = .failure(.invalidPairingCode)
        let login = pairingModel(redeemer: redeemer, signedIn: SignedIn())
        await login.openPairingLink(link)

        await login.confirmPairing()

        #expect(login.step == .pairing(server: server, appName: "Familie Muster"))
        #expect(login.problem == .invalidPairingCode)
        #expect(login.pairingCode == "")
    }

    @Test func otherFailuresStayOnTheConfirmation() async {
        let redeemer = FakeRedeemer()
        redeemer.result = .failure(.rateLimited)
        let login = pairingModel(redeemer: redeemer, signedIn: SignedIn())
        await login.openPairingLink(link)

        await login.confirmPairing()

        #expect(login.step == .confirmPairing(server: server, appName: "Familie Muster", code: "ACDE34FGHJ"))
        #expect(login.problem == .rateLimited)
    }

    @Test func cancellingTheConfirmationReturnsToTheAddress() async {
        let redeemer = FakeRedeemer()
        let login = pairingModel(redeemer: redeemer, signedIn: SignedIn())
        await login.openPairingLink(link)

        login.back()

        #expect(login.step == .address)
        #expect(login.address == "https://yuvomi.example.com")
        #expect(redeemer.codes.isEmpty)
    }

    /// Q8: Der Link gewinnt. Der offene 2FA-Versuch ist danach weg, „Abbrechen“ in der
    /// Bestätigung führt zur Adresse und nicht zurück zum Code.
    @Test func linkDuringTheSecondFactorReplacesTheSignIn() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        let login = pairingModel(gateway: gateway, redeemer: FakeRedeemer(), signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.username = "alex"
        login.password = "demo1234"
        await login.submitPassword()
        #expect(login.step == .code)

        await login.openPairingLink(link)
        #expect(login.step == .confirmPairing(server: server, appName: "Familie Muster", code: "ACDE34FGHJ"))

        login.back()
        #expect(login.step == .address)
        login.code = "123456"
        await login.submitCode()
        #expect(login.step == .address)
    }

    /// Läuft gerade eine Anfrage, wird der Link danach angenommen.
    @Test func linkWhileSigningInIsTakenAfterTheAnswer() async {
        let gateway = FakeGateway()
        gateway.passwordResult = .success(.needsSecondFactor)
        let login = pairingModel(gateway: gateway, redeemer: FakeRedeemer(), signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.username = "alex"
        login.password = "demo1234"
        gateway.whileWaiting = { await login.openPairingLink(self.link) }

        await login.submitPassword()

        #expect(login.step == .confirmPairing(server: server, appName: "Familie Muster", code: "ACDE34FGHJ"))
    }

    /// Meldet die laufende Anfrage schon an, verfällt der Link: Er ersetzt keine Sitzung (Q3).
    @Test func linkWhileSigningInIsDroppedOnceSignedIn() async {
        let gateway = FakeGateway()
        let redeemer = FakeRedeemer()
        let signedIn = SignedIn()
        let login = pairingModel(gateway: gateway, redeemer: redeemer, signedIn: signedIn)
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.username = "alex"
        login.password = "demo1234"
        gateway.whileWaiting = { await login.openPairingLink(self.link) }

        await login.submitPassword()

        #expect(signedIn.sessions == [Session(server: server, credential: "ydc_new")])
        #expect(login.step == .password(server: server, appName: "Familie Muster"))
        #expect(redeemer.codes.isEmpty)
    }

    /// Codex-Hinweis zu PR #11: Zugangsdaten für Server A dürfen nach einem Link zu Server B
    /// nicht im Formular bleiben, sonst gingen sie nach einer erneuten Prüfung an B.
    @Test(arguments: [
        ("yuvomi://pair?server=https%3A%2F%2Fother.example.com&code=ACDE34FGHJ", FakeProbe()),
        ("yuvomi://pair?server=https%3A%2F%2Fother.example.com&code=ACDE34FGHJ", FakeProbe(version: .failure(.unreachable))),
        ("yuvomi://pair?code=ACDE34FGHJ", FakeProbe()),
    ])
    func linkClearsTheEnteredCredentials(link: String, probe: FakeProbe) async {
        let login = pairingModel(probe: probe, redeemer: FakeRedeemer(), signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.username = "alex"
        login.password = "demo1234"
        login.code = "123456"
        login.pairingCode = "ACDE"

        await login.openPairingLink(URL(string: link)!)

        #expect(login.username == "")
        #expect(login.password == "")
        #expect(login.code == "")
        #expect(login.pairingCode == "")
    }

    // MARK: Scanner

    /// Ein QR aus der Web-App enthält genau den Kopplungslink und läuft denselben Weg.
    @Test func scannedPairingLinkAsksToConfirmTheServer() async {
        let login = pairingModel(redeemer: FakeRedeemer(), signedIn: SignedIn())

        let accepted = await login.openScannedCode(self.link.absoluteString)

        #expect(accepted)
        #expect(login.step == .confirmPairing(server: server, appName: "Familie Muster", code: "ACDE34FGHJ"))
    }

    /// Fremde QR-Codes beenden den Scan nicht: Man richtet die Kamera einfach neu aus, und
    /// was schon eingegeben ist, bleibt stehen.
    @Test(arguments: [
        "https://yuvomi.example.com",
        "Kein Link, nur Text",
        "yuvomi://pair?code=ACDE34FGHJ",
        "",
    ])
    func foreignQRCodeLeavesTheStepAsItIs(text: String) async {
        let login = pairingModel(probe: Self.ssoOnly, redeemer: FakeRedeemer(), signedIn: SignedIn())
        login.address = "yuvomi.example.com"
        await login.submitAddress()
        login.pairingCode = "ACDE"

        let accepted = await login.openScannedCode(text)

        #expect(!accepted)
        #expect(login.step == .pairing(server: server, appName: "Familie Muster"))
        #expect(login.problem == nil)
        #expect(login.pairingCode == "ACDE")
    }
}
