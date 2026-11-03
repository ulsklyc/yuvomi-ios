import LoginFeature
import SwiftUI
import TasksFeature
import UIKit
import YuvomiAPI
import YuvomiCore

/// Kompositionswurzel: Hier treffen Kern und Adapter aufeinander.
@main
struct YuvomiApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if let session = app.session.current {
                    TaskListView(model: app.taskList(for: session), onSignOut: { await app.session.signOut() })
                        .id(session)
                } else {
                    LoginView(model: app.login())
                }
            }
            .animation(.default, value: app.session.current)
            .onOpenURL { url in Task { await app.open(url) } }
            .alert(Text("app.pairing.alreadySignedIn.title"), isPresented: $app.showsAlreadySignedIn) {
                Button("app.pairing.alreadySignedIn.ok", role: .cancel) {}
            } message: {
                Text("app.pairing.alreadySignedIn.message")
            }
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

    /// Die Serveradresse ist kein Geheimnis und liegt in den UserDefaults. Mit den Widgets
    /// wandert sie in die Defaults der App Group.
    private static let serverKey = "server"

    init() {
        session = SessionState(store: store, revoker: YuvomiSessionRevoker())
        if let server = UserDefaults.standard.url(forKey: Self.serverKey) {
            session.restore(server: server)
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
