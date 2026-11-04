import Foundation
import Observation
import Testing
@testable import RemindersFeature

/// Port-Fake: die Erlaubnis für Mitteilungen, wie iOS sie hält.
final class FakePermission: NotificationPermission, @unchecked Sendable {
    var status: NotificationPermissionStatus
    /// Was die Person in der Frage von iOS antwortet.
    var answer: Bool
    private(set) var requests = 0

    init(_ status: NotificationPermissionStatus, answer: Bool = true) {
        self.status = status
        self.answer = answer
    }

    func current() async -> NotificationPermissionStatus { status }

    func request() async -> NotificationPermissionStatus {
        requests += 1
        // Die Antwort kommt nicht sofort, eine Reihenfolge zwischen Tasks garantiert das aber
        // nicht. Tests, die während der Frage tippen, nehmen `HeldPermission`.
        await Task.yield()
        status = answer ? .allowed : .denied
        return status
    }
}

/// Hält die Frage von iOS offen, bis der Test sie beantwortet. So tippt der Test sicher,
/// während iOS fragt, statt auf die Reihenfolge der Tasks zu hoffen.
actor HeldPermission: NotificationPermission {
    private(set) var requests = 0
    private var allowed = false
    private var answer: CheckedContinuation<Void, Never>?
    private var waitingForQuestion: [CheckedContinuation<Void, Never>] = []

    func current() -> NotificationPermissionStatus { .notDetermined }

    func request() async -> NotificationPermissionStatus {
        requests += 1
        // Nur die erste Frage bleibt offen. Fragt die App ein zweites Mal, antwortet der Fake
        // sofort: Der Test zählt die Fragen dann, statt zu hängen.
        guard requests == 1, !allowed else { return .allowed }
        waitingForQuestion.forEach { $0.resume() }
        waitingForQuestion = []
        await withCheckedContinuation { answer = $0 }
        return .allowed
    }

    /// Kehrt zurück, sobald die App iOS fragt.
    func untilAsked() async {
        guard requests == 0 else { return }
        await withCheckedContinuation { waitingForQuestion.append($0) }
    }

    /// Die Person erlaubt. Gilt auch, wenn die Frage erst danach kommt.
    func allow() {
        allowed = true
        answer?.resume()
        answer = nil
    }
}

@MainActor @Suite final class RemindersSettingsModelTests {
    /// Eigene Defaults je Test, damit nichts zwischen den Tests stehen bleibt.
    let suite = "RemindersSettingsModelTests.\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func model(_ permission: any NotificationPermission, onChange: @escaping @MainActor (Bool) -> Void = { _ in }) -> RemindersSettingsModel {
        RemindersSettingsModel(permission: permission, defaults: defaults, onChange: onChange)
    }

    @Test func theCardAsksAndTurnsRemindersOn() async {
        let permission = FakePermission(.notDetermined)
        var changes: [Bool] = []
        let settings = model(permission) { changes.append($0) }
        await settings.load()
        #expect(settings.showsCard)
        #expect(!settings.isOn)

        await settings.allowFromCard()

        #expect(permission.requests == 1)
        #expect(!settings.showsCard)
        #expect(settings.isOn)
        #expect(changes == [true])
    }

    @Test func notNowHidesTheCardForGoodWithoutAsking() async {
        let permission = FakePermission(.notDetermined)
        let settings = model(permission)
        await settings.load()

        settings.notNow()

        #expect(!settings.showsCard)
        let later = model(permission)
        await later.load()
        #expect(!later.showsCard)
        #expect(permission.requests == 0)
    }

    @Test func aRefusalInTheCardLeavesRemindersOff() async {
        let permission = FakePermission(.notDetermined, answer: false)
        var changes: [Bool] = []
        let settings = model(permission) { changes.append($0) }
        await settings.load()

        await settings.allowFromCard()

        #expect(!settings.showsCard)
        #expect(!settings.isOn)
        #expect(settings.permission == .denied)
        #expect(changes == [])
    }

    @Test func theSwitchTurnsRemindersOffAndOnAgain() async {
        var changes: [Bool] = []
        let settings = model(FakePermission(.allowed)) { changes.append($0) }
        await settings.load()
        #expect(settings.isOn)

        await settings.setOn(false)
        #expect(!settings.isOn)
        let later = model(FakePermission(.allowed))
        await later.load()
        #expect(!later.isOn, "der Wunsch bleibt gespeichert")

        await settings.setOn(true)
        #expect(settings.isOn)
        #expect(changes == [false, true])
    }

    /// Der Schalter zeichnet sich neu, wenn er umschaltet. Sonst stünde er nach „aus“ weiter auf
    /// „an“, obwohl die Erinnerungen schon abgeräumt sind.
    @Test func switchingOffIsObservable() async {
        let settings = model(FakePermission(.allowed))
        await settings.load()
        await confirmation { changed in
            withObservationTracking { _ = settings.isOn } onChange: { changed() }
            await settings.setOn(false)
        }
    }

    /// Nach einem Nein fragt iOS nicht noch einmal. Der Schalter bleibt aus, der Abschnitt
    /// zeigt den Weg in die Einstellungen von iOS.
    @Test func withoutPermissionTheSwitchStaysOff() async {
        let permission = FakePermission(.denied)
        var changes: [Bool] = []
        let settings = model(permission) { changes.append($0) }
        await settings.load()

        await settings.setOn(true)

        #expect(!settings.isOn)
        #expect(permission.requests == 0)
        #expect(changes == [])
    }

    /// Wer in den Einstellungen statt in der Karte gefragt wurde, sieht die Karte nicht mehr.
    @Test func askingFromTheSwitchAlsoRemovesTheCard() async {
        let settings = model(FakePermission(.notDetermined, answer: false))
        await settings.load()
        #expect(settings.showsCard)

        await settings.setOn(true)

        #expect(!settings.showsCard)
    }

    /// Das zweite Tippen wird abgewartet, bevor die Person antwortet: So landet es sicher
    /// während der Frage. Fragt das Modell gar nicht oder lässt es das zweite Tippen auf die
    /// Antwort warten, beendet `.timeLimit` den Test, statt ihn hängen zu lassen.
    @Test(.timeLimit(.minutes(1))) func tappingTwiceWhileIOSAsksAsksOnlyOnce() async {
        let permission = HeldPermission()
        var changes: [Bool] = []
        let settings = model(permission) { changes.append($0) }
        await settings.load()

        let first = Task { await settings.setOn(true) }
        await permission.untilAsked()
        await settings.setOn(true)
        await permission.allow()
        await first.value

        #expect(await permission.requests == 1)
        #expect(changes == [true])
    }
}
