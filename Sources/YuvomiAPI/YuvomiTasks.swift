import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Setzt `TaskReading` und `TaskWriting` mit dem generierten Client um.
public struct YuvomiTasks: TaskReading, TaskWriting {
    let client: Client

    public init(server: URL, credential: String, transport: any ClientTransport = URLSessionTransport()) {
        client = Client(serverURL: server, transport: transport, middlewares: [BearerAuth(credential: credential)])
    }

    public func tasks() async throws(APIError) -> [TaskSummary] {
        let output: Operations.ListTasks.Output
        do {
            output = try await client.listTasks()
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let list) = ok.body else { throw .unexpectedResponse }
            return list.data.map(TaskSummary.init)
        case .unauthorized:
            throw .unauthorized
        default:
            throw .unexpectedResponse
        }
    }

    public func task(id: Int) async throws(APIError) -> TaskDetail {
        let output: Operations.GetTask.Output
        do {
            output = try await client.getTask(path: .init(id: id))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let detail) = ok.body else { throw .unexpectedResponse }
            return TaskDetail(detail.data)
        case .unauthorized: throw .unauthorized
        case .notFound: throw .notFound
        default: throw .unexpectedResponse
        }
    }

    /// Ohne `done_by_user_id`: Dann gilt die Regel der Zuständigen, wie beim Abhaken in der Web-App.
    public func setStatus(task id: Int, to status: TaskStatus) async throws(APIError) -> StatusChange {
        let payload: Components.Schemas.TaskStatusInput.StatusPayload = switch status {
        case .open: .open
        case .inProgress: .inProgress
        case .done: .done
        // Einen Status, den die App nicht kennt, kann sie nicht setzen.
        case .unknown: throw .unexpectedResponse
        }
        let output: Operations.UpdateTaskStatus.Output
        do {
            output = try await client.updateTaskStatus(path: .init(id: id), body: .json(.init(status: payload)))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let changed) = ok.body else { throw .unexpectedResponse }
            return StatusChange(
                status: TaskStatus(server: changed.data.status),
                nextDue: changed.data.nextDueDate.flatMap(CalendarDay.init(iso:))
            )
        case .unauthorized: throw .unauthorized
        case .forbidden: throw .forbidden
        case .notFound: throw .notFound
        default: throw .unexpectedResponse
        }
    }

    public func tick(task id: Int, line: Int, checked: Bool, expect: String) async throws(APIError) -> String {
        let output: Operations.CheckTaskItem.Output
        do {
            output = try await client.checkTaskItem(
                path: .init(id: id), body: .json(.init(line: line, checked: checked, expect: expect))
            )
        } catch {
            // Ein 409 ohne lesbaren Body ist hier trotzdem der Konflikt um die Zeile.
            throw APIError(classifying: error, conflict: true)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let ticked) = ok.body else { throw .unexpectedResponse }
            return ticked.data.description
        case .unauthorized: throw .unauthorized
        case .notFound: throw .notFound
        case .conflict: throw .conflict
        // Die Spec nennt hier kein 403, die Modul-Sperre des Servers schickt es bei
        // `tasks: read` trotzdem (`module_read_only`).
        case .undocumented(statusCode: 403, _): throw .forbidden
        default: throw .unexpectedResponse
        }
    }
}

/// Setzt `MemberPermissions` mit `GET /auth/me` um.
public struct YuvomiMemberPermissions: MemberPermissions {
    let client: Client

    public init(server: URL, credential: String, transport: any ClientTransport = URLSessionTransport()) {
        client = Client(serverURL: server, transport: transport, middlewares: [BearerAuth(credential: credential)])
    }

    /// Nur `write` erlaubt Schreiben. Ein Wert, den diese App-Version nicht kennt, gilt als
    /// nicht erlaubt: Der Server prüft ohnehin, und ein Haken, der zurückspringt, ist das
    /// kleinere Übel als einer, den es nicht gibt.
    public func member() async throws(APIError) -> Member {
        let output: Operations.GetCurrentUser.Output
        do {
            output = try await client.getCurrentUser()
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let me) = ok.body else { throw .unexpectedResponse }
            return Member(
                id: me.user.id,
                mayWriteTasks: me.permissions.modules.additionalProperties["tasks"] == "write",
                householdSize: me.householdSize
            )
        case .unauthorized: throw .unauthorized
        default: throw .unexpectedResponse
        }
    }
}

