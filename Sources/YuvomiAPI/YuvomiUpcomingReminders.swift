import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import YuvomiCore

/// Setzt `UpcomingReminders` mit dem generierten Client um.
///
/// Fragt immer nur Aufgaben und Termine ab (`types=task,event`): Andere Herkünfte brächten
/// Gesundheits- und Finanztitel in ein Binary, das laut Apple-Anfrage solche Funktionen nicht hat.
public struct YuvomiUpcomingReminders: UpcomingReminders {
    let client: Client

    public init(server: URL, credential: String, transport: any ClientTransport = URLSessionTransport()) {
        client = Client(serverURL: server, transport: transport, middlewares: [BearerAuth(credential: credential)])
    }

    public func upcoming(from: Date, to: Date) async throws(APIError) -> [UpcomingReminder] {
        let output: Operations.ListUpcomingReminders.Output
        do {
            output = try await client.listUpcomingReminders(query: .init(from: from, to: to, types: [.task, .event]))
        } catch {
            throw APIError(classifying: error)
        }
        switch output {
        case .ok(let ok):
            guard case .json(let list) = ok.body else { throw .unexpectedResponse }
            return list.data.map(UpcomingReminder.init)
        case .unauthorized:
            throw .unauthorized
        default:
            throw .unexpectedResponse
        }
    }
}

extension UpcomingReminder {
    /// Jede andere Herkunft als Aufgabe und Termin wird `.unknown` und verliert ihren Titel,
    /// auch wenn der Server sie doch schickt: Ein Gesundheits- oder Finanztitel soll nicht aufs
    /// Telefon. Geplant wird sie trotzdem, mit einem allgemeinen Text.
    init(_ row: Components.Schemas.UpcomingReminder) {
        let origin: ReminderOrigin = switch row.entityType {
        case "task": .task
        case "event": .event
        default: .unknown
        }
        let title = origin == .unknown ? "" : row.entityTitle ?? ""
        self.init(id: row.id, origin: origin, entityID: row.entityId, title: title, firesAt: row.firesAt)
    }
}
