import BackgroundTasks
import LoginFeature
import os
import RemindersFeature
import SwiftUI
import TasksFeature
import UIKit
import YuvomiAPI
import YuvomiCore

/// Kompositionswurzel: Hier treffen Kern und Adapter aufeinander.
@main
struct YuvomiApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = app.session.current {
                    TaskListView(model: app.taskList(for: session), onOpenSettings: { app.showsSettings = true }) {
                        ReminderCard(model: app.reminderSettings)
                    }
                    // Nach der Anmeldung und beim Start mit gespeicherter Anmeldung.
                    .task { await app.refreshReminders() }
                    .sheet(isPresented: $app.showsSettings) {
                        SettingsView(session: session, reminders: app.reminderSettings, onSignOut: { await app.session.signOut() })
                    }
                    .id(session)
                } else {
                    LoginView(model: app.login())
                }
            }
            .animation(.default, value: app.session.current)
            // Endet die Sitzung bei offenem Blatt (Widerruf), darf es nach der nächsten
            // Anmeldung nicht von selbst wieder aufgehen.
            .onChange(of: app.session.current) { _, current in
                app.showsSettings = false
                // Abmelden und Widerruf: keine Mitteilung von Yuvomi bleibt zurück.
                if current == nil { Task { await app.clearReminders() } }
            }
            // Zurück in den Vordergrund, auch aus den Einstellungen von iOS: Erlaubnis neu
            // lesen und abgleichen.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    app.becameActive()
                    Task { await app.refreshReminders() }
                }
                if phase == .background { Task { await app.scheduleBackgroundRefresh() } }
            }
            .onOpenURL { url in Task { await app.open(url) } }
            .alert(Text("app.pairing.alreadySignedIn.title"), isPresented: $app.showsAlreadySignedIn) {
                Button("app.pairing.alreadySignedIn.ok", role: .cancel) {}
            } message: {
                Text("app.pairing.alreadySignedIn.message")
            }
        }
        // Weckt iOS die App, gleicht sie ab und meldet sich für das nächste Mal an.
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) {
            await app.backgroundRefresh()
        }
    }
}

/// Hält die langlebigen Teile und baut die Screen-Modelle.
@MainActor @Observable
final class AppModel {
    let session: SessionState
    private let store = KeychainCredentialStore(accessGroup: KeychainCredentialStore.sharedAccessGroup)
    private var loginModel: LoginModel?
    private var taskListModel: (session: Session, model: TaskListModel)?
    /// Ein Kopplungslink kam, während schon jemand angemeldet ist (Q3).
    var showsAlreadySignedIn = false
    var showsSettings = false
    /// Der eine Besitzer des Abgleichs: Abgleichen und Abräumen laufen nacheinander.
    let reminders: ReminderCoordinator
    /// Karte und Schalter für Erinnerungen. Gilt für das Gerät, nicht für das Konto.
    let reminderSettings: RemindersSettingsModel
    /// Delegate für Mitteilungen. Das Center hält ihn nur schwach.
    private var notifications: ReminderNotificationDelegate?
    /// Im Hintergrund abgehakt: Die offene Liste lädt beim nächsten Wechsel in den Vordergrund.
    private var listIsStale = false

    /// Die Serveradresse ist kein Geheimnis und liegt in den UserDefaults. Mit den Widgets
    /// wandert sie in die Defaults der App Group.
    private static let serverKey = "server"
    nonisolated static let refreshTaskID = "cloud.yuvomi.ios.reminders"

