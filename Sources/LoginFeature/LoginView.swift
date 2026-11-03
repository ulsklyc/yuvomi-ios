import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Anmeldung: Serveradresse, dann Passwort und bei Bedarf der 2FA-Code, oder Kopplung per
/// Code, Link oder QR.
public struct LoginView: View {
    @Bindable var model: LoginModel
    let scanner: any QRCodeScanner
    @FocusState private var focus: Field?
    @State private var isScanning = false

    private enum Field { case address, username, password, code, pairingCode }

    public init(model: LoginModel, scanner: any QRCodeScanner = VisionKitScanner()) {
        self.model = model
        self.scanner = scanner
    }

    public var body: some View {
        NavigationStack {
            Form {
                switch model.step {
                case .address: addressStep
                case .password(_, let appName): passwordStep(appName: appName)
                case .pairing(_, let appName): pairingStep(appName: appName)
                case .confirmPairing(let server, let appName, _): confirmPairingStep(server: server, appName: appName)
                case .code: codeStep
                }
            }
            .navigationTitle(Text("login.title", bundle: .module))
            .toolbar {
                // Die Bestätigung hat ihr eigenes „Abbrechen“ neben „Anmelden“.
                if model.step != .address, !isConfirmingPairing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { model.back() } label: { Text("login.back", bundle: .module) }
                            .disabled(model.isWorking)
                    }
                }
            }
            .animation(.default, value: model.step)
            .sheet(isPresented: $isScanning) {
                ScannerSheet(scanner: scanner, model: model, isPresented: $isScanning)
            }
        }
    }

    private var isConfirmingPairing: Bool {
        if case .confirmPairing = model.step { true } else { false }
    }

    @ViewBuilder private var addressStep: some View {
        Section {
            TextField(text: $model.address, prompt: Text(verbatim: "yuvomi.example.com")) {
                Text("login.address.label", bundle: .module)
            }
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: .address)
            .submitLabel(.continue)
            .onSubmit { Task { await model.submitAddress() } }
            .onAppear { focus = .address }
            problem
            PrimaryButton(Text("login.address.continue", bundle: .module), isWorking: model.isWorking) {
                await model.submitAddress()
            }
        } header: {
            Text("login.address.header", bundle: .module)
        } footer: {
            Text("login.address.footer", bundle: .module)
        }
        if scanner.isAvailable {
            Section {
                scanButton
            } footer: {
                Text("login.address.scanFooter", bundle: .module)
            }
        }
    }

    private var scanButton: some View {
        Button { isScanning = true } label: {
            Label { Text("login.scan", bundle: .module) } icon: { Image(systemName: "qrcode.viewfinder") }
        }
        .disabled(model.isWorking)
    }

    @ViewBuilder private func passwordStep(appName: String) -> some View {
        Section {
            TextField(text: $model.username) { Text("login.username", bundle: .module) }
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .username)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .onAppear { focus = model.username.isEmpty ? .username : .password }
            SecureField(text: $model.password) { Text("login.password", bundle: .module) }
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { Task { await model.submitPassword() } }
            problem
            PrimaryButton(Text("login.signIn", bundle: .module), isWorking: model.isWorking) {
                await model.submitPassword()
            }
            .disabled(!model.canSubmitPassword)
        } header: {
            Text(verbatim: appName)
        }
        Section {
            Button { model.startPairing() } label: {
                Label { Text("login.password.usePairingCode", bundle: .module) } icon: { Image(systemName: "number") }
            }
            .disabled(model.isWorking)
        }
    }

    @ViewBuilder private func pairingStep(appName: String) -> some View {
        Section {
            TextField(text: $model.pairingCode, prompt: Text(verbatim: "ABCDE FGHJK")) {
                Text("login.pairing.code", bundle: .module)
            }
            .font(.body.monospaced())
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($focus, equals: .pairingCode)
            .submitLabel(.go)
            .onSubmit { Task { await model.submitPairingCode() } }
            .onAppear { focus = .pairingCode }
            // Gruppiert in Fünfern. Ein umformendes Binding übernimmt das Feld während der
            // Eingabe nicht, deshalb steht die Anzeige im Modell; normalisiert wird beim Einlösen.
            .onChange(of: model.pairingCode) { _, code in
                let grouped = PairingCode.grouped(code)
                if grouped != code { model.pairingCode = grouped }
            }
            problem
            PrimaryButton(Text("login.signIn", bundle: .module), isWorking: model.isWorking) {
                await model.submitPairingCode()
            }
            .disabled(!model.canSubmitPairingCode)
        } header: {
            Text(verbatim: appName)
        } footer: {
            Text("login.pairing.footer", bundle: .module)
        }
        if scanner.isAvailable {
            Section { scanButton }
        }
    }

    /// Link und QR: Erst nach dieser Bestätigung geht der Code an den Server, denn jede Seite
    /// kann einen `yuvomi://`-Link mit fremdem Server bauen.
    @ViewBuilder private func confirmPairingStep(server: URL, appName: String) -> some View {
        let isEncrypted = server.scheme == "https"
        Section {
            // Der Host zuerst: Den App-Namen bestimmt der Server, den man gerade bestätigt.
            // Er könnte mit Zeilenumbruch eine falsche Adresse vortäuschen, deshalb steht er
            // darunter, klein und einzeilig.
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.origin(server))
                    .font(.title2)
                    .textSelection(.enabled)
                Text(verbatim: Self.singleLine(appName))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            if isEncrypted {
                Label { Text("login.confirmPairing.encrypted", bundle: .module) } icon: { Image(systemName: "lock.fill") }
                    .foregroundStyle(.secondary)
            } else {
                // Orange nur am Schloss: Als Textfarbe reicht es auf Weiß nicht für 4,5:1.
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("login.confirmPairing.unencrypted", bundle: .module)
                            .fontWeight(.semibold)
                        Text("login.confirmPairing.unencrypted.detail", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.open.fill").foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("login.confirmPairing.header", bundle: .module)
        } footer: {
            Text("login.confirmPairing.footer", bundle: .module)
        }
        Section {
            problem
            PrimaryButton(Text("login.signIn", bundle: .module), isWorking: model.isWorking) {
                await model.confirmPairing()
            }
            Button(role: .cancel) { model.back() } label: {
                Text("login.cancel", bundle: .module).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.isWorking)
            .listRowSeparator(.hidden)
        }
    }

    /// Steuerzeichen und Zeilenumbrüche werden zu Leerzeichen.
    static func singleLine(_ text: String) -> String {
        String(text.unicodeScalars.map { CharacterSet.controlCharacters.union(.newlines).contains($0) ? " " : Character($0) })
    }

    /// Schema klein und grau, der Host groß: Auf den Host kommt es an, das Schema muss
    /// trotzdem zu sehen sein.
    static func origin(_ server: URL) -> AttributedString {
        var scheme = AttributedString("\(server.scheme ?? "")://")
        scheme.foregroundColor = .secondary
        var host = AttributedString(server.host() ?? server.absoluteString)
        host.font = .title2.bold()
        var origin = scheme + host
        if let port = server.port {
            var suffix = AttributedString(":\(port)")
            suffix.foregroundColor = .secondary
            origin += suffix
        }
        return origin
    }

    private var codeStep: some View {
        Section {
            TextField(text: $model.code) { Text("login.code", bundle: .module) }
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .code)
                .submitLabel(.go)
                .onSubmit { Task { await model.submitCode() } }
                .onAppear { focus = .code }
            problem
            PrimaryButton(Text("login.code.confirm", bundle: .module), isWorking: model.isWorking) {
                await model.submitCode()
            }
            .disabled(!model.canSubmitCode)
        } header: {
            Text("login.code.header", bundle: .module)
        } footer: {
            Text("login.code.footer", bundle: .module)
        }
    }

    @ViewBuilder private var problem: some View {
        if let problem = model.problem {
            ProblemLabel(Text(problem.message, bundle: .module))
        }
    }
}

