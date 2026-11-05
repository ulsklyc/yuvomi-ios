import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Liefert die Antworten aus `Fixtures/demo` statt eines Servers, wie ein MSW-Handler in JS.
///
/// Weil der generierte Client darüber läuft, prüft jede Vorschau und jeder Test auch das
/// Dekodieren echter `v2.84.0`-Antworten. Zugeordnet wird über die operationId.
public struct FixtureTransport: ClientTransport {
    /// Eine Antwort: Status und JSON-Body.
    public struct Response: Sendable {
        public var status: HTTPResponse.Status
        public var body: Data
        public var contentType: String

        public init(status: HTTPResponse.Status = .ok, body: Data, contentType: String = "application/json; charset=utf-8") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }

        /// Eine Datei aus `Fixtures/demo`, `name` ohne Endung.
        public static func fixture(_ name: String, status: HTTPResponse.Status = .ok) throws -> Response {
            Response(status: status, body: try Fixtures.data(name))
        }
    }

    /// Eine gesendete Anfrage, für Tests, die prüfen, was der Client verschickt.
    public struct Request: Sendable {
        public var operationID: String
        public var request: HTTPRequest
        public var body: Data?
    }

    public enum Failure: Error, CustomStringConvertible {
        case noFixture(operationID: String)

        public var description: String {
            switch self {
            case .noFixture(let id): "Keine Fixture für \(id). FixtureTransport.defaults ergänzen oder overrides setzen."
            }
        }
    }

    /// operationId -> Datei in `Fixtures/demo` und Erfolgsstatus.
    public static let defaults: [String: (file: String, status: HTTPResponse.Status)] = [
        "getVersion": ("version", .ok),
        "getSignInOptions": ("auth-oidc-config", .ok),
        "signInWithPassword": ("auth-login", .ok),
        "addSignedInDevice": ("auth-devices-create", .created),
        // Dasselbe Schema wie beim Ausstellen nach dem Login (SignedInDeviceCreateResponse).
        "redeemPairingCode": ("auth-devices-create", .created),
        "getCurrentUser": ("auth-me", .ok),
        "listSignedInDevices": ("auth-devices", .ok),
        "getDashboard": ("dashboard", .ok),
        "listTasks": ("tasks", .ok),
        "getTaskOptions": ("tasks-meta-options", .ok),
        "getTask": ("task", .ok),
        "createTask": ("task-created", .created),
        "updateTask": ("task-updated", .ok),
        "listShoppingLists": ("shopping-lists", .ok),
        "listShoppingListVersions": ("shopping-versions", .ok),
        "listShoppingSuggestions": ("shopping-suggestions", .ok),
        "listShoppingCategories": ("shopping-categories", .ok),
        "listShoppingItems": ("shopping-items", .ok),
        "listCalendarEvents": ("calendar", .ok),
        "listUpcomingCalendarEvents": ("calendar-upcoming", .ok),
        "listLocalCalendars": ("calendar-calendars", .ok),
        "getCalendarEvent": ("calendar-event", .ok),
        "listUpcomingReminders": ("reminders-upcoming", .ok),
        "listPendingReminders": ("reminders-pending", .ok),
    ]

    /// Weitere echte Antworten derselben Operation, die ein Test per `overrides` einsetzt:
    /// Datei in `Fixtures/demo` -> operationId.
    public static let variants: [String: String] = [
        // Aufgabe mit Checkliste und Unteraufgaben (Slice 5).
        "task-checklist": "getTask",
    ]

    private let overrides: [String: Response]
    private let recorder: Recorder?

    /// - Parameters:
    ///   - overrides: Antworten, die eine Fixture ersetzen oder ergänzen, etwa ein 401.
    ///   - recorder: Sammelt die gesendeten Anfragen, falls ein Test sie braucht.
    public init(overrides: [String: Response] = [:], recorder: Recorder? = nil) {
        self.overrides = overrides
        self.recorder = recorder
    }

    public func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if let recorder {
            let data: Data? = if let body { try await Data(collecting: body, upTo: 10 * 1024 * 1024) } else { nil }
            await recorder.record(Request(operationID: operationID, request: request, body: data))
        }

        let response: Response
        if let override = overrides[operationID] {
            response = override
        } else if let entry = Self.defaults[operationID] {
            response = try .fixture(entry.file, status: entry.status)
        } else {
            throw Failure.noFixture(operationID: operationID)
        }

        var fields = HTTPFields()
        fields[.contentType] = response.contentType
        return (HTTPResponse(status: response.status, headerFields: fields), HTTPBody(response.body))
    }

    /// Sammelt Anfragen über Nebenläufigkeitsgrenzen hinweg.
    public actor Recorder {
        public private(set) var requests: [Request] = []

        public init() {}

        func record(_ request: Request) {
            requests.append(request)
        }
    }
}
