import SwiftUI
import YuvomiCore

/// Was nach einem gescheiterten Schreiben über Liste oder Detail steht (Q13).
public enum TaskNotice: Hashable, Sendable {
    /// Keine Antwort: wie beim Neuladen.
    case unreachable
    /// 5xx oder sonst unerwartet: wie beim Neuladen.
    case unexpectedResponse
    /// 403: Die Person darf Aufgaben nur ansehen.
    case readOnly
    /// 404: gelöscht oder nicht mehr sichtbar.
    case gone
    /// 409 beim Ankreuzen: Die Beschreibung hat sich geändert, das Detail lädt neu.
    case changed
    /// 409 beim Anlegen: Derselbe Versuch läuft noch, gleich nochmal (Q14).
    case stillRunning
    /// 403 `task_locked`: Nur wer die Aufgabe angelegt hat, darf sie ändern (Q13).
    case locked

    /// Für die Fehler ohne eigene Folge. 401 behandelt der Aufrufer vorher.
    init(_ error: APIError) {
        switch error {
        case .unreachable: self = .unreachable
        case .forbidden: self = .readOnly
        case .notFound: self = .gone
        case .locked: self = .locked
        case .unauthorized, .conflict, .unexpectedResponse: self = .unexpectedResponse
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .unreachable: "tasks.problem.unreachable"
        case .unexpectedResponse: "tasks.problem.unexpectedResponse"
        case .readOnly: "tasks.notice.readOnly"
        case .gone: "tasks.notice.gone"
        case .changed: "tasks.notice.changed"
        case .stillRunning: "tasks.notice.stillRunning"
        case .locked: "tasks.notice.locked"
        }
    }
}
