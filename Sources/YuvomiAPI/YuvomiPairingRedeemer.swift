import Foundation
import OpenAPIRuntime
import YuvomiCore

/// Setzt `PairingRedeeming` gegen einen echten Server um (S3 im Plan).
///
/// Ohne `Authorization`: Mit einem gültigen Credential antwortet der Server hier 403. Cookies
/// fallen keine an, die flüchtige URLSession hält trotzdem `HTTPCookieStorage.shared` leer.
public struct YuvomiPairingRedeemer: PairingRedeeming {
    let server: URL
    let device: DeviceInfo
    let transport: any ClientTransport

    public init(server: URL, device: DeviceInfo, transport: any ClientTransport = YuvomiSignInGateway.ephemeralTransport()) {
        self.server = server
        self.device = device
        self.transport = transport
    }

    public func redeem(code: String) async throws(SignInError) -> String {
        let client = Client(serverURL: server, transport: transport)
        do {
            let output = try await client.redeemPairingCode(
                body: .json(.init(code: code, name: device.name, platform: "ios", deviceId: device.deviceID))
            )
            switch output {
            case .created(let created): return try created.body.json.credential
            // Nur dieser Grund heißt „falscher Code“. Ein 400 ohne ihn ist ein ungültiger
            // Rumpf, also ein Fehler der App, und verbraucht den Code nicht.
            case .badRequest(let bad) where (try? bad.body.json.reason) == "invalid_pairing_code":
                throw SignInError.invalidPairingCode
            case .forbidden: throw SignInError(status: .forbidden, during: .pairing)
            case .tooManyRequests: throw SignInError(status: .tooManyRequests, during: .pairing)
            default: throw SignInError.unexpectedResponse
            }
        } catch let error as SignInError {
            throw error
        } catch {
            throw SignInError(classifying: error, during: .pairing)
        }
    }
}
