import Foundation
import OpenAPIRuntime
import YuvomiCore

/// Anlegen, Ändern und Löschen (Slice 6). Fehler nach Q13: 403 trägt den `reason`, damit die
/// App eine gesperrte Aufgabe von fehlenden Rechten unterscheiden kann.
extension YuvomiTasks: TaskEditing {
    public func options() async throws(APIError) -> TaskOptions {
        let output: Operations.GetTaskOptions.Output
        do {
            output = try await client.getTaskOptions()
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let options) = ok.body else { throw .unexpectedResponse }
            return TaskOptions(
                people: options.users.map { TaskOptions.Person(id: $0.id, name: $0.displayName) },
                categories: options.categories.map { TaskCategory(key: $0.key, name: $0.name, labelKey: $0.labelKey) }
            )
        case .unauthorized: throw .unauthorized
        // Die Spec nennt kein 403, die Modul-Sperre schickt es bei `tasks: none` trotzdem.
        case .undocumented(statusCode: 403, _): throw .forbidden
        default: throw .unexpectedResponse
        }
    }

    public func create(_ draft: TaskDraft, parent: Int?, idempotencyKey: String) async throws(APIError) -> TaskSummary {
        let changes = draft.changes(from: TaskDraft())
        var input = TaskCreateInput(title: changes.title ?? draft.title)
        try input.apply(changes)
        if let parent { input.parentTaskId = .set(parent) }

        let output: Operations.CreateTask.Output
        do {
            output = try await client.createTask(
                headers: .init(idempotencyKey: idempotencyKey), body: .json(input)
            )
        } catch {
            // 409 heißt hier: Derselbe Schlüssel läuft noch oder kam schon mit anderem Body.
            throw APIError(classifying: error, conflict: true)
        }
        switch output {
        case .created(let created):
            guard case .json(let task) = created.body else { throw .unexpectedResponse }
            return TaskSummary(task.data)
        case .unauthorized: throw .unauthorized
        case .forbidden(let forbidden): throw APIError(forbidden: try? forbidden.body.json)
        case .notFound: throw .notFound
        case .conflict: throw .conflict
        default: throw .unexpectedResponse
        }
    }

    public func update(task id: Int, _ changes: TaskChanges) async throws(APIError) -> TaskDetail {
        var input = TaskUpdateInput(title: changes.title)
        try input.apply(changes)

        let output: Operations.UpdateTask.Output
        do {
            output = try await client.updateTask(path: .init(id: id), body: .json(input))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let updated) = ok.body else { throw .unexpectedResponse }
            return TaskDetail(updated.data)
        case .unauthorized: throw .unauthorized
        case .forbidden(let forbidden): throw APIError(forbidden: try? forbidden.body.json)
        case .notFound: throw .notFound
        default: throw .unexpectedResponse
        }
    }

    public func delete(task id: Int) async throws(APIError) {
        let output: Operations.DeleteTask.Output
        do {
            output = try await client.deleteTask(path: .init(id: id))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok: return
        case .unauthorized: throw .unauthorized
        case .forbidden(let forbidden): throw APIError(forbidden: try? forbidden.body.json)
        case .notFound: throw .notFound
        default: throw .unexpectedResponse
        }
    }
}

/// Die Felder des Formulars, gleich für Anlegen und Ändern.
protocol TaskFormInput {
    var category: String? { get set }
    var priority: String? { get set }
    var dueDate: Patch<String> { get set }
    var dueTime: Patch<String> { get set }
    var assignedTo: Patch<[Int]> { get set }
    var description: Patch<String> { get set }
}

extension TaskFormInput {
    mutating func apply(_ changes: TaskChanges) throws(APIError) {
        if let priority = changes.priority {
            // Eine Priorität, die die App nicht kennt, kann sie nicht setzen.
            guard let value = priority.server else { throw .unexpectedResponse }
            self.priority = value
        }
        category = changes.category
        dueDate = Patch(changes.due) { $0.iso }
        dueTime = Patch(changes.dueTime) { $0 }
        assignedTo = Patch(changes.assigneeIDs) { $0 }
        description = Patch(changes.description) { $0 }
    }
}

extension TaskCreateInput: TaskFormInput {}
extension TaskUpdateInput: TaskFormInput {}

extension APIError {
    /// 403 mit `reason: task_locked` ist die Sperre, jedes andere 403 fehlende Rechte
    /// (`module_read_only`, die Zahlungsaufgabe ohne Grund).
    init(forbidden body: Components.Schemas.ApiError?) {
        self = body?.reason == "task_locked" ? .locked : .forbidden
    }
}

extension Patch {
    init<Source>(_ change: Change<Source>, _ transform: (Source) -> Value) {
        switch change {
        case .keep: self = .unset
        case .clear: self = .clear
        case .set(let value): self = .set(transform(value))
        }
    }
}
