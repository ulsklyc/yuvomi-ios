import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Setzt `SessionRevoking` mit dem generierten Client um. Mit Bearer braucht der Server
/// kein CSRF-Token.
public struct YuvomiSessionRevoker: SessionRevoking {
    let transport: any ClientTransport

    public init(transport: any ClientTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func revoke(_ session: Session) async throws(APIError) {
        let client = Client(serverURL: session.server, transport: transport, middlewares: [BearerAuth(credential: session.credential)])
        let output: Operations.SignOutCurrentDevice.Output
        do {
            output = try await client.signOutCurrentDevice()
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok: return
        case .unauthorized: throw .unauthorized
        default: throw .unexpectedResponse
        }
    }
}
