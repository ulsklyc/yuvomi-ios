import Foundation
import Observation
import YuvomiCore

/// Zustand des Anmelde-Screens: Adresse prüfen, Passwort, bei Bedarf 2FA.
///
/// Wie ein State-Hook in React: Die View liest `step` und `problem` und ruft die
/// `submit…`-Funktionen; alles andere passiert hier und ist ohne UI testbar.
@MainActor @Observable
public final class LoginModel {
    public enum Step: Hashable, Sendable {
        case address
        case password(server: URL, appName: String)
        /// Kopplungscode eingeben oder scannen, für einen geprüften Server.
        case pairing(server: URL, appName: String)
        /// Link oder QR: Server zeigen und bestätigen lassen, bevor der Code eingelöst wird.
        case confirmPairing(server: URL, appName: String, code: String)
        case code
    }

    /// Was die View als Fehlermeldung zeigt. Die Texte stehen im String Catalog.
    public enum Problem: Hashable, Sendable {
        case invalidAddress, unreachable, notYuvomi, tooOld, invalidPairingLink
        case invalidCredentials, invalidCode, invalidPairingCode, notAllowed, rateLimited, credentialNotStored, unexpectedResponse
    }

    public var address = ""
    public var username = ""
    public var password = ""
    public var code = ""
    public var pairingCode = ""
    public private(set) var step: Step = .address
    public private(set) var problem: Problem?
    public private(set) var isWorking = false

    /// Leere Felder schickt die App nicht ab; der Server antwortet darauf nur mit 400.
    public var canSubmitPassword: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    public var canSubmitCode: Bool { !code.trimmingCharacters(in: .whitespaces).isEmpty }

    public var canSubmitPairingCode: Bool { !PairingCode.normalize(pairingCode).isEmpty }

    private let check: ServerCheck
    private let makeFlow: @MainActor (URL) -> SignInFlow
    private let makePairing: @MainActor (URL) -> PairingFlow
    private let onSignedIn: @MainActor (Session) -> Void

    /// - Parameters:
    ///   - makeFlow: Ein neuer Ablauf pro Server, mit frischem Gateway (eigene Cookie-Sitzung).
    ///   - makePairing: Ein Kopplungsablauf pro Server.
    ///   - onSignedIn: Übergibt die Sitzung an die App, etwa an `SessionState.signedIn`.
    public init(
        check: ServerCheck,
        makeFlow: @escaping @MainActor (URL) -> SignInFlow,
        makePairing: @escaping @MainActor (URL) -> PairingFlow,
        onSignedIn: @escaping @MainActor (Session) -> Void
    ) {
        self.check = check
        self.makeFlow = makeFlow
        self.makePairing = makePairing
        self.onSignedIn = onSignedIn
    }

    /// Die `submit…`-Funktionen tun nichts, solange eine Anfrage läuft: Die Tastatur
    /// kann auch absenden, während der Button gesperrt ist.
    public func submitAddress() async {
        guard !isWorking else { return }
        let result = await working { await check.run(address: address) }
        switch result {
        case .ready(let server, let appName, .password): step = .password(server: server, appName: appName)
        case .ready(let server, let appName, .pairingOnly):
            returnStep = nil
            step = .pairing(server: server, appName: appName)
        default: problem = Problem(result)
        }
        await takeQueuedLink()
    }

    public func submitPassword() async {
        guard !isWorking, canSubmitPassword, case .password(let server, _) = step else { return }
        let flow = makeFlow(server)
        let result = await working { () async -> Result<SignInStep, SignInError> in
            do throws(SignInError) { return .success(try await flow.submitPassword(username: username, password: password)) } catch { return .failure(error) }
        }
        password = ""
        switch result {
        case .success(.signedIn(let session)): signedIn(session)
        case .success(.needsSecondFactor):
            pendingFlow = flow
            returnStep = step
            step = .code
        case .failure(let error): problem = Problem(error)
        }
        await takeQueuedLink()
    }

    public func submitCode() async {
        guard !isWorking, canSubmitCode, step == .code, let flow = pendingFlow else { return }
        let result = await working { () async -> Result<Session, SignInError> in
            do throws(SignInError) { return .success(try await flow.submitCode(code)) } catch { return .failure(error) }
        }
        code = ""
        switch result {
        case .success(let session):
            pendingFlow = nil
            signedIn(session)
        case .failure(let error): problem = Problem(error)
        }
        await takeQueuedLink()
    }

