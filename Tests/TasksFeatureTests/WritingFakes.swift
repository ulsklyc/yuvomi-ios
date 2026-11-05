import Foundation
import Synchronization
import YuvomiCore

/// Port-Fake fürs Schreiben: merkt sich jeden Aufruf und antwortet, was der Test einstellt.
/// Mit `hold()` wartet die nächste Anfrage, bis der Test `release()` ruft: So lässt sich
/// prüfen, was die App zeigt, während eine Anfrage läuft.
final class FakeWriter: TaskWriting, Sendable {
    let status = Mutex<Result<StatusChange, APIError>>(.success(StatusChange(status: .done)))
    let tick = Mutex<Result<String, APIError>>(.success(""))
    let calls = Mutex<[String]>([])
    private let gate = Mutex<(holding: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func setStatus(task id: Int, to status: TaskStatus) async throws(APIError) -> StatusChange {
        calls.withLock { $0.append("status \(id) \(status)") }
        await waitIfHeld()
        return try self.status.withLock { $0 }.get()
    }

    func tick(task id: Int, line: Int, checked: Bool, expect: String) async throws(APIError) -> String {
        calls.withLock { $0.append("tick \(id) \(line) \(checked) \(expect)") }
        await waitIfHeld()
        return try tick.withLock { $0 }.get()
    }

    func hold() {
        gate.withLock { $0.holding = true }
    }

    func release() {
        let waiting = gate.withLock { gate in
            gate.holding = false
            defer { gate.waiting = [] }
            return gate.waiting
        }
        waiting.forEach { $0.resume() }
    }

    /// Bis eine Anfrage am Tor wartet.
    func untilWaiting() async {
        while gate.withLock({ $0.waiting.isEmpty }) { await Task.yield() }
    }

    private func waitIfHeld() async {
        await withCheckedContinuation { continuation in
            let held = gate.withLock { gate in
                if gate.holding { gate.waiting.append(continuation) }
                return gate.holding
            }
            if !held { continuation.resume() }
        }
    }
}

/// Ein Tor für Fakes: Ist es zu, wartet jede Anfrage, bis der Test es öffnet. So lässt sich die
/// Reihenfolge zweier Antworten im Test festlegen.
final class Gate: Sendable {
    private let state = Mutex<(closed: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func close() { state.withLock { $0.closed = true } }

    func open() {
        let waiting = state.withLock { state in
            state.closed = false
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }

    func untilWaiting() async {
        while state.withLock({ $0.waiting.isEmpty }) { await Task.yield() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            let closed = state.withLock { state in
                if state.closed { state.waiting.append(continuation) }
                return state.closed
            }
            if !closed { continuation.resume() }
        }
    }
}

/// Port-Fake für `/auth/me`.
struct FakePermissions: MemberPermissions {
    var result: Result<Bool, APIError> = .success(true)

    func member() async throws(APIError) -> Member {
        Member(id: 1, mayWriteTasks: try result.get())
    }
}

/// Port-Fake fürs Anlegen, Ändern und Löschen. Merkt sich jeden Aufruf. Mit `gate.close()`
/// wartet `create`, bis der Test das Tor öffnet.
final class FakeEditor: TaskEditing, Sendable {
    static let household = TaskOptions(
        people: [TaskOptions.Person(id: 1, name: "Alex"), TaskOptions.Person(id: 3, name: "Emma")],
        categories: [
            TaskCategory(key: "household", name: nil, labelKey: "tasks.categoryHousehold"),
            TaskCategory(key: "misc", name: nil, labelKey: "tasks.categoryMisc"),
        ]
    )

    let options = Mutex<Result<TaskOptions, APIError>>(.success(household))
    let created = Mutex<Result<TaskSummary, APIError>>(.success(task(27)))
    /// Je `create` der Entwurf, der Elternteil und der Schlüssel.
    let creates = Mutex<[(draft: TaskDraft, parent: Int?, key: String)]>([])
    let gate = Gate()

    func options() async throws(APIError) -> TaskOptions {
        try options.withLock { $0 }.get()
    }

    func create(_ draft: TaskDraft, parent: Int?, idempotencyKey: String) async throws(APIError) -> TaskSummary {
        creates.withLock { $0.append((draft, parent, idempotencyKey)) }
        await gate.pass()
        return try created.withLock { $0 }.get()
    }

    func update(task id: Int, _ changes: TaskChanges) async throws(APIError) -> TaskDetail {
        throw .unexpectedResponse
    }

    func delete(task id: Int) async throws(APIError) {
        throw .unexpectedResponse
    }
}
