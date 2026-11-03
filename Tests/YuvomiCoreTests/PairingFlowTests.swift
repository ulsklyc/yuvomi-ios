import Foundation
import Testing
import YuvomiCore

/// Port-Fake: Was der Server auf einen Kopplungscode antworten würde.
final class FakeRedeemer: PairingRedeeming, @unchecked Sendable {
    var result: Result<String, SignInError> = .success("ydc_paired")
    private(set) var redeemedCodes: [String] = []

    func redeem(code: String) async throws(SignInError) -> String {
        redeemedCodes.append(code)
        return try result.get()
    }
}

@Suite struct PairingFlowTests {
    let server = URL(string: "https://yuvomi.example.com")!
    let store = InMemoryCredentialStore()

    @Test func redeemedCodeStoresTheCredential() async throws {
        let redeemer = FakeRedeemer()
        let flow = PairingFlow(server: server, redeemer: redeemer, store: store)

        let session = try await flow.redeem(code: "acde-34fg hj")

        #expect(session == Session(server: server, credential: "ydc_paired"))
        #expect(try store.credential(for: server) == "ydc_paired")
        #expect(redeemer.redeemedCodes == ["ACDE34FGHJ"])
    }

    @Test(arguments: [SignInError.invalidPairingCode, .notAllowed, .rateLimited, .unreachable, .unexpectedResponse])
    func refusalStoresNothing(_ error: SignInError) async throws {
        let redeemer = FakeRedeemer()
        redeemer.result = .failure(error)
        let flow = PairingFlow(server: server, redeemer: redeemer, store: store)

        await #expect(throws: error) { try await flow.redeem(code: "ACDE34FGHJ") }
        #expect(try store.credential(for: server) == nil)
    }

    @Test func keychainFailureIsReported() async {
        let flow = PairingFlow(server: server, redeemer: FakeRedeemer(), store: BrokenStore())
        await #expect(throws: SignInError.credentialNotStored) { try await flow.redeem(code: "ACDE34FGHJ") }
    }
}