    init() {
        let session = SessionState(store: store, revoker: YuvomiSessionRevoker())
        self.session = session
        if let server = UserDefaults.standard.url(forKey: Self.serverKey) {
            session.restore(server: server)
        }
        let reminders = ReminderCoordinator(
            makeSource: { YuvomiUpcomingReminders(server: $0.server, credential: $0.credential) },
            makeWriter: { YuvomiReminderWriting(server: $0.server, credential: $0.credential) },
            scheduler: SystemNotificationScheduler(),
            queue: UserDefaultsReplyQueue(),
            onUnauthorized: { session.handle(.unauthorized, from: $0) },
            onNotCheckedOff: { await SystemNotificationScheduler().announceNotCheckedOff(title: $0.title) }
        )
        self.reminders = reminders
        reminderSettings = RemindersSettingsModel(permission: SystemNotificationPermission()) { on in
            Task {
                if !on {
                    await Self.clear(reminders, keepingReplies: true)
                } else if let current = session.current {
                    await reminders.sync(current)
                }
            }
        }
        // Wurde die Sitzung beendet, während die App nicht lief (Widerruf im Hintergrund),
        // dürfen keine Mitteilungen des alten Kontos übrig bleiben. Nicht aber vor dem ersten
        // Entsperren: Dann ist nur der Keychain nicht lesbar, und eine Rückmeldung von der
        // gesperrten Mitteilungszentrale hat die App gestartet.
        if session.current == nil, UIApplication.shared.isProtectedDataAvailable {
            Task { await Self.clear(reminders) }
        }
        // Kategorien und Delegate vor dem Ende von `didFinishLaunching`: Das Modell entsteht mit
        // der App, und iOS meldet Antippen, Wegwischen und „Erledigt“ erst danach.
        SystemNotificationScheduler.registerCategories()
        let notifications = ReminderNotificationDelegate { [weak self] in await self?.reply($0) }
        notifications.install()
        self.notifications = notifications
    }

    /// Zurück im Vordergrund. Hat der Start vor dem ersten Entsperren den Keychain nicht lesen
    /// können, holt die App die Anmeldung jetzt nach. Und eine im Hintergrund abgehakte Aufgabe
    /// verschwindet aus der Liste.
    func becameActive() {
        if session.current == nil, let server = UserDefaults.standard.url(forKey: Self.serverKey) {
            session.restore(server: server)
        }
        if listIsStale, let current = session.current, let taskListModel, taskListModel.session == current {
            listIsStale = false
            Task { await taskListModel.model.load() }
        }
    }

    /// Erlaubnis neu lesen, dann abgleichen oder abräumen. Ohne Erlaubnis oder mit
    /// ausgeschaltetem Schalter bleibt nichts geplant.
    func refreshReminders() async {
        guard let current = session.current else { return }
        await reminderSettings.load()
        // Abgemeldet, während die Erlaubnis gelesen wurde: Das Abmelden hat schon abgeräumt.
        guard session.current == current else { return }
        // Hat iOS den Hintergrund-Task schon beendet, gibt es noch keinen Abgleich zum
        // Abbrechen. Ein später gemeldeter bricht `cancelRunning()` ab.
        guard !Task.isCancelled else { return }
        if reminderSettings.isOn {
            await reminders.sync(current)
        } else {
            // Ohne Mitteilungen, aber was jemand schon getan hat, geht trotzdem raus.
            await Self.clear(reminders, keepingReplies: true)
            // Abgemeldet, während abgeräumt wurde: Die Warteschlange gehört nicht mehr diesem Konto.
            guard session.current == current else { return }
            await reminders.sendReplies(current)
        }
    }

    /// Abmelden und Widerruf: alles abräumen, auch den angemeldeten Hintergrund-Task.
    func clearReminders() async {
        await Self.clear(reminders)
    }

    private static func clear(_ reminders: ReminderCoordinator, keepingReplies: Bool = false) async {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
        await reminders.clear(keepingReplies: keepingReplies)
    }

