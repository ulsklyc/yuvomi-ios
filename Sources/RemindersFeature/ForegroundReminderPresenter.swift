@preconcurrency import UserNotifications

/// Zeigt Erinnerungen auch bei offener App als Banner mit Ton. Ohne Delegate schluckt iOS sie
/// im Vordergrund still. Antippen öffnet nur die App, dafür braucht es kein `didReceive`.
///
/// Ohne Zustand und deshalb `Sendable`. Die Methode ist `nonisolated`: Ein `@MainActor`-Delegate
/// mit async-Methode baut unter Swift 6 nicht, weil die UN-Typen nicht `Sendable` sind.
public final class ForegroundReminderPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    override public init() {}

    /// Muss vor dem Ende von `didFinishLaunching` passieren. Das Center hält den Delegate nur
    /// schwach, der Aufrufer muss ihn festhalten.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
