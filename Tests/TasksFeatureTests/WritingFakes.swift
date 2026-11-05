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

/// Port-Fake für `/auth/me`.
struct FakePermissions: MemberPermissions {
    var result: Result<Bool, APIError> = .success(true)

    func mayWriteTasks() async throws(APIError) -> Bool { try result.get() }
}
