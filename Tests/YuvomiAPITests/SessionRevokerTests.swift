import Foundation
import Testing
import YuvomiCore
import YuvomiFixtures
import YuvomiAPI

@Suite struct SessionRevokerTests {
    let session = Session(server: URL(string: "https://yuvomi.example.com")!, credential: "ydc_FIXTURE_CREDENTIAL")
    let ok = FixtureTransport.Response(body: Data(#"{"ok":true}"#.utf8))

    @Test func revokesTheCurrentDeviceWithItsCredential() async throws {
        let recorder = FixtureTransport.Recorder()
        let revoker = YuvomiSessionRevoker(transport: FixtureTransport(overrides: ["signOutCurrentDevice": ok], recorder: recorder))

        try await revoker.revoke(session)

        let request = try #require(await recorder.requests.first?.request)
        #expect(request.method == .delete)
        #expect(request.path == "/api/v1/auth/devices/current")
        #expect(request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
    }

    @Test func failuresAreClassified() async {
        let gone = FixtureTransport.Response(status: .unauthorized, body: Data())
        let revoked = YuvomiSessionRevoker(transport: FixtureTransport(overrides: ["signOutCurrentDevice": gone]))
        await #expect(throws: APIError.unauthorized) { try await revoked.revoke(session) }

        let offline = YuvomiSessionRevoker(transport: FailingTransport(error: URLError(.timedOut)))
        await #expect(throws: APIError.unreachable) { try await offline.revoke(session) }
    }
}
