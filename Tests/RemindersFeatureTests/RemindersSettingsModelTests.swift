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
        // Wie die Frage von iOS: Die Antwort kommt nicht sofort.
        await Task.yield()
        status = answer ? .allowed : .denied
        return status
    }
}

@MainActor @Suite final class RemindersSettingsModelTests {
    /// Eigene Defaults je Test, damit nichts zwischen den Tests stehen bleibt.
    let suite = "RemindersSettingsModelTests.\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func model(_ permission: FakePermission, onChange: @escaping @MainActor (Bool) -> Void = { _ in }) -> RemindersSettingsModel {
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

    @Test func tappingTwiceWhileIOSAsksAsksOnlyOnce() async {
        let permission = FakePermission(.notDetermined)
        var changes: [Bool] = []
        let settings = model(permission) { changes.append($0) }
        await settings.load()

        async let first: Void = settings.setOn(true)
        async let second: Void = settings.setOn(true)
        _ = await (first, second)

        #expect(permission.requests == 1)
        #expect(changes == [true])
    }
}