    /// Ein Kopplungslink aus iOS oder ein gescannter QR. Der Server wird geprüft wie eine
    /// eingetippte Adresse, eingelöst wird erst nach `confirmPairing()`.
    public func openPairingLink(_ url: URL) async {
        guard !isWorking else {
            queuedLink = url
            return
        }
        // Q8: Der Link gewinnt. Ein offener 2FA-Versuch fällt mit seiner Cookie-Sitzung weg,
        // und Eingaben für den bisherigen Server gehen nicht an den aus dem Link.
        pendingFlow = nil
        username = ""
        password = ""
        code = ""
        pairingCode = ""
        guard let link = PairingLink(url: url) else {
            step = .address
            problem = .invalidPairingLink
            return
        }
        address = link.server.absoluteString
        let result = await working { await check.run(address: address) }
        switch result {
        case .ready(let server, let appName, _): step = .confirmPairing(server: server, appName: appName, code: link.code)
        default:
            step = .address
            problem = Problem(result)
        }
        await takeQueuedLink()
    }

    /// Ein QR aus dem Scanner. `false` heißt: kein Kopplungslink, der Scanner bleibt offen.
    public func openScannedCode(_ text: String) async -> Bool {
        guard let url = URL(string: text), PairingLink(url: url) != nil else { return false }
        await openPairingLink(url)
        return true
    }

    public func confirmPairing() async {
        guard !isWorking, case .confirmPairing(let server, _, let code) = step else { return }
        await redeem(code, at: server)
    }

    /// „Stattdessen mit Code anmelden“ im Passwort-Schritt.
    public func startPairing() {
        guard !isWorking, case .password(let server, let appName) = step else { return }
        problem = nil
        returnStep = step
        step = .pairing(server: server, appName: appName)
    }

    /// Löst den abgetippten Kopplungscode für den geprüften Server ein.
    public func submitPairingCode() async {
        guard !isWorking, canSubmitPairingCode, case .pairing(let server, _) = step else { return }
        await redeem(pairingCode, at: server)
    }

    private func redeem(_ code: String, at server: URL) async {
        let flow = makePairing(server)
        let result = await working { () async -> Result<Session, SignInError> in
            do throws(SignInError) { return .success(try await flow.redeem(code: code)) } catch { return .failure(error) }
        }
        switch result {
        case .success(let session): signedIn(session)
        case .failure(let error):
            problem = Problem(error)
            // Ein ungültiger Code ist falsch oder verbraucht; bei Netzfehlern und zu vielen
            // Versuchen bleibt er stehen, damit ein zweiter Versuch ohne neuen Code geht.
            if error == .invalidPairingCode {
                pairingCode = ""
                // Aus der Bestätigung geht es zur Code-Eingabe für denselben Server (Q9).
                if case .confirmPairing(let server, let appName, _) = step {
                    returnStep = nil
                    step = .pairing(server: server, appName: appName)
                }
            }
        }
        await takeQueuedLink()
    }

    /// Einen Schritt zurück. Vom Code geht es zum Passwort, mit neuem Versuch. Während
    /// eine Anfrage läuft, bestimmt deren Antwort den nächsten Schritt.
    public func back() {
        guard !isWorking else { return }
        problem = nil
        password = ""
        code = ""
        pairingCode = ""
        switch step {
        case .code:
            pendingFlow = nil
            step = returnStep ?? .address
        case .pairing:
            step = returnStep ?? .address
        default:
            step = .address
        }
    }

    /// Ein Link, der während einer Anfrage kam. Er gilt nach deren Antwort, der letzte gewinnt.
    private var queuedLink: URL?
    private var handedOver = false

    private func signedIn(_ session: Session) {
        handedOver = true
        onSignedIn(session)
    }

    /// Hat die Antwort schon angemeldet, verfällt der Link: Eine bestehende Sitzung ersetzt
    /// er nicht (Q3).
    private func takeQueuedLink() async {
        guard let url = queuedLink else { return }
        queuedLink = nil
        guard !handedOver else { return }
        await openPairingLink(url)
    }

    /// Der Ablauf zwischen Passwort und Code: Er hält die Cookie-Sitzung des Servers.
    private var pendingFlow: SignInFlow?
    /// Wohin „Zurück“ aus dem 2FA-Code oder der Code-Eingabe führt.
    private var returnStep: Step?

    private func working<T>(_ body: () async -> T) async -> T {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        return await body()
    }
}

extension LoginModel.Problem {
    /// Nur für Ergebnisse, die nicht `.ready` sind.
    init?(_ result: ServerCheckResult) {
        switch result {
        case .ready: return nil
        case .invalidAddress: self = .invalidAddress
        case .unreachable: self = .unreachable
        case .notYuvomi: self = .notYuvomi
        case .tooOld: self = .tooOld
        }
    }

    init(_ error: SignInError) {
        switch error {
        case .invalidCredentials: self = .invalidCredentials
        case .invalidCode: self = .invalidCode
        case .invalidPairingCode: self = .invalidPairingCode
        case .notAllowed: self = .notAllowed
        case .rateLimited: self = .rateLimited
        case .unreachable: self = .unreachable
        case .unexpectedResponse: self = .unexpectedResponse
        case .credentialNotStored: self = .credentialNotStored
        }
    }
}
