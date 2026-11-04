import Foundation
import OpenAPIRuntime
import Testing
import YuvomiFixtures
@testable import YuvomiAPI

/// Jede Fixture läuft einmal durch den generierten Client. Schlägt das Dekodieren fehl,
/// passt die Spec nicht zu dem, was `v2.84.0` wirklich sendet.
@Suite struct FixtureDecodingTests {
    let client = Client(serverURL: URL(string: "https://fixture.invalid")!, transport: FixtureTransport())

    @Test func instanceAndSignIn() async throws {
        let version = try await client.getVersion().ok.body.json
        #expect(version.product == "yuvomi")
        #expect(version.clientApi == 1)
        _ = try await client.getSignInOptions().ok.body.json
        _ = try await client.signInWithPassword(body: .json(.init(username: "alex", password: "demo1234"))).ok.body.json
        _ = try await client.getCurrentUser().ok.body.json
    }

    @Test func signedInDevices() async throws {
        _ = try await client.addSignedInDevice(body: .json(.init(name: "iPhone", platform: "ios", deviceId: "fixture-device-0001"))).created.body.json
        _ = try await client.listSignedInDevices().ok.body.json
    }

    @Test func dashboard() async throws {
        _ = try await client.getDashboard().ok.body.json
    }

    @Test func tasks() async throws {
        let tasks = try await client.listTasks().ok.body.json
        #expect(!tasks.data.isEmpty)
        _ = try await client.getTaskOptions().ok.body.json
        _ = try await client.getTask(path: .init(id: 1)).ok.body.json
    }

    @Test func shopping() async throws {
        _ = try await client.listShoppingLists().ok.body.json
        _ = try await client.listShoppingListVersions().ok.body.json
        _ = try await client.listShoppingSuggestions().ok.body.json
        _ = try await client.listShoppingCategories().ok.body.json
        _ = try await client.listShoppingItems(path: .init(listId: 1)).ok.body.json
    }

    @Test func calendar() async throws {
        _ = try await client.listCalendarEvents().ok.body.json
        _ = try await client.listUpcomingCalendarEvents().ok.body.json
        _ = try await client.listLocalCalendars().ok.body.json
        _ = try await client.getCalendarEvent(path: .init(id: 1)).ok.body.json
    }

    @Test func reminders() async throws {
        let now = Date()
        _ = try await client.listUpcomingReminders(query: .init(from: now, to: now.addingTimeInterval(14 * 86_400))).ok.body.json
        _ = try await client.listPendingReminders().ok.body.json
    }

    /// Ein unbekannter Wert in einer Antwort, hier ein neuer Status und eine neue Priorität,
    /// kippt nicht die ganze Liste (Fixtures/derived, abgeleitet aus tasks.json).
    @Test func unknownValuesInAResponseStillDecode() async throws {
        let variant = FixtureTransport.Response(body: try Fixtures.derived("tasks-unknown-values"))
        let client = Client(serverURL: URL(string: "https://fixture.invalid")!, transport: FixtureTransport(overrides: ["listTasks": variant]))
        let tasks = try await client.listTasks().ok.body.json
        #expect(tasks.data.count == 21)
        #expect(tasks.data.first?.status == "waiting")
    }

    /// Wächter: Jede Fixture-Datei hat einen Eintrag in FixtureTransport.defaults.
    @Test func everyFixtureIsMapped() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Fixtures.directory.path())
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("_") }
            .map { String($0.dropLast(".json".count)) }
        let mapped = Set(FixtureTransport.defaults.values.map(\.file))
        #expect(Set(files) == mapped)
        #expect(files.count == 21)
    }
}
