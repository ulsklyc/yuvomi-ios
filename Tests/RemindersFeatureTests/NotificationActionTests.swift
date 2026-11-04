import Foundation
import ObjectiveC
@testable import RemindersFeature
import Testing
import UserNotifications
import YuvomiCore

/// Seam 4: Kategorien, Kategorie an der Anfrage und die Rückmeldung aus einer Aktion.
@Suite struct NotificationActionTests {
    let at = Date(timeIntervalSince1970: 1_793_707_200)
    let task = "reminder.7.task.12"
    let event = "reminder.8.event.30"

    @Test(arguments: [(ReminderOrigin.task, "reminder.task"), (.event, "reminder.event")])
    func theRequestCarriesTheCategoryOfItsOrigin(origin: ReminderOrigin, category: String) {
        let planned = PlannedNotification(id: "reminder.7.task.12", reminderID: 7, origin: origin, entityID: 12, title: "Strom zahlen", firesAt: .distantFuture)

        #expect(SystemNotificationScheduler.request(for: planned).content.categoryIdentifier == category)
    }

    /// Nur die Aufgabe hat einen Knopf, er verlangt das Entsperren und öffnet die App nicht.
    /// Beide melden das Wegwischen.
    @Test func onlyTheTaskCategoryHasMarkAsDone() throws {
        let categories = SystemNotificationScheduler.categories(locale: Locale(identifier: "de"))
        let task = try #require(categories.first { $0.identifier == "reminder.task" })
        let event = try #require(categories.first { $0.identifier == "reminder.event" })

        #expect(categories.count == 2)
        let action = try #require(task.actions.first)
        #expect(task.actions.count == 1)
        #expect(action.identifier == "reminder.checkOff")
        #expect(action.title == "Erledigt")
        #expect(action.options == [.authenticationRequired])
        #expect(event.actions.isEmpty)
        #expect(task.options.contains(.customDismissAction))
        #expect(event.options.contains(.customDismissAction))
    }

    @Test func theButtonIsEnglishInEnglish() throws {
        let categories = SystemNotificationScheduler.categories(locale: Locale(identifier: "en"))
        let task = try #require(categories.first { $0.identifier == "reminder.task" })

        #expect(task.actions.first?.title == "Mark as Done")
    }

    @Test(arguments: [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier])
    func tappingAndSwipingAwayDismiss(action: String) throws {
        let reply = try #require(ReminderReply(action: action, identifier: task, title: "Strom zahlen", at: at))

        #expect(reply == ReminderReply(kind: .dismiss, reminderID: 7, origin: .task, entityID: 12, title: "Strom zahlen", at: at))
    }

    @Test func markAsDoneChecksOffTheTask() throws {
        let reply = try #require(ReminderReply(action: "reminder.checkOff", identifier: task, title: "Strom zahlen", at: at))

        #expect(reply == ReminderReply(kind: .checkOff, reminderID: 7, origin: .task, entityID: 12, title: "Strom zahlen", at: at))
    }

    /// Ein Termin kennt kein „erledigt“, auch wenn die Aktion doch einmal ankommt.
    @Test func anEventIsNeverCheckedOff() {
        #expect(ReminderReply(action: "reminder.checkOff", identifier: event, title: "Filmabend", at: at) == nil)
        #expect(ReminderReply(action: UNNotificationDefaultActionIdentifier, identifier: event, title: "Filmabend", at: at)?.kind == .dismiss)
    }

    /// Fremde Mitteilungen, der Hinweis „Nicht abgehakt“, Kennungen aus Slice 3 und unbekannte
    /// Aktionen ergeben keine Rückmeldung.
    @Test(arguments: [
        ("reminder.7", UNNotificationDefaultActionIdentifier),
        ("reminder.notice.notCheckedOff.1", UNNotificationDefaultActionIdentifier),
        ("other.7.task.12", UNNotificationDefaultActionIdentifier),
        ("reminder.7.task.12", "reminder.unknown"),
    ])
    func otherNotificationsAndActionsAreIgnored(identifier: String, action: String) {
        #expect(ReminderReply(action: action, identifier: identifier, title: "x", at: at) == nil)
    }

    @Test(arguments: [
        ("de", "Nicht abgehakt", "Strom zahlen: Du darfst Aufgaben nur ansehen."),
        ("en", "Not marked as done", "Strom zahlen: You can only view tasks."),
    ])
    func theNoticeNamesTheTaskAndComesAtOnce(language: String, title: String, body: String) {
        let request = SystemNotificationScheduler.notCheckedOffRequest(title: "Strom zahlen", locale: Locale(identifier: language))

        #expect(request.content.title == title)
        #expect(request.content.body == body)
        #expect(request.trigger == nil)
        #expect(request.identifier.hasPrefix("reminder.notice.notCheckedOff."))
        #expect(ReminderSync.parse(request.identifier) == nil)
    }
}

/// iOS erfährt erst nach der Rückmeldung, dass die Aktion fertig ist, und zwar auf dem Main
/// Thread. Sonst beendet UIKit die App („Call must be made on main thread“).
///
/// Ruft `didReceive` über das Protokoll mit Completion Handler auf, so wie iOS es tut. Eine
/// `UNNotificationResponse` hat keinen öffentlichen Init, die Tests bauen sie über die
/// Fabrikmethoden der Klassen (nur im Test).
@MainActor @Suite struct NotificationDelegateTests {
    @MainActor final class Steps {
        var all: [String] = []
    }

    /// `UNUserNotificationCenter.current()` gibt es ohne Host-App nicht. Der Delegate liest
    /// `center` nie, ein Objekt ohne Init reicht.
    static let center = class_createInstance(UNUserNotificationCenter.self, 0) as! UNUserNotificationCenter

    static func response(identifier: String, action: String) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        content.body = "Strom zahlen"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        let notification = try #require(
            (UNNotification.self as AnyObject)
                .perform(NSSelectorFromString("notificationWithRequest:date:"), with: request, with: Date())?
                .takeUnretainedValue() as? UNNotification
        )
        return try #require(
            (UNNotificationResponse.self as AnyObject)
                .perform(NSSelectorFromString("responseWithNotification:actionIdentifier:"), with: notification, with: action)?
                .takeUnretainedValue() as? UNNotificationResponse
        )
    }

    @Test func iOSHearsBackOnTheMainThreadAfterTheReply() async throws {
        let steps = Steps()
        let delegate: UNUserNotificationCenterDelegate = ReminderNotificationDelegate { reply in
            await Task.yield()
            steps.all.append("reply \(reply.kind)")
        }
        let response = try Self.response(identifier: "reminder.7.task.12", action: "reminder.checkOff")

        let onMainThread = await withCheckedContinuation { finished in
            delegate.userNotificationCenter?(Self.center, didReceive: response) {
                finished.resume(returning: Thread.isMainThread)
            }
        }
        // Der Handler hat nicht gewartet, wenn die Rückmeldung danach noch fehlt.
        let repliedBefore = steps.all

        #expect(onMainThread)
        #expect(repliedBefore == ["reply checkOff"])
    }

    @Test func aForeignNotificationIsDoneAtOnce() throws {
        var done = false
        let delegate: UNUserNotificationCenterDelegate = ReminderNotificationDelegate { _ in
            Issue.record("Eine fremde Mitteilung ist keine Rückmeldung")
        }
        let response = try Self.response(identifier: "reminder.notice.notCheckedOff.1", action: UNNotificationDefaultActionIdentifier)

        delegate.userNotificationCenter?(Self.center, didReceive: response) { done = true }

        #expect(done)
    }
}
