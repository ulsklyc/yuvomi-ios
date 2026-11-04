import Foundation
import HTTPTypes
import Testing
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

@Suite struct ReminderWritingAdapterTests {
    let server = URL(string: "https://yuvomi.example.com")!

    /// Antworten wie `v2.84.0`: `{ data: { id } }` und `{ data: { id, status, archived_at, next_due_date } }`.
    static let dismissed = FixtureTransport.Response(body: Data(#"{"data":{"id":7}}"#.utf8))
    static let done = FixtureTransport.Response(body: Data(#"{"data":{"id":12,"status":"done","archived_at":null,"next_due_date":null}}"#.utf8))

    func writer(_ overrides: [String: FixtureTransport.Response], recorder: FixtureTransport.Recorder? = nil) -> YuvomiReminderWriting {
        YuvomiReminderWriting(server: server, credential: "ydc_FIXTURE_CREDENTIAL", transport: FixtureTransport(overrides: overrides, recorder: recorder))
    }

    @Test func dismissPatchesTheReminder() async throws {
        let recorder = FixtureTransport.Recorder()

        try await writer(["dismissReminder": Self.dismissed], recorder: recorder).dismiss(reminder: 7)

        let sent = try #require(await recorder.requests.first)
        #expect(sent.operationID == "dismissReminder")
        #expect(sent.request.method == .patch)
        #expect(sent.request.path == "/api/v1/reminders/7/dismiss")
        #expect(sent.request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
    }

    /// Nur `status`, ohne `done_by_user_id`: Dann gilt die Regel der Zuständigen.
    @Test func checkOffSetsTheTaskToDone() async throws {
        let recorder = FixtureTransport.Recorder()

        try await writer(["updateTaskStatus": Self.done], recorder: recorder).checkOff(task: 12)

        let sent = try #require(await recorder.requests.first)
        #expect(sent.request.method == .patch)
        #expect(sent.request.path == "/api/v1/tasks/12/status")
        #expect(sent.request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
        let body = try JSONSerialization.jsonObject(with: try #require(sent.body)) as? [String: String]
        #expect(body == ["status": "done"])
    }

    /// Auch ohne lesbaren Body: 401, 403 und 404 sind endgültig und müssen als solche ankommen.
    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, APIError.unauthorized),
        (.forbidden, .forbidden),
        (.notFound, .notFound),
        (.internalServerError, .unexpectedResponse),
        (.badRequest, .unexpectedResponse),
    ])
    func failuresAreClassified(status: HTTPResponse.Status, error: APIError) async {
        let withBody = FixtureTransport.Response(status: status, body: Data(#"{"error":"x","code":0,"reason":"module_read_only"}"#.utf8))
        let unreadable = FixtureTransport.Response(status: status, body: Data("<html></html>".utf8), contentType: "text/html")
        for response in [withBody, unreadable] {
            await #expect(throws: error) { try await writer(["dismissReminder": response]).dismiss(reminder: 7) }
            await #expect(throws: error) { try await writer(["updateTaskStatus": response]).checkOff(task: 12) }
        }
    }

    @Test func noAnswerIsUnreachable() async {
        let offline = YuvomiReminderWriting(server: server, credential: "c", transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await #expect(throws: APIError.unreachable) { try await offline.dismiss(reminder: 7) }
        await #expect(throws: APIError.unreachable) { try await offline.checkOff(task: 12) }
    }
}
