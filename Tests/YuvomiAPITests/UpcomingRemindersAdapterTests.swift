import Foundation
import Testing
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

@Suite struct UpcomingRemindersAdapterTests {
    let server = URL(string: "https://yuvomi.example.com")!
    /// 2026-11-03 12:00 UTC, Fenster bis 2026-11-17 12:00 UTC.
    let from = Date(timeIntervalSince1970: 1_793_707_200)
    var to: Date { from.addingTimeInterval(1_209_600) }

    @Test func readsTheUpcomingRemindersOfTasksAndEventsOnly() async throws {
        let recorder = FixtureTransport.Recorder()
        let reminders = YuvomiUpcomingReminders(server: server, credential: "ydc_FIXTURE_CREDENTIAL", transport: FixtureTransport(recorder: recorder))

        let list = try await reminders.upcoming(from: from, to: to)

        // Einziger Eintrag von Fixtures/demo/reminders-upcoming.json.
        #expect(list == [UpcomingReminder(
            id: 1, origin: .task, entityID: 2, title: "Pay electricity bill",
            firesAt: try #require(ISO8601DateFormatter().date(from: "2026-11-04T07:00:00Z"))
        )])
        let request = try #require(await recorder.requests.first?.request)
        let query = try #require(URLComponents(string: request.path ?? "")?.queryItems)
        #expect(query.first { $0.name == "types" }?.value == "task,event")
        #expect(query.first { $0.name == "from" }?.value == "2026-11-03T12:00:00Z")
        #expect(query.first { $0.name == "to" }?.value == "2026-11-17T12:00:00Z")
        #expect(request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
    }

    /// Fixtures/derived/reminders-upcoming-unknown-type.json: Eine Erinnerung mit einer Herkunft,
    /// die die App nicht abfragt, kippt die Antwort nicht. Die bekannte bleibt, die fremde fällt
    /// weg (siehe `UpcomingReminder.init?`).
    @Test func aReminderOfAnUnknownTypeLeavesTheOthersIntact() async throws {
        let variant = FixtureTransport.Response(body: try Fixtures.derived("reminders-upcoming-unknown-type"))
        let reminders = YuvomiUpcomingReminders(server: server, credential: "c", transport: FixtureTransport(overrides: ["listUpcomingReminders": variant]))

        let list = try await reminders.upcoming(from: from, to: to)

        #expect(list == [UpcomingReminder(
            id: 1, origin: .task, entityID: 2, title: "Pay electricity bill",
            firesAt: try #require(ISO8601DateFormatter().date(from: "2026-11-04T07:00:00Z"))
        )])
    }

    /// Auch mit unlesbarem Body: Sonst behielte die App ein widerrufenes Credential.
    @Test(arguments: [
        FixtureTransport.Response(status: .unauthorized, body: Data()),
        FixtureTransport.Response(status: .unauthorized, body: Data("<html>401</html>".utf8), contentType: "text/html"),
        FixtureTransport.Response(status: .unauthorized, body: Data(#"{"message":42}"#.utf8)),
    ])
    func revokedCredentialIsUnauthorized(response: FixtureTransport.Response) async {
        let reminders = YuvomiUpcomingReminders(server: server, credential: "ydc_revoked", transport: FixtureTransport(overrides: ["listUpcomingReminders": response]))
        await #expect(throws: APIError.unauthorized) { try await reminders.upcoming(from: from, to: to) }
    }

    @Test func otherFailuresAreClassified() async {
        let tooLong = FixtureTransport.Response(status: .badRequest, body: Data(#"{"error":"window","code":400}"#.utf8))
        let refused = YuvomiUpcomingReminders(server: server, credential: "c", transport: FixtureTransport(overrides: ["listUpcomingReminders": tooLong]))
        await #expect(throws: APIError.unexpectedResponse) { try await refused.upcoming(from: from, to: to) }

        let offline = YuvomiUpcomingReminders(server: server, credential: "c", transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await #expect(throws: APIError.unreachable) { try await offline.upcoming(from: from, to: to) }
    }

    /// Ein Server, der doch eine andere Herkunft schickt, darf sie nicht ins Telefon bringen.
    @Test func leavesOutOriginsTheAppDoesNotAskFor() async throws {
        let body = Data("""
        {"data":[
          {"id":1,"entity_type":"subscription","entity_id":3,"entity_title":"Streaming","remind_at":"2026-11-04T07:00:00Z","created_by":1,"fires_at":"2026-11-04T07:00:00Z"},
          {"id":2,"entity_type":"event","entity_id":4,"entity_title":null,"remind_at":"2026-11-04T08:00:00Z","created_by":1,"fires_at":"2026-11-04T08:00:00Z"}
        ]}
        """.utf8)
        let reminders = YuvomiUpcomingReminders(server: server, credential: "c", transport: FixtureTransport(overrides: ["listUpcomingReminders": .init(body: body)]))

        let list = try await reminders.upcoming(from: from, to: to)

        #expect(list.map(\.id) == [2])
        #expect(list.first?.origin == .event)
        #expect(list.first?.title == "")
        #expect(list.first?.entityID == 4)
    }
}
