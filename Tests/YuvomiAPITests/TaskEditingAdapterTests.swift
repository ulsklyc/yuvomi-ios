import Foundation
import HTTPTypes
import Testing
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Seam 2: Anlegen, Ändern, Löschen und Optionen über den Fixture-Transport. Die Antworten
/// stammen von `v2.85.0` (Fixtures/demo/task-created.json, task-updated.json).
@Suite struct TaskEditingAdapterTests {
    let server = URL(string: "https://yuvomi.example.com")!
    static let ok = FixtureTransport.Response(body: Data(#"{"ok":true}"#.utf8))

    func tasks(_ overrides: [String: FixtureTransport.Response] = [:], recorder: FixtureTransport.Recorder? = nil) -> YuvomiTasks {
        YuvomiTasks(server: server, credential: "ydc_FIXTURE_CREDENTIAL", transport: FixtureTransport(overrides: overrides, recorder: recorder))
    }

    func json(_ body: Data?) throws -> NSDictionary {
        let data = try #require(body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test func createPostsOnlyTheFilledFields() async throws {
        let recorder = FixtureTransport.Recorder()
        var draft = TaskDraft()
        draft.title = " Water the plants "
        draft.due = CalendarDay(year: 2026, month: 11, day: 5)
        draft.dueTime = "18:30"
        draft.assigneeIDs = [1]
        draft.priority = .low
        draft.category = "household"
        draft.description = "The big ones on the balcony."

        let created = try await tasks(recorder: recorder).create(draft, parent: nil, idempotencyKey: "key-1")

        #expect(created.id == 27)
        #expect(created.title == "Water the plants")
        let sent = try #require(await recorder.requests.first)
        #expect(sent.operationID == "createTask")
        #expect(sent.request.method == .post)
        #expect(sent.request.path == "/api/v1/tasks")
        #expect(sent.request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
        #expect(sent.request.headerFields[HTTPField.Name("Idempotency-Key")!] == "key-1")
        #expect(try json(sent.body) == [
            "title": "Water the plants", "due_date": "2026-11-05", "due_time": "18:30",
            "assigned_to": [1], "priority": "low", "category": "household",
            "description": "The big ones on the balcony.",
        ])
    }

    /// Eine Unteraufgabe hat nur einen Titel (Q5). Den Rest setzt der Server.
    @Test func createSubtaskSendsTitleAndParent() async throws {
        let recorder = FixtureTransport.Recorder()
        var draft = TaskDraft()
        draft.title = "Balcony"

        _ = try await tasks(recorder: recorder).create(draft, parent: 27, idempotencyKey: "key-2")

        let sent = try #require(await recorder.requests.first)
        #expect(try json(sent.body) == ["title": "Balcony", "parent_task_id": 27])
    }

    @Test func updatePutsOnlyTheChanges() async throws {
        let recorder = FixtureTransport.Recorder()

        let updated = try await tasks(recorder: recorder).update(
            task: 27, TaskChanges(title: "Water all the plants", dueTime: .clear)
        )

        #expect(updated.title == "Water all the plants")
        #expect(updated.dueTime == nil)
        #expect(updated.assigneeIDs == [1])
        #expect(updated.category == "household")
        #expect(updated.createdBy == 1)
        let sent = try #require(await recorder.requests.first)
        #expect(sent.request.method == .put)
        #expect(sent.request.path == "/api/v1/tasks/27")
        #expect(try json(sent.body) == ["title": "Water all the plants", "due_time": NSNull()])
    }

