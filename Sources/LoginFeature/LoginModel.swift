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
        /// Der Server erlaubt keine Passwort-Anmeldung. Koppeln kommt erst mit Slice 2.
        case ssoOnly(appName: String)
        case code
    }

    /// Was die View als Fehlermeldung zeigt. Die Texte stehen im String Catalog.
    public enum Problem: Hashable, Sendable {
        case invalidAddress, unreachable, notYuvomi, tooOld
        case invalidCredentials, invalidCode, notAllowed, rateLimited, credentialNotStored, unexpectedResponse
    }

    public var address = ""
    public var username = ""
    public var password = ""
    public var code = ""
    public private(set) var step: Step = .address
    public private(set) var problem: Problem?
    public private(set) var isWorking = false

    /// Leere Felder schickt die App nicht ab; der Server antwortet darauf nur mit 400.
    public var canSubmitPassword: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    public var canSubmitCode: Bool { !code.trimmingCharacters(in: .whitespaces).isEmpty }

    private let check: ServerCheck
    private let makeFlow: @MainActor (URL) -> SignInFlow
    private let onSignedIn: @MainActor (Session) -> Void

    /// - Parameters:
    ///   - makeFlow: Ein neuer Ablauf pro Server, mit frischem Gateway (eigene Cookie-Sitzung).
    ///   - onSignedIn: Übergibt die Sitzung an die App, etwa an `SessionState.signedIn`.
    public init(check: ServerCheck, makeFlow: @escaping @MainActor (URL) -> SignInFlow, onSignedIn: @escaping @MainActor (Session) -> Void) {
        self.check = check
        self.makeFlow = makeFlow
        self.onSignedIn = onSignedIn
    }

    /// Die `submit…`-Funktionen tun nichts, solange eine Anfrage läuft: Die Tastatur
    /// kann auch absenden, während der Button gesperrt ist.
    public func submitAddress() async {
        guard !isWorking else { return }
        let result = await working { await check.run(address: address) }
        switch result {
        case .ready(let server, let appName, .password): step = .password(server: server, appName: appName)
        case .ready(_, let appName, .pairingOnly): step = .ssoOnly(appName: appName)
        case .invalidAddress: problem = .invalidAddress
        case .unreachable: problem = .unreachable
        case .notYuvomi: problem = .notYuvomi
        case .tooOld: problem = .tooOld
        }
    }

    public func submitPassword() async {
        guard !isWorking, canSubmitPassword, case .password(let server, _) = step else { return }
        let flow = makeFlow(server)
        let result = await working { () async -> Result<SignInStep, SignInError> in
            do throws(SignInError) { return .success(try await flow.submitPassword(username: username, password: password)) } catch { return .failure(error) }
        }
        password = ""
        switch result {
        case .success(.signedIn(let session)): onSignedIn(session)
        case .success(.needsSecondFactor):
            pendingFlow = flow
            returnStep = step
            step = .code
        case .failure(let error): problem = Problem(error)
        }
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
            onSignedIn(session)
        case .failure(let error): problem = Problem(error)
        }
    }

    /// Einen Schritt zurück. Vom Code geht es zum Passwort, mit neuem Versuch. Während
    /// eine Anfrage läuft, bestimmt deren Antwort den nächsten Schritt.
    public func back() {
        guard !isWorking else { return }
        problem = nil
        password = ""
        code = ""
        switch step {
        case .code:
            pendingFlow = nil
            step = returnStep ?? .address
        default:
            step = .address
        }
    }

    /// Der Ablauf zwischen Passwort und Code: Er hält die Cookie-Sitzung des Servers.
    private var pendingFlow: SignInFlow?
    private var returnStep: Step?

    private func working<T>(_ body: () async -> T) async -> T {
        isWorking = true
        problem = nil
        defer { isWorking = false }
        return await body()
    }
}

extension LoginModel.Problem {
    init(_ error: SignInError) {
        switch error {
        case .invalidCredentials: self = .invalidCredentials
        // Gekoppelt wird erst ab B3, bis dahin erreicht dieser Fall das Modell nicht.
        case .invalidCode, .invalidPairingCode: self = .invalidCode
        case .notAllowed: self = .notAllowed
        case .rateLimited: self = .rateLimited
        case .unreachable: self = .unreachable
        case .unexpectedResponse: self = .unexpectedResponse
        case .credentialNotStored: self = .credentialNotStored
        }
    }
}
