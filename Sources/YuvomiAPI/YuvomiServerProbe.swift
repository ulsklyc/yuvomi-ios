import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Setzt `ServerProbe` gegen einen echten Server um.
///
/// `/version` liest der Adapter selbst und nachsichtig: Im generierten Typ sind `product`
/// und `client_api` Pflicht, ein alter oder fremder Server würde dort nur als Dekodierfehler
/// enden. `ServerCheck` soll aber unterscheiden können. Die Abfrage geht immer ohne
/// `Authorization` (S1: ein ungültiges Credential ergäbe 401).
public struct YuvomiServerProbe: ServerProbe {
    let transport: any ClientTransport

    public init(transport: any ClientTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func version(at server: URL) async throws(ServerProbeError) -> ServerVersion {
        let request = HTTPRequest(method: .get, scheme: nil, authority: nil, path: "/api/v1/version")
        let response: HTTPResponse
        let body: HTTPBody?
        do {
            (response, body) = try await transport.send(request, body: nil, baseURL: server, operationID: "getVersion")
        } catch {
            throw .unreachable
        }
        guard response.status == .ok, let body,
              let data = try? await Data(collecting: body, upTo: 64 * 1024),
              let payload = try? JSONDecoder().decode(LenientVersion.self, from: data)
        else { throw .unexpectedResponse }
        return ServerVersion(product: payload.product, clientAPI: payload.client_api, appName: payload.app_name)
    }

    public func signInOptions(at server: URL) async throws(ServerProbeError) -> SignInOptions {
        let client = Client(serverURL: server, transport: transport)
        do {
            let output = try await client.getSignInOptions()
            guard case .ok(let ok) = output, case .json(let options) = ok.body else { throw ServerProbeError.unexpectedResponse }
            return SignInOptions(passwordLoginEnabled: options.passwordLoginEnabled)
        } catch let error as ServerProbeError {
            throw error
        } catch {
            throw ServerProbeError(classifying: error)
        }
    }
}

extension ServerProbeError {
    /// Ordnet einen Fehler des generierten Clients ein: Kam keine Antwort, ist der Server
    /// nicht erreichbar; kam eine, die sich nicht lesen ließ (falscher Typ, HTML, kaputtes
    /// JSON), ist sie unerwartet.
    init(classifying error: any Error) {
        self = (error as? ClientError)?.response == nil ? .unreachable : .unexpectedResponse
    }
}

private struct LenientVersion: Decodable {
    var product: String?
    var client_api: Int?
    var app_name: String?
}
