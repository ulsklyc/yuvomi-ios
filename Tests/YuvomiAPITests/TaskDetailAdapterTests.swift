import Foundation
import HTTPTypes
import Testing
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Seam 2: Aufgabe lesen, abhaken, wieder öffnen und ankreuzen über den generierten Client,
/// dazu die Rechte aus `/auth/me`.
@Suite struct TaskDetailAdapterTests {
    let server = URL(string: "https://yuvomi.example.com")!

    func tasks(_ overrides: [String: FixtureTransport.Response] = [:], recorder: FixtureTransport.Recorder? = nil) -> YuvomiTasks {
        YuvomiTasks(server: server, credential: "ydc_FIXTURE_CREDENTIAL", transport: FixtureTransport(overrides: overrides, recorder: recorder))
    }

    /// Fixtures/demo/task-checklist.json: Aufgabe 24 mit Checkliste und zwei Unteraufgaben.
    @Test func readsATaskWithChecklistAndSubtasks() async throws {
        let recorder = FixtureTransport.Recorder()
        let checklist = FixtureTransport.Response(body: try Fixtures.data("task-checklist"))

        let task = try await tasks(["getTask": checklist], recorder: recorder).task(id: 24)

        let sent = try #require(await recorder.requests.first)
        #expect(sent.request.path == "/api/v1/tasks/24")
        #expect(sent.request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
        #expect(task.id == 24)
        #expect(task.title == "Pack for the weekend trip")
        #expect(task.status == .open)
        #expect(task.priority == .medium)
        #expect(task.points == 5)
        #expect(task.isRecurring == false)
        #expect(task.isLocked == false)
        #expect(task.description?.hasPrefix("Leave by **Friday 5 pm**.") == true)
        #expect(Checklist(description: task.description).items.count == 4)
        #expect(task.subtasks.map(\.id) == [25, 26])
        #expect(task.subtasks.map(\.title) == ["Check the car tyres", "Print the route"])
        #expect(task.subtasks.map(\.status) == [.open, .done])
    }

