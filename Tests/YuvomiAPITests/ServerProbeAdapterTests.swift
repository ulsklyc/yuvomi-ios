import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import YuvomiCore
import YuvomiFixtures
import YuvomiAPI

@Suite struct ServerProbeAdapterTests {
    let server = URL(string: "https://yuvomi.example.com")!

    @Test func readsVersionWithoutAuthorization() async throws {
        let recorder = FixtureTransport.Recorder()
        let probe = YuvomiServerProbe(transport: FixtureTransport(recorder: recorder))

        let version = try await probe.version(at: server)

        #expect(version == ServerVersion(product: "yuvomi", clientAPI: 1, appName: "Yuvomi"))
        let request = try #require(await recorder.requests.first?.request)
        #expect(request.path == "/api/v1/version")
        #expect(request.headerFields[.authorization] == nil)
    }

    @Test func oldServerWithoutProductStillAnswers() async throws {
        let old = Data(#"{"app_name":"Familie Muster","setup_required":false}"#.utf8)
        let probe = YuvomiServerProbe(transport: FixtureTransport(overrides: ["getVersion": .init(body: old)]))
        #expect(try await probe.version(at: server) == ServerVersion(product: nil, clientAPI: nil, appName: "Familie Muster"))
    }

    @Test(arguments: [
        FixtureTransport.Response(body: Data("<html>Router login</html>".utf8)),
        FixtureTransport.Response(status: .notFound, body: Data(#"{"error":"Not found"}"#.utf8)),
    ])
    func answerThatNoYuvomiGivesIsUnexpected(response: FixtureTransport.Response) async {
        let probe = YuvomiServerProbe(transport: FixtureTransport(overrides: ["getVersion": response]))
        await #expect(throws: ServerProbeError.unexpectedResponse) { try await probe.version(at: server) }
    }

    @Test func connectionFailureIsUnreachable() async {
        let probe = YuvomiServerProbe(transport: FailingTransport(error: URLError(.cannotConnectToHost)))
        await #expect(throws: ServerProbeError.unreachable) { try await probe.version(at: server) }
    }
}

extension ServerProbeAdapterTests {
    @Test func readsSignInOptions() async throws {
        let probe = YuvomiServerProbe(transport: FixtureTransport())
        #expect(try await probe.signInOptions(at: server) == SignInOptions(passwordLoginEnabled: true))
    }

    @Test func ssoOnlyServerReportsPasswordLoginOff() async throws {
        let ssoOnly = Data(#"{"enabled":true,"password_login_enabled":false,"guest_password_login_enabled":false}"#.utf8)
        let probe = YuvomiServerProbe(transport: FixtureTransport(overrides: ["getSignInOptions": .init(body: ssoOnly)]))
        #expect(try await probe.signInOptions(at: server) == SignInOptions(passwordLoginEnabled: false))
    }

    @Test func signInOptionsFailuresAreClassified() async {
        let broken = YuvomiServerProbe(transport: FixtureTransport(overrides: ["getSignInOptions": .init(body: Data("<html/>".utf8))]))
        await #expect(throws: ServerProbeError.unexpectedResponse) { try await broken.signInOptions(at: server) }

        let html = FixtureTransport.Response(body: Data("<html>Router login</html>".utf8), contentType: "text/html")
        let router = YuvomiServerProbe(transport: FixtureTransport(overrides: ["getSignInOptions": html]))
        await #expect(throws: ServerProbeError.unexpectedResponse) { try await router.signInOptions(at: server) }

        let offline = YuvomiServerProbe(transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await #expect(throws: ServerProbeError.unreachable) { try await offline.signInOptions(at: server) }
    }
}

/// Transport, der wie URLSession bei fehlender Verbindung wirft.
struct FailingTransport: ClientTransport {
    var error: any Error

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        throw error
    }
}
