import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Setzt `ReminderWriting` mit dem generierten Client um: Erinnerung verwerfen und Aufgabe
/// abhaken. Beide Aufrufe sind am Server idempotent.
public struct YuvomiReminderWriting: ReminderWriting {
    let client: Client

    public init(server: URL, credential: String, transport: any ClientTransport = URLSessionTransport()) {
        client = Client(serverURL: server, transport: transport, middlewares: [BearerAuth(credential: credential)])
    }

    public func dismiss(reminder id: Int) async throws(APIError) {
        let output: Operations.DismissReminder.Output
        do {
            output = try await client.dismissReminder(path: .init(id: id))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok: return
        case .unauthorized: throw .unauthorized
        case .forbidden: throw .forbidden
        case .notFound: throw .notFound
        default: throw .unexpectedResponse
        }
    }

    /// Ohne `done_by_user_id`: Dann gilt die Regel der Zuständigen, wie beim Abhaken in der Web-App.
    public func checkOff(task id: Int) async throws(APIError) {
        let output: Operations.UpdateTaskStatus.Output
        do {
            output = try await client.updateTaskStatus(path: .init(id: id), body: .json(.init(status: .done)))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok: return
        case .unauthorized: throw .unauthorized
        case .forbidden: throw .forbidden
        case .notFound: throw .notFound
        default: throw .unexpectedResponse
        }
    }
}