    /// Frühestens in vier Stunden. Wann iOS die App wirklich weckt, entscheidet iOS.
    /// Erst nach `load()` aufrufen, sonst gilt die Erlaubnis noch als nicht erteilt.
    func scheduleBackgroundRefresh() async {
        guard session.current != nil, reminderSettings.isOn else { return }
        do {
            try await Self.submitRefresh(at: .now.addingTimeInterval(4 * 3600))
        } catch {
            // Etwa Hintergrundaktualisierung aus: Es fehlt nur der Abgleich im Hintergrund.
            Self.log.error("Hintergrund-Abgleich nicht angemeldet: \(error.localizedDescription, privacy: .public)")
        }
        // Abgemeldet oder ausgeschaltet, während die Anmeldung lief: Das `cancel` aus
        // `clear` kam dann vor ihr an und hätte sie nicht erfasst.
        if session.current == nil || !reminderSettings.isOn {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskID)
        }
    }

    /// Nicht auf dem Main Thread, so verlangt es `BGTaskScheduler`.
    @concurrent private nonisolated static func submitRefresh(at date: Date) async throws {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = date
        try await BGTaskScheduler.shared.submitTaskRequest(request)
    }

    private static let log = Logger(subsystem: "cloud.yuvomi.ios", category: "reminders")

    /// Nimmt iOS dem Task die Zeit, bricht das den Abgleich ab, statt auf ihn zu warten.
    func backgroundRefresh() async {
        let reminders = reminders
        await withTaskCancellationHandler {
            await refreshReminders()
        } onCancel: {
            Task { @MainActor in reminders.cancelRunning() }
        }
        await scheduleBackgroundRefresh()
    }

    /// Antippen, Wegwischen oder „Erledigt“ an einer Mitteilung. Läuft oft, während die App im
    /// Hintergrund ist: Die Zeit dafür holt `beginBackgroundTask`, und läuft sie ab, bleibt die
    /// Rückmeldung für den nächsten Abgleich gemerkt.
    func reply(_ reply: ReminderReply) async {
        let application = UIApplication.shared
        let background = BackgroundTask()
        let reminders = reminders
        background.id = application.beginBackgroundTask(withName: "reminders.reply") {
            reminders.cancelRunning()
            background.end()
        }
        let current = session.current
        await reminders.reply(reply, session: current)
        background.end()
        // Ist die Liste offen, zeigt sie die abgehakte Aufgabe nicht mehr. Im Hintergrund erst
        // beim nächsten Wechsel in den Vordergrund.
        guard reply.kind == .checkOff else { return }
        if application.applicationState == .active, let current, let taskListModel, taskListModel.session == current {
            await taskListModel.model.load()
        } else {
            listIsStale = true
        }
    }

    func login() -> LoginModel {
        if let loginModel { return loginModel }
        let store = store
        let model = LoginModel(
            check: ServerCheck(probe: YuvomiServerProbe()),
            makeFlow: { server in
                SignInFlow(server: server, gateway: YuvomiSignInGateway(server: server, device: Self.device), store: store)
            },
            makePairing: { server in
                PairingFlow(server: server, redeemer: YuvomiPairingRedeemer(server: server, device: Self.device), store: store)
            },
            onSignedIn: { [weak self] session in
                UserDefaults.standard.set(session.server, forKey: Self.serverKey)
                self?.loginModel = nil
                self?.session.signedIn(session)
            }
        )
        // Nach dem Abmelden steht die letzte Adresse schon im Feld.
        model.address = UserDefaults.standard.url(forKey: Self.serverKey)?.absoluteString ?? ""
        loginModel = model
        return model
    }

    /// Links von iOS: `yuvomi://pair` aus der Web-App oder von der Kamera-App.
    func open(_ url: URL) async {
        switch IncomingLink(url: url, current: session.current) {
        case .pairing(let url): await login().openPairingLink(url)
        case .refusedWhileSignedIn: showsAlreadySignedIn = true
        }
    }

    func taskList(for session: Session) -> TaskListModel {
        if let taskListModel, taskListModel.session == session { return taskListModel.model }
        let model = TaskListModel(
            tasks: YuvomiTasks(server: session.server, credential: session.credential),
            today: { CalendarDay(Date.now) },
            onUnauthorized: { [weak self] in self?.session.handle(.unauthorized, from: session) }
        )
        taskListModel = (session, model)
        return model
    }

    /// Name „iPhone“ und `identifierForVendor`, entschieden in A4.
    private static var device: DeviceInfo {
        DeviceInfo(name: "iPhone", deviceID: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
    }
}

/// Hält die Kennung aus `beginBackgroundTask` und beendet sie genau einmal: am Ende der
/// Rückmeldung oder, wenn iOS die Zeit nimmt, im Ablauf-Handler.
@MainActor private final class BackgroundTask {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
