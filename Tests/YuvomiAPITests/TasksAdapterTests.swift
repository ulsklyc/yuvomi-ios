import Foundation
import Testing
import YuvomiCore
import YuvomiFixtures
import YuvomiAPI

@Suite struct TasksAdapterTests {
    let server = URL(string: "https://yuvomi.example.com")!

    @Test func listsTasksWithTheDeviceCredential() async throws {
        let recorder = FixtureTransport.Recorder()
        let tasks = YuvomiTasks(server: server, credential: "ydc_FIXTURE_CREDENTIAL", transport: FixtureTransport(recorder: recorder))

        let list = try await tasks.tasks()

        #expect(list.count == 21)
        // Erster Eintrag von Fixtures/demo/tasks.json.
        #expect(list.first == TaskSummary(
            id: 7,
            title: "Sign school permission slip",
            status: .open,
            priority: .urgent,
            due: CalendarDay(year: 2026, month: 11, day: 3),
            dueTime: nil,
            assignees: ["Linda Johnson"]
        ))
        let request = try #require(await recorder.requests.first?.request)
        #expect(request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
    }

    @Test func revokedCredentialIsUnauthorized() async {
        let revoked = FixtureTransport.Response(status: .unauthorized, body: Data(#"{"error":"Unauthorized","code":401}"#.utf8))
        let tasks = YuvomiTasks(server: server, credential: "ydc_revoked", transport: FixtureTransport(overrides: ["listTasks": revoked]))
        await #expect(throws: APIError.unauthorized) { try await tasks.tasks() }
    }

    /// Proxys und ältere Fehlerseiten antworten auf 401 ohne lesbares `ApiError`. Auch dann
    /// muss das Credential verworfen werden, sonst bleibt die App mit einem toten Schlüssel stehen.
    @Test(arguments: [
        FixtureTransport.Response(status: .unauthorized, body: Data()),
        FixtureTransport.Response(status: .unauthorized, body: Data("<html>401</html>".utf8), contentType: "text/html"),
        FixtureTransport.Response(status: .unauthorized, body: Data(#"{"message":42}"#.utf8)),
    ])
    func unauthorizedWithUnreadableBodyIsStillUnauthorized(response: FixtureTransport.Response) async {
        let tasks = YuvomiTasks(server: server, credential: "ydc_revoked", transport: FixtureTransport(overrides: ["listTasks": response]))
        await #expect(throws: APIError.unauthorized) { try await tasks.tasks() }
    }

    @Test func otherFailuresAreClassified() async {
        let html = FixtureTransport.Response(body: Data("<html/>".utf8), contentType: "text/html")
        let broken = YuvomiTasks(server: server, credential: "c", transport: FixtureTransport(overrides: ["listTasks": html]))
        await #expect(throws: APIError.unexpectedResponse) { try await broken.tasks() }

        let serverError = FixtureTransport.Response(status: .internalServerError, body: Data(#"{"error":"x","code":500}"#.utf8))
        let failing = YuvomiTasks(server: server, credential: "c", transport: FixtureTransport(overrides: ["listTasks": serverError]))
        await #expect(throws: APIError.unexpectedResponse) { try await failing.tasks() }

        let offline = YuvomiTasks(server: server, credential: "c", transport: FailingTransport(error: URLError(.timedOut)))
        await #expect(throws: APIError.unreachable) { try await offline.tasks() }
    }
}
