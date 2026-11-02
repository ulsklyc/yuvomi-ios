import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Setzt `TaskReading` mit dem generierten Client um.
public struct YuvomiTasks: TaskReading {
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
}

extension APIError {
    /// Wie `ServerProbeError(classifying:)`: ohne Antwort nicht erreichbar, sonst unerwartet.
    /// Eine 401 bleibt eine 401, auch wenn sich ihr Body nicht lesen lässt: Sonst behielte
    /// die App ein widerrufenes Credential.
    init(classifying error: any Error) {
        switch (error as? ClientError)?.response?.status {
        case nil: self = .unreachable
        case .unauthorized: self = .unauthorized
        default: self = .unexpectedResponse
        }
    }
}

extension TaskSummary {
    init(_ item: Components.Schemas.TaskListItem) {
        let status: TaskStatus = switch item.status {
        case .open: .open
        case .inProgress: .inProgress
        case .done: .done
        }
        let priority: TaskPriority = switch item.priority {
        case .none: .none
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .urgent: .urgent
        }
        self.init(
            id: item.id,
            title: item.title,
            status: status,
            priority: priority,
            due: item.dueDate.flatMap(CalendarDay.init(iso:)),
            dueTime: item.dueTime,
            assignees: (item.assignedUsers ?? []).map(\.displayName)
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