extension APIError {
    /// Wie `ServerProbeError(classifying:)`: ohne Antwort nicht erreichbar, sonst unerwartet.
    /// Eine 401 bleibt eine 401, auch wenn sich ihr Body nicht lesen lässt: Sonst behielte
    /// die App ein widerrufenes Credential. Ebenso 403 und 404: Beide sind endgültig, ein
    /// zweiter Versuch brächte nichts.
    ///
    /// 409 nur mit `conflict`: Für die Operationen, die es dokumentieren (Ankreuzen, Anlegen).
    init(classifying error: any Error, conflict: Bool = false) {
        switch (error as? ClientError)?.response?.status {
        case nil: self = .unreachable
        case .unauthorized: self = .unauthorized
        case .forbidden: self = .forbidden
        case .notFound: self = .notFound
        case .conflict where conflict: self = .conflict
        default: self = .unexpectedResponse
        }
    }
}

// In Antworten sind Enums seit scripts/prune-spec.mjs einfache Strings. Ein Wert, den diese
// App-Version nicht kennt, wird `.unknown`, statt die ganze Antwort zu kippen.
extension TaskStatus {
    init(server value: String) {
        self = switch value {
        case "open": .open
        case "in_progress": .inProgress
        case "done": .done
        default: .unknown
        }
    }
}

extension TaskPriority {
    init(server value: String) {
        self = switch value {
        case "none": .none
        case "low": .low
        case "medium": .medium
        case "high": .high
        case "urgent": .urgent
        default: .unknown
        }
    }

    /// Der Wert für den Server, `nil` bei `.unknown`: Den kann die App nicht setzen.
    var server: String? {
        switch self {
        case .none: "none"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .urgent: "urgent"
        case .unknown: nil
        }
    }
}

extension TaskSummary {
    init(_ item: Components.Schemas.TaskListItem) {
        self.init(
            id: item.id,
            title: item.title,
            status: TaskStatus(server: item.status),
            priority: TaskPriority(server: item.priority),
            due: item.dueDate.flatMap(CalendarDay.init(iso:)),
            dueTime: item.dueTime,
            assignees: (item.assignedUsers ?? []).map(\.displayName),
            subtasks: SubtaskProgress(done: item.subtaskDone, total: item.subtaskTotal)
        )
    }

    /// Eine Unteraufgabe aus `subtasks` des Details.
    init(_ task: Components.Schemas.Task) {
        self.init(
            id: task.id,
            title: task.title,
            status: TaskStatus(server: task.status),
            priority: TaskPriority(server: task.priority),
            due: task.dueDate.flatMap(CalendarDay.init(iso:)),
            dueTime: task.dueTime,
            assignees: task.assignedUsers.map(\.displayName)
        )
    }
}

/// Die Felder, die `TaskDetail` liest. Das Detail (`GET`) und die Antwort von `PUT` haben sie
/// gleich, die Antwort von `PUT` nur ohne Dokumente.
protocol TaskDetailFields {
    var id: Int { get }
    var title: String { get }
    var status: String { get }
    var priority: String { get }
    var startDate: String? { get }
    var dueDate: String? { get }
    var dueTime: String? { get }
    var assignedUsers: [Components.Schemas.AssignedPerson] { get }
    var description: String? { get }
    var subtasks: [Components.Schemas.Task] { get }
    var tags: [String] { get }
    var points: Int { get }
    var isRecurring: Int { get }
    var locked: Int { get }
    var category: String { get }
    var createdBy: Int { get }
}

extension Components.Schemas.TaskDetail: TaskDetailFields {}
extension Components.Schemas.TaskUpdated: TaskDetailFields {}

extension TaskDetail {
    init(_ task: some TaskDetailFields) {
        self.init(
            id: task.id,
            title: task.title,
            status: TaskStatus(server: task.status),
            priority: TaskPriority(server: task.priority),
            start: task.startDate.flatMap(CalendarDay.init(iso:)),
            due: task.dueDate.flatMap(CalendarDay.init(iso:)),
            dueTime: task.dueTime,
            assignees: task.assignedUsers.map(\.displayName),
            assigneeIDs: task.assignedUsers.map(\.id),
            description: task.description,
            subtasks: task.subtasks.map(TaskSummary.init),
            tags: task.tags,
            points: task.points,
            isRecurring: task.isRecurring != 0,
            isLocked: task.locked != 0,
            category: task.category,
            createdBy: task.createdBy
        )
    }
}

/// Hängt das Device Credential an jede Anfrage.
struct BearerAuth: ClientMiddleware {
    let credential: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(credential)"
        return try await next(request, body, baseURL)
    }
}
