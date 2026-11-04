import Foundation
@testable import RemindersFeature
import Testing
import UserNotifications
import YuvomiCore

/// Seam 3: die Anfrage, die der Planer an iOS gibt. Ohne Notification Center.
@Suite(.serialized) struct NotificationRequestTests {
    /// 2099-03-29 01:30 UTC: in Berlin eine halbe Stunde nach der Umstellung auf Sommerzeit.
    /// Weit in der Zukunft, sonst gibt `nextTriggerDate()` irgendwann `nil`.
    let firesAt = Date(timeIntervalSince1970: 4_078_431_000)

    func planned(_ origin: ReminderOrigin = .task) -> PlannedNotification {
        PlannedNotification(id: "reminder.7.task.12", reminderID: 7, origin: origin, entityID: 12, title: "Strom zahlen", firesAt: firesAt)
    }

    @Test(arguments: ["Europe/Berlin", "America/Los_Angeles", "Asia/Kolkata", "UTC"])
    func firesAtTheSameMomentInEveryTimeZoneOfTheDevice(zone: String) throws {
        // Global für den Prozess. Die Suite läuft seriell, und die anderen Suiten dieses
        // Targets geben ihre Zeitzone nicht vor.
        let previous = NSTimeZone.default
        NSTimeZone.default = try #require(TimeZone(identifier: zone))
        defer { NSTimeZone.default = previous }

        let request = SystemNotificationScheduler.request(for: planned())

        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.nextTriggerDate() == firesAt)
        #expect(trigger.repeats == false)
        #expect(request.identifier == "reminder.7.task.12")
    }

    @Test func headingNamesTheOriginAndTheBodyTheTitle() {
        let german = Locale(identifier: "de")
        let task = SystemNotificationScheduler.request(for: planned(.task), locale: german).content
        let event = SystemNotificationScheduler.request(for: planned(.event), locale: german).content

        #expect(task.title == "Aufgabe")
        #expect(event.title == "Termin")
        #expect(task.body == "Strom zahlen")
        #expect(task.sound == .default)
    }
}
