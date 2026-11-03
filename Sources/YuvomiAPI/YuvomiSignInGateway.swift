import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Was der Server über dieses Gerät erfährt. Die App setzt `identifierForVendor` ein.
public struct DeviceInfo: Hashable, Sendable {
    public var name: String
    public var deviceID: String

    public init(name: String, deviceID: String) {
        self.name = name
        self.deviceID = deviceID
    }
}

/// Setzt `SignInGateway` gegen einen echten Server um (S2 im Plan).
///
/// Ein Exemplar pro Anmeldeversuch: Login und 2FA laufen über eine Cookie-Sitzung, die nur
/// so lange lebt, bis das Gerät sein Credential hat. Danach meldet sich der Gateway von der
/// Cookie-Sitzung ab, die flüchtige URLSession verwirft die Cookies mit sich. Ab dann gilt
/// nur noch der Bearer.
public actor YuvomiSignInGateway: SignInGateway {
    let server: URL
    let device: DeviceInfo
    let transport: any ClientTransport

    public init(server: URL, device: DeviceInfo, transport: any ClientTransport = YuvomiSignInGateway.ephemeralTransport()) {
        self.server = server
        self.device = device
        self.transport = transport
    }

    /// Eigene URLSession ohne gemeinsamen Cookie-Speicher, damit nichts aus dem Versuch
    /// in `HTTPCookieStorage.shared` landet.
    public static func ephemeralTransport() -> URLSessionTransport {
        URLSessionTransport(configuration: .init(session: URLSession(configuration: .ephemeral)))
    }

    public func signIn(username: String, password: String) async throws(SignInError) -> PasswordStep {
        let client = Client(serverURL: server, transport: transport)
        let csrfToken: String
        do {
            let output = try await client.signInWithPassword(body: .json(.init(username: username, password: password)))
            let ok: Operations.SignInWithPassword.Output.Ok
            switch output {
            case .ok(let response): ok = response
            case .unauthorized: throw SignInError(status: .unauthorized, during: .password)
            case .forbidden: throw SignInError(status: .forbidden, during: .password)
            case .tooManyRequests: throw SignInError(status: .tooManyRequests, during: .password)
            default: throw SignInError.unexpectedResponse
            }
            switch ok.body {
            case .json(.LoginResponse(let login)):
                csrfToken = login.csrfToken
            case .json(.TwoFactorChallengeResponse):
                return .needsSecondFactor
            }
        } catch let error as SignInError {
            throw error
        } catch {
            throw SignInError(classifying: error, during: .password)
        }
        return .signedIn(credential: try await addDevice(csrfToken: csrfToken))
    }

    /// Läuft über denselben Transport wie `signIn`: Der Server hält die offene Anmeldung
    /// in der Cookie-Sitzung des ersten Schritts.
    public func verifySecondFactor(code: String) async throws(SignInError) -> String {
        let client = Client(serverURL: server, transport: transport)
        let csrfToken: String
        do {
            let output = try await client.verifySecondFactor(body: .json(.init(code: code)))
            switch output {
            case .ok(let ok): csrfToken = try ok.body.json.csrfToken
            case .unauthorized: throw SignInError(status: .unauthorized, during: .code)
            case .forbidden: throw SignInError(status: .forbidden, during: .code)
            case .tooManyRequests: throw SignInError(status: .tooManyRequests, during: .code)
            default: throw SignInError.unexpectedResponse
            }
        } catch let error as SignInError {
            throw error
        } catch {
            throw SignInError(classifying: error, during: .code)
        }
        return try await addDevice(csrfToken: csrfToken)
    }

    private func addDevice(csrfToken: String) async throws(SignInError) -> String {
        let client = Client(serverURL: server, transport: transport)
        let credential: String
        do {
            let output = try await client.addSignedInDevice(
                headers: .init(xCSRFToken: csrfToken),
                body: .json(.init(name: device.name, platform: "ios", deviceId: device.deviceID))
            )
            switch output {
            case .created(let created): credential = try created.body.json.credential
            case .forbidden: throw SignInError(status: .forbidden, during: .device)
            default: throw SignInError.unexpectedResponse
            }
        } catch let error as SignInError {
            throw error
        } catch {
            throw SignInError(classifying: error, during: .device)
        }
        await endCookieSession(csrfToken: csrfToken)
        return credential
    }

    /// `POST /auth/logout` gehört nicht zu den Operationen des Clients, deshalb geht er
    /// direkt über den Transport. Nur ein Versuch: Das Credential ist schon ausgestellt.
    private func endCookieSession(csrfToken: String) async {
        var fields = HTTPFields()
        fields[csrfHeader] = csrfToken
        let request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/api/v1/auth/logout", headerFields: fields)
        _ = try? await transport.send(request, body: nil, baseURL: server, operationID: "signOut")
    }
}

private let csrfHeader = HTTPField.Name("X-CSRF-Token")!

extension SignInError {
    enum Step { case password, code, device, pairing }

    /// Was ein Status im jeweiligen Schritt bedeutet. Ein 401 beim Passwort ist etwas
    /// anderes als ein 401 beim Code.
    init(status: HTTPResponse.Status, during step: Step) {
        switch (status, step) {
        case (.unauthorized, .password): self = .invalidCredentials
        case (.unauthorized, .code): self = .invalidCode
        case (.forbidden, _): self = .notAllowed
        case (.tooManyRequests, _): self = .rateLimited
        default: self = .unexpectedResponse
        }
    }

    /// Ohne Antwort ist der Server nicht erreichbar. Mit Antwort zählt zuerst der Status,
    /// denn ein Proxy liefert zum 401 oft einen Body, den der Client nicht lesen kann.
    init(classifying error: any Error, during step: Step) {
        guard let status = (error as? ClientError)?.response?.status else {
            self = .unreachable
            return
        }
        self.init(status: status, during: step)
    }
}