extension LoginModel.Problem {
    var message: LocalizedStringKey {
        switch self {
        case .invalidAddress: "login.problem.invalidAddress"
        case .unreachable: "login.problem.unreachable"
        case .notYuvomi: "login.problem.notYuvomi"
        case .tooOld: "login.problem.tooOld"
        case .invalidPairingLink: "login.problem.invalidPairingLink"
        case .invalidCredentials: "login.problem.invalidCredentials"
        case .invalidCode: "login.problem.invalidCode"
        case .invalidPairingCode: "login.problem.invalidPairingCode"
        case .notAllowed: "login.problem.notAllowed"
        case .rateLimited: "login.problem.rateLimited"
        case .credentialNotStored: "login.problem.credentialNotStored"
        case .unexpectedResponse: "login.problem.unexpectedResponse"
        }
    }
}

/// Kamera im Blatt. Fremde QR-Codes beenden den Scan nicht, darunter steht dann ein Hinweis.
private struct ScannerSheet: View {
    let scanner: any QRCodeScanner
    let model: LoginModel
    @Binding var isPresented: Bool
    @State private var sawForeignCode = false
    @State private var isHandling = false
    /// `nil`, solange iOS fragt.
    @State private var hasCamera: Bool?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            camera
                .task { hasCamera = await scanner.requestAccess() }
                .navigationTitle(Text("login.scan", bundle: .module))
                .navigationBarTitleDisplayMode(.inline)
                // Läuft die Serverprüfung für einen gescannten Link, entscheidet ihre Antwort
                // den nächsten Schritt, wie bei einem Link von iOS. Abbrechen ginge erst danach.
                .interactiveDismissDisabled(isHandling)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { isPresented = false } label: { Text("login.cancel", bundle: .module) }
                            .disabled(isHandling)
                    }
                }
        }
    }

    @ViewBuilder private var camera: some View {
        switch hasCamera {
        case true?:
            scanner.makeView { text in handle(text) }
                .overlay(alignment: .bottom) { hint }
                .overlay { if isHandling { ProgressView().controlSize(.large) } }
        case false?:
            // Abgelehnt: Ohne diesen Zustand bliebe die Kamera schwarz und der Hinweis
            // verlangte trotzdem, sie auf den Code zu richten.
            ContentUnavailableView {
                Label { Text("login.scan.noCamera", bundle: .module) } icon: { Image(systemName: "video.slash") }
            } description: {
                Text("login.scan.noCamera.detail", bundle: .module)
            } actions: {
                Button {
                    if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                } label: {
                    Text("login.scan.openSettings", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        case nil:
            Color.clear
        }
    }

    private var hint: some View {
        Group {
            if sawForeignCode {
                Label { Text("login.scan.foreign", bundle: .module) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            } else {
                Text("login.scan.hint", bundle: .module)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .padding()
        .accessibilityElement(children: .combine)
    }

    /// Ein Kopplungslink schließt das Blatt, sobald der Server geprüft ist; was danach kommt,
    /// zeigt der Anmeldeschritt.
    private func handle(_ text: String) {
        guard !isHandling else { return }
        isHandling = true
        Task {
            if await model.openScannedCode(text) {
                isPresented = false
            } else {
                sawForeignCode = true
                AccessibilityNotification.Announcement(String(localized: "login.scan.foreign", bundle: .module)).post()
            }
            isHandling = false
        }
    }
}

/// Platzhalter für die Kamera, damit Vorschauen den Scan-Button zeigen.
private struct PreviewScanner: QRCodeScanner {
    var hasCamera = true
    var isAvailable: Bool { true }

    func requestAccess() async -> Bool { hasCamera }

    func makeView(onCode: @escaping @MainActor (String) -> Void) -> AnyView {
        AnyView(Image(systemName: "qrcode.viewfinder").font(.system(size: 120)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}

@MainActor private func previewModel() -> LoginModel {
    let transport = FixtureTransport()
    return LoginModel(
        check: ServerCheck(probe: YuvomiServerProbe(transport: transport)),
        makeFlow: { server in
            SignInFlow(
                server: server,
                gateway: YuvomiSignInGateway(server: server, device: DeviceInfo(name: "iPhone", deviceID: "preview"), transport: transport),
                store: InMemoryCredentialStore()
            )
        },
        makePairing: { server in
            PairingFlow(
                server: server,
                redeemer: YuvomiPairingRedeemer(server: server, device: DeviceInfo(name: "iPhone", deviceID: "preview"), transport: transport),
                store: InMemoryCredentialStore()
            )
        },
        onSignedIn: { _ in }
    )
}

#Preview("Fixtures") {
    LoginView(model: previewModel(), scanner: PreviewScanner())
}

#Preview("Code-Eingabe") {
    let model = previewModel()
    LoginView(model: model, scanner: PreviewScanner())
        .task {
            model.address = "yuvomi.example.com"
            await model.submitAddress()
            model.startPairing()
        }
}

#Preview("Bestätigung, https") {
    let model = previewModel()
    LoginView(model: model, scanner: PreviewScanner())
        .task { await model.openPairingLink(URL(string: "yuvomi://pair?server=https%3A%2F%2Fyuvomi.example.com&code=ACDEFGHJK3")!) }
}

#Preview("Bestätigung, http") {
    let model = previewModel()
    LoginView(model: model, scanner: PreviewScanner())
        .task { await model.openPairingLink(URL(string: "yuvomi://pair?server=http%3A%2F%2F192.168.1.20%3A3901&code=ACDEFGHJK3")!) }
}

#Preview("Scanner, Kamera abgelehnt") {
    ScannerSheet(scanner: PreviewScanner(hasCamera: false), model: previewModel(), isPresented: .constant(true))
}