    /// Fixtures/demo/task.json: Aufgabe 7 mit Fälligkeit und Zuständiger, ohne Beschreibung.
    @Test func readsDueDateAndAssignees() async throws {
        let task = try await tasks().task(id: 7)

        #expect(task.title == "Sign school permission slip")
        #expect(task.due == CalendarDay(year: 2026, month: 11, day: 6))
        #expect(task.assignees == ["Linda Johnson"])
        #expect(task.subtasks.isEmpty)
    }

    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, APIError.unauthorized),
        (.notFound, .notFound),
        (.internalServerError, .unexpectedResponse),
    ])
    func readFailuresAreClassified(status: HTTPResponse.Status, error: APIError) async {
        let response = FixtureTransport.Response(status: status, body: Data(#"{"error":"x","code":0,"reason":"tasks_task_not_found"}"#.utf8))
        await #expect(throws: error) { try await tasks(["getTask": response]).task(id: 7) }
    }

    /// Antwort wie `v2.84.0`, Aufgabe 12 setzt eine Serie fort.
    @Test func checkingOffReportsTheNextOccurrence() async throws {
        let recorder = FixtureTransport.Recorder()
        let done = FixtureTransport.Response(body: Data(#"{"data":{"id":12,"status":"done","archived_at":null,"next_due_date":"2026-11-12"}}"#.utf8))

        let change = try await tasks(["updateTaskStatus": done], recorder: recorder).setStatus(task: 12, to: .done)

        let sent = try #require(await recorder.requests.first)
        #expect(sent.request.method == .patch)
        #expect(sent.request.path == "/api/v1/tasks/12/status")
        let body = try JSONSerialization.jsonObject(with: try #require(sent.body)) as? [String: String]
        #expect(body == ["status": "done"])
        #expect(change == StatusChange(status: .done, nextDue: CalendarDay(year: 2026, month: 11, day: 12)))
    }

    @Test func reopeningSendsOpen() async throws {
        let recorder = FixtureTransport.Recorder()
        let open = FixtureTransport.Response(body: Data(#"{"data":{"id":12,"status":"open","archived_at":null,"next_due_date":null}}"#.utf8))

        let change = try await tasks(["updateTaskStatus": open], recorder: recorder).setStatus(task: 12, to: .open)

        let sentBody = try #require(await recorder.requests.first?.body)
        let body = try JSONSerialization.jsonObject(with: sentBody) as? [String: String]
        #expect(body == ["status": "open"])
        #expect(change == StatusChange(status: .open, nextDue: nil))
    }

    @Test func tickingSendsLineStateAndExpectedLine() async throws {
        let recorder = FixtureTransport.Recorder()
        let ticked = FixtureTransport.Response(body: Data(#"{"data":{"id":24,"description":"- [x] Pack sleeping bags"}}"#.utf8))

        let description = try await tasks(["checkTaskItem": ticked], recorder: recorder)
            .tick(task: 24, line: 3, checked: true, expect: "- [ ] Pack sleeping bags")

        let sent = try #require(await recorder.requests.first)
        #expect(sent.request.method == .patch)
        #expect(sent.request.path == "/api/v1/tasks/24/check")
        #expect(sent.request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
        let sentBody = try #require(sent.body)
        let body = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(body["line"] as? Int == 3)
        #expect(body["checked"] as? Bool == true)
        #expect(body["expect"] as? String == "- [ ] Pack sleeping bags")
        #expect(description == "- [x] Pack sleeping bags")
    }

    /// Auch ohne lesbaren Body. 403 nennt die Spec bei `/check` nicht, die Modul-Sperre schickt
    /// sie trotzdem (`module_read_only`).
    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, APIError.unauthorized),
        (.forbidden, .forbidden),
        (.notFound, .notFound),
        (.conflict, .conflict),
        (.internalServerError, .unexpectedResponse),
        (.badRequest, .unexpectedResponse),
    ])
    func writeFailuresAreClassified(status: HTTPResponse.Status, error: APIError) async {
        let withBody = FixtureTransport.Response(status: status, body: Data(#"{"error":"x","code":0,"reason":"stale"}"#.utf8))
        let unreadable = FixtureTransport.Response(status: status, body: Data("<html></html>".utf8), contentType: "text/html")
        for response in [withBody, unreadable] {
            await #expect(throws: error) { try await tasks(["checkTaskItem": response]).tick(task: 24, line: 3, checked: true, expect: "x") }
            // Bei `/status` kommt ein 409 nicht vor, dort bleibt er unerwartet.
            let statusError: APIError = error == .conflict ? .unexpectedResponse : error
            await #expect(throws: statusError) { try await tasks(["updateTaskStatus": response]).setStatus(task: 12, to: .done) }
        }
    }

    @Test func noAnswerIsUnreachable() async {
        let offline = YuvomiTasks(server: server, credential: "c", transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await #expect(throws: APIError.unreachable) { try await offline.task(id: 7) }
        await #expect(throws: APIError.unreachable) { try await offline.setStatus(task: 7, to: .done) }
        await #expect(throws: APIError.unreachable) { try await offline.tick(task: 7, line: 0, checked: true, expect: "x") }
    }

    /// Fixtures/demo/auth-me.json: alex (ID 1) darf in allen Modulen schreiben, der Haushalt
    /// hat vier Mitglieder.
    @Test func membersWithWriteAccessMayWriteTasks() async throws {
        let permissions = YuvomiMemberPermissions(server: server, credential: "c", transport: FixtureTransport())
        #expect(try await permissions.member() == Member(id: 1, mayWriteTasks: true))
    }

    @Test(arguments: ["read", "none", "something-new"])
    func otherAccessMayNotWriteTasks(access: String) async throws {
        let fixture = try Fixtures.data("auth-me")
        var me = try #require(try JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var permissions = try #require(me["permissions"] as? [String: Any])
        var modules = try #require(permissions["modules"] as? [String: Any])
        modules["tasks"] = access
        permissions["modules"] = modules
        me["permissions"] = permissions
        let response = FixtureTransport.Response(body: try JSONSerialization.data(withJSONObject: me))
        let adapter = YuvomiMemberPermissions(server: server, credential: "c", transport: FixtureTransport(overrides: ["getCurrentUser": response]))

        #expect(try await adapter.member().mayWriteTasks == false)
    }
}
