import Foundation
import Testing
import YuvomiCore

/// Port-Fake: liefert, was ein Server auf `/version` und `/auth/oidc/config` antworten würde.
struct FakeProbe: ServerProbe {
    var version: Result<ServerVersion, ServerProbeError> = .success(
        ServerVersion(product: "yuvomi", clientAPI: 1, appName: "Yuvomi")
    )
    var passwordLoginEnabled = true

    func version(at server: URL) async throws(ServerProbeError) -> ServerVersion {
        try version.get()
    }

    func signInOptions(at server: URL) async throws(ServerProbeError) -> SignInOptions {
        SignInOptions(passwordLoginEnabled: passwordLoginEnabled)
    }
}

@Suite struct ServerCheckTests {
    @Test func addressWithoutSchemeReachesAReadyServer() async {
        let result = await ServerCheck(probe: FakeProbe()).run(address: "yuvomi.example.com")
        #expect(result == .ready(server: URL(string: "https://yuvomi.example.com")!, appName: "Yuvomi", signIn: .password))
    }

    @Test(arguments: [
        ServerVersion(product: "yuvomi", clientAPI: 0, appName: "Yuvomi"),
        // Vor v2.83.0: weder `product` noch `client_api`, aber `app_name` wie jeder Yuvomi.
        ServerVersion(product: nil, clientAPI: nil, appName: "Familie Muster"),
    ])
    func serverBelowClientAPIOneIsTooOld(version: ServerVersion) async {
        let result = await ServerCheck(probe: FakeProbe(version: .success(version))).run(address: "yuvomi.example.com")
        #expect(result == .tooOld)
    }

    @Test func newerClientAPIIsAccepted() async {
        let probe = FakeProbe(version: .success(ServerVersion(product: "yuvomi", clientAPI: 3, appName: "Yuvomi")))
        let result = await ServerCheck(probe: probe).run(address: "yuvomi.example.com")
        #expect(result == .ready(server: URL(string: "https://yuvomi.example.com")!, appName: "Yuvomi", signIn: .password))
    }

    @Test(arguments: [
        Result<ServerVersion, ServerProbeError>.success(ServerVersion(product: "otherapp", clientAPI: 1, appName: "Other")),
        .success(ServerVersion(product: nil, clientAPI: nil, appName: nil)),
        .failure(.unexpectedResponse),
    ])
    func foreignServerIsNotYuvomi(version: Result<ServerVersion, ServerProbeError>) async {
        let result = await ServerCheck(probe: FakeProbe(version: version)).run(address: "example.com")
        #expect(result == .notYuvomi)
    }

    @Test func unreachableServerIsReportedAsSuch() async {
        let result = await ServerCheck(probe: FakeProbe(version: .failure(.unreachable))).run(address: "example.com")
        #expect(result == .unreachable)
    }

    @Test func ssoOnlyServerOffersPairingInsteadOfPassword() async {
        let result = await ServerCheck(probe: FakeProbe(passwordLoginEnabled: false)).run(address: "yuvomi.example.com")
        #expect(result == .ready(server: URL(string: "https://yuvomi.example.com")!, appName: "Yuvomi", signIn: .pairingOnly))
    }

    /// Ohne Schema https, ein eingetipptes http bleibt, Pfad bleibt, Schrägstrich am Ende fällt weg.
    /// Schema und Host klein, damit derselbe Server immer denselben Keychain-Eintrag trifft.
    @Test(arguments: [
        (" yuvomi.example.com ", "https://yuvomi.example.com"),
        ("https://yuvomi.example.com/", "https://yuvomi.example.com"),
        ("http://192.168.1.5:3000", "http://192.168.1.5:3000"),
        ("HTTPS://Yuvomi.Example.com/yuvomi/", "https://yuvomi.example.com/yuvomi"),
        ("yuvomi.local:8080/home", "https://yuvomi.local:8080/home"),
    ])
    func addressIsNormalized(input: String, expected: String) async {
        let result = await ServerCheck(probe: FakeProbe()).run(address: input)
        #expect(result == .ready(server: URL(string: expected)!, appName: "Yuvomi", signIn: .password))
    }

    @Test(arguments: ["", "   ", "ftp://yuvomi.example.com", "https://", "kein host"])
    func unusableAddressIsRejected(input: String) async {
        let result = await ServerCheck(probe: FakeProbe()).run(address: input)
        #expect(result == .invalidAddress)
    }
}
