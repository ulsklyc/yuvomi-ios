import Foundation
import HTTPTypes
import Testing
import YuvomiCore
import YuvomiFixtures
import YuvomiAPI

@Suite struct PairingRedeemerTests {
    let server = URL(string: "https://yuvomi.example.com")!
    let device = DeviceInfo(name: "iPhone", deviceID: "6F1C2A4E-0000-4000-8000-000000000001")

    @Test func redeemsTheCodeWithoutAuthorization() async throws {
        let recorder = FixtureTransport.Recorder()
        let redeemer = YuvomiPairingRedeemer(server: server, device: device, transport: FixtureTransport(recorder: recorder))

        let credential = try await redeemer.redeem(code: "ACDE34FGHJ")

        #expect(credential == "ydc_FIXTURE_CREDENTIAL")
        let requests = await recorder.requests
        #expect(requests.map(\.operationID) == ["redeemPairingCode"])
        #expect(requests[0].request.headerFields[.authorization] == nil)
        #expect(try json(requests[0].body) == ["code": "ACDE34FGHJ", "name": "iPhone", "platform": "ios", "device_id": "6F1C2A4E-0000-4000-8000-000000000001"])
    }

    /// Nur `invalid_pairing_code` heißt „falscher Code“. Ein 400 ohne diesen Grund ist ein
    /// ungültiger Rumpf, also ein Fehler der App, und verbraucht den Code nicht.
    @Test(arguments: [
        (FixtureTransport.Response(status: .badRequest, body: Data(#"{"error":"x","code":400,"reason":"invalid_pairing_code"}"#.utf8)), SignInError.invalidPairingCode),
        (FixtureTransport.Response(status: .badRequest, body: Data(#"{"error":"code is required.","code":400}"#.utf8)), .unexpectedResponse),
        (FixtureTransport.Response(status: .badRequest, body: Data("<html/>".utf8), contentType: "text/html"), .unexpectedResponse),
        (FixtureTransport.Response(status: .forbidden, body: Data(#"{"error":"x","code":403,"reason":"device_credential"}"#.utf8)), .notAllowed),
        (FixtureTransport.Response(status: .tooManyRequests, body: Data()), .rateLimited),
        (FixtureTransport.Response(status: .internalServerError, body: Data(#"{"error":"x","code":500}"#.utf8)), .unexpectedResponse),
        (FixtureTransport.Response(status: .created, body: Data("<html>Router</html>".utf8), contentType: "text/html"), .unexpectedResponse),
    ])
    func refusalsAreNamed(response: FixtureTransport.Response, expected: SignInError) async {
        let redeemer = YuvomiPairingRedeemer(server: server, device: device, transport: FixtureTransport(overrides: ["redeemPairingCode": response]))

        await #expect(throws: expected) { try await redeemer.redeem(code: "ACDE34FGHJ") }
    }

    @Test func withoutAnswerTheServerIsUnreachable() async {
        let redeemer = YuvomiPairingRedeemer(server: server, device: device, transport: FailingTransport(error: URLError(.notConnectedToInternet)))

        await #expect(throws: SignInError.unreachable) { try await redeemer.redeem(code: "ACDE34FGHJ") }
    }
}

private func json(_ body: Data?) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: try #require(body))
}
