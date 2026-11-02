import Foundation
import Testing
import YuvomiFixtures

// Rauchtest für das Gerüst: Paket baut, Tests laufen im Simulator, Ressourcen sind erreichbar.
@Test func versionFixtureNamesTheProduct() throws {
    let json = try JSONSerialization.jsonObject(with: Fixtures.data("version")) as? [String: Any]
    #expect(json?["product"] as? String == "yuvomi")
    #expect(json?["client_api"] as? Int == 1)
}