    @Test func updateClearsWithNull() async throws {
        let recorder = FixtureTransport.Recorder()

        _ = try await tasks(recorder: recorder).update(
            task: 27, TaskChanges(due: .clear, dueTime: .clear, assigneeIDs: .clear, description: .clear)
        )

        let sent = try #require(await recorder.requests.first)
        #expect(try json(sent.body) == [
            "due_date": NSNull(), "due_time": NSNull(), "assigned_to": NSNull(), "description": NSNull(),
        ])
    }

    @Test func deleteSendsDelete() async throws {
        let recorder = FixtureTransport.Recorder()

        try await tasks(["deleteTask": Self.ok], recorder: recorder).delete(task: 27)

        let sent = try #require(await recorder.requests.first)
        #expect(sent.request.method == .delete)
        #expect(sent.request.path == "/api/v1/tasks/27")
        #expect(sent.request.headerFields[.authorization] == "Bearer ydc_FIXTURE_CREDENTIAL")
    }

    /// Fixtures/demo/tasks-meta-options.json: vier Mitglieder, die eingebauten Kategorien mit
    /// `label_key` und ohne Namen.
    @Test func optionsListPeopleAndCategories() async throws {
        let options = try await tasks().options()

        #expect(options.people.map(\.id) == [1, 3, 4, 2])
        #expect(options.people.first?.name == "Alex Johnson")
        #expect(options.categories.first == TaskCategory(key: "household", name: nil, labelKey: "tasks.categoryHousehold"))
    }

    /// Q13: 403 mit `task_locked` ist die Sperre, jedes andere 403 fehlende Rechte.
    @Test(arguments: [
        (#"{"error":"x","code":403,"reason":"task_locked"}"#, APIError.locked),
        (#"{"error":"x","code":403,"reason":"module_read_only"}"#, .forbidden),
        (#"{"error":"x","code":403}"#, .forbidden),
        ("<html></html>", .forbidden),
    ])
    func forbiddenCarriesTheReason(body: String, error: APIError) async {
        let response = FixtureTransport.Response(status: .forbidden, body: Data(body.utf8))
        var draft = TaskDraft()
        draft.title = "Call"
        await #expect(throws: error) { try await tasks(["createTask": response]).create(draft, parent: 27, idempotencyKey: "k") }
        await #expect(throws: error) { try await tasks(["updateTask": response]).update(task: 27, TaskChanges(title: "x")) }
        await #expect(throws: error) { try await tasks(["deleteTask": response]).delete(task: 27) }
    }

    /// Auch ohne lesbaren Body kommen 401, 404 und 409 als solche an.
    @Test(arguments: [
        (HTTPResponse.Status.unauthorized, APIError.unauthorized),
        (.notFound, .notFound),
        (.badRequest, .unexpectedResponse),
        (.internalServerError, .unexpectedResponse),
    ])
    func failuresAreClassified(status: HTTPResponse.Status, error: APIError) async {
        let withBody = FixtureTransport.Response(status: status, body: Data(#"{"error":"x","code":0}"#.utf8))
        let unreadable = FixtureTransport.Response(status: status, body: Data("<html></html>".utf8), contentType: "text/html")
        var draft = TaskDraft()
        draft.title = "Call"
        for response in [withBody, unreadable] {
            await #expect(throws: error) { try await tasks(["createTask": response]).create(draft, parent: nil, idempotencyKey: "k") }
            await #expect(throws: error) { try await tasks(["updateTask": response]).update(task: 27, TaskChanges(title: "x")) }
            await #expect(throws: error) { try await tasks(["deleteTask": response]).delete(task: 27) }
        }
    }

    /// 409 gibt es nur beim Anlegen: Derselbe Schlüssel läuft noch (Q14).
    @Test func createConflictIsConflict() async {
        let withBody = FixtureTransport.Response(status: .conflict, body: Data(#"{"error":"x","code":409}"#.utf8))
        let unreadable = FixtureTransport.Response(status: .conflict, body: Data("<html></html>".utf8), contentType: "text/html")
        var draft = TaskDraft()
        draft.title = "Call"
        for response in [withBody, unreadable] {
            await #expect(throws: APIError.conflict) { try await tasks(["createTask": response]).create(draft, parent: nil, idempotencyKey: "k") }
        }
    }

    @Test func optionsForbiddenAndUnauthorized() async {
        let forbidden = FixtureTransport.Response(status: .forbidden, body: Data(#"{"error":"x","code":403,"reason":"module_access_denied"}"#.utf8))
        let unauthorized = FixtureTransport.Response(status: .unauthorized, body: Data(#"{"error":"x","code":401}"#.utf8))
        await #expect(throws: APIError.forbidden) { try await tasks(["getTaskOptions": forbidden]).options() }
        await #expect(throws: APIError.unauthorized) { try await tasks(["getTaskOptions": unauthorized]).options() }
    }

    @Test func noAnswerIsUnreachable() async {
        let offline = YuvomiTasks(server: server, credential: "c", transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        var draft = TaskDraft()
        draft.title = "Call"
        await #expect(throws: APIError.unreachable) { try await offline.create(draft, parent: nil, idempotencyKey: "k") }
        await #expect(throws: APIError.unreachable) { try await offline.update(task: 27, TaskChanges(title: "x")) }
        await #expect(throws: APIError.unreachable) { try await offline.delete(task: 27) }
        await #expect(throws: APIError.unreachable) { try await offline.options() }
    }
}
