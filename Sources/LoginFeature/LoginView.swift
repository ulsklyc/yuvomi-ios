import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Anmeldung in drei Schritten: Serveradresse, Passwort, bei Bedarf der Code.
public struct LoginView: View {
    @Bindable var model: LoginModel
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, code }

    public init(model: LoginModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                switch model.step {
                case .address: addressStep
                case .password(_, let appName): passwordStep(appName: appName)
                case .ssoOnly(let appName): ssoOnlyStep(appName: appName)
                case .code: codeStep
                }
            }
            .navigationTitle(Text("login.title", bundle: .module))
            .toolbar {
                if model.step != .address {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { model.back() } label: { Text("login.back", bundle: .module) }
                            .disabled(model.isWorking)
                    }
                }
            }
            .animation(.default, value: model.step)
        }
    }

    private var addressStep: some View {
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
    }

    private func passwordStep(appName: String) -> some View {
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
    }

    private func ssoOnlyStep(appName: String) -> some View {
        Section {
            Label { Text("login.ssoOnly.message", bundle: .module) } icon: { Image(systemName: "person.badge.key") }
        } header: {
            Text(verbatim: appName)
        }
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
        case .invalidCredentials: "login.problem.invalidCredentials"
        case .invalidCode: "login.problem.invalidCode"
        case .notAllowed: "login.problem.notAllowed"
        case .rateLimited: "login.problem.rateLimited"
        case .credentialNotStored: "login.problem.credentialNotStored"
        case .unexpectedResponse: "login.problem.unexpectedResponse"
        }
    }
}

#Preview("Fixtures") {
    let transport = FixtureTransport()
    let server = URL(string: "https://yuvomi.example.com")!
    LoginView(model: LoginModel(
        check: ServerCheck(probe: YuvomiServerProbe(transport: transport)),
        makeFlow: { _ in
            SignInFlow(
                server: server,
                gateway: YuvomiSignInGateway(server: server, device: DeviceInfo(name: "iPhone", deviceID: "preview"), transport: transport),
                store: InMemoryCredentialStore()
            )
        },
        onSignedIn: { _ in }
    ))
}
