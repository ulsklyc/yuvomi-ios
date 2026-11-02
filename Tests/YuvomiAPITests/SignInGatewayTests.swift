import Foundation
import HTTPTypes
import Testing
import YuvomiCore
import YuvomiFixtures
import YuvomiAPI

@Suite struct SignInGatewayTests {
    let server = URL(string: "https://yuvomi.example.com")!
    let device = DeviceInfo(name: "iPhone", deviceID: "6F1C2A4E-0000-4000-8000-000000000001")

    @Test func passwordSignInAddsTheDeviceAndEndsTheCookieSession() async throws {
        let recorder = FixtureTransport.Recorder()
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FixtureTransport(recorder: recorder))

        let step = try await gateway.signIn(username: "alex", password: "secret")

        #expect(step == .signedIn(credential: "ydc_FIXTURE_CREDENTIAL"))
        let requests = await recorder.requests
        #expect(requests.map(\.operationID) == ["signInWithPassword", "addSignedInDevice", "signOut"])

        let login = requests[0]
        #expect(login.request.headerFields[.authorization] == nil)
        #expect(try json(login.body) == ["username": "alex", "password": "secret"])

        let add = requests[1]
        #expect(add.request.headerFields[csrf] == "FIXTURE_CSRF_TOKEN")
        #expect(try json(add.body) == ["name": "iPhone", "platform": "ios", "device_id": "6F1C2A4E-0000-4000-8000-000000000001"])

        let logout = requests[2]
        #expect(logout.request.method == .post)
        #expect(logout.request.path == "/api/v1/auth/logout")
        #expect(logout.request.headerFields[csrf] == "FIXTURE_CSRF_TOKEN")
    }

    @Test func secondFactorCompletesTheSignInWithItsOwnCSRFToken() async throws {
        let recorder = FixtureTransport.Recorder()
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FixtureTransport(
            overrides: ["signInWithPassword": challenge, "verifySecondFactor": try verified(csrfToken: "VERIFY_CSRF")],
            recorder: recorder
        ))

        #expect(try await gateway.signIn(username: "alex", password: "secret") == .needsSecondFactor)
        #expect(await recorder.requests.map(\.operationID) == ["signInWithPassword"])

        let credential = try await gateway.verifySecondFactor(code: "123456")

        #expect(credential == "ydc_FIXTURE_CREDENTIAL")
        let requests = await recorder.requests
        #expect(requests.map(\.operationID) == ["signInWithPassword", "verifySecondFactor", "addSignedInDevice", "signOut"])
        #expect(try json(requests[1].body) == ["code": "123456"])
        #expect(requests[2].request.headerFields[csrf] == "VERIFY_CSRF")
        #expect(requests[3].request.headerFields[csrf] == "VERIFY_CSRF")
    }

    /// Einordnung nach Status zuerst, auch wenn der Body nicht lesbar ist (wie bei APIError).
    @Test(arguments: [
        (FixtureTransport.Response(status: .unauthorized, body: Data(#"{"error":"Invalid credentials","code":401}"#.utf8)), SignInError.invalidCredentials),
        (FixtureTransport.Response(status: .unauthorized, body: Data("<html/>".utf8), contentType: "text/html"), .invalidCredentials),
        (FixtureTransport.Response(status: .forbidden, body: Data(#"{"error":"x","code":403,"reason":"password_login_disabled"}"#.utf8)), .notAllowed),
        (FixtureTransport.Response(status: .tooManyRequests, body: Data()), .rateLimited),
        (FixtureTransport.Response(status: .internalServerError, body: Data(#"{"error":"x","code":500}"#.utf8)), .unexpectedResponse),
        (FixtureTransport.Response(body: Data("<html>Router</html>".utf8), contentType: "text/html"), .unexpectedResponse),
    ])
    func passwordRefusalsAreNamed(response: FixtureTransport.Response, expected: SignInError) async {
        let recorder = FixtureTransport.Recorder()
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FixtureTransport(overrides: ["signInWithPassword": response], recorder: recorder))

        await #expect(throws: expected) { try await gateway.signIn(username: "alex", password: "wrong") }
        #expect(await recorder.requests.map(\.operationID) == ["signInWithPassword"])
    }

    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, SignInError.invalidCode),
        (.forbidden, .notAllowed),
        (.tooManyRequests, .rateLimited),
        (.badRequest, .unexpectedResponse),
    ])
    func codeRefusalsAreNamed(status: HTTPResponse.Status, expected: SignInError) async throws {
        let recorder = FixtureTransport.Recorder()
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FixtureTransport(
            overrides: ["signInWithPassword": challenge, "verifySecondFactor": .init(status: status, body: Data())],
            recorder: recorder
        ))
        _ = try await gateway.signIn(username: "alex", password: "secret")

        await #expect(throws: expected) { try await gateway.verifySecondFactor(code: "000000") }
        #expect(await recorder.requests.map(\.operationID) == ["signInWithPassword", "verifySecondFactor"])
    }

    /// Ohne Credential ist die Anmeldung gescheitert, auch wenn Passwort oder Code stimmten.
    @Test func deviceRefusalFailsTheSignIn() async {
        let refused = FixtureTransport.Response(status: .forbidden, body: Data(#"{"error":"x","code":403}"#.utf8))
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FixtureTransport(overrides: ["addSignedInDevice": refused]))
        await #expect(throws: SignInError.notAllowed) { try await gateway.signIn(username: "alex", password: "secret") }
    }

    @Test func failedLogoutKeepsTheCredential() async throws {
        let broken = FixtureTransport.Response(status: .internalServerError, body: Data())
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FixtureTransport(overrides: ["signOut": broken]))
        #expect(try await gateway.signIn(username: "alex", password: "secret") == .signedIn(credential: "ydc_FIXTURE_CREDENTIAL"))
    }

    @Test func noConnectionIsUnreachable() async {
        let gateway = YuvomiSignInGateway(server: server, device: device, transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await #expect(throws: SignInError.unreachable) { try await gateway.signIn(username: "alex", password: "secret") }
    }
}

private let challenge = FixtureTransport.Response(body: Data(#"{"twoFactorRequired":true,"recoveryAvailable":true}"#.utf8))

/// Antwort von `/auth/2fa/verify`: dieselben Felder wie beim Login, dazu die 2FA-Angaben.
private func verified(csrfToken: String) throws -> FixtureTransport.Response {
    var body = try #require(JSONSerialization.jsonObject(with: Fixtures.data("auth-login")) as? [String: Any])
    body["csrfToken"] = csrfToken
    body["twoFactorMethod"] = "totp"
    body["recoveryRemaining"] = 8
    return FixtureTransport.Response(body: try JSONSerialization.data(withJSONObject: body))
}

private let csrf = HTTPField.Name("X-CSRF-Token")!

private func json(_ body: Data?) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: try #require(body))
}
