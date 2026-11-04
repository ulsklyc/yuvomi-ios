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
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
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
                if phase == .active { Task { await app.refreshReminders() } }
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
            // Die Mitteilung „Nicht abgehakt“ kommt mit den Aktionen an der Mitteilung (D3, D4).
            onNotCheckedOff: { _ in Self.log.notice("Abhaken vom Server abgelehnt") }
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
        // dürfen keine Mitteilungen des alten Kontos übrig bleiben.
        if session.current == nil { Task { await Self.clear(reminders) } }
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

/// Setzt den Delegate für Mitteilungen, bevor iOS den Start abschließt.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let presenter = ForegroundReminderPresenter()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        presenter.install()
        return true
    }
}
