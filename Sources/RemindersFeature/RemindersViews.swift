import SwiftUI
import UIKit

/// Einmal über der Aufgabenliste, bevor iOS nach Mitteilungen gefragt hat. Erst der Knopf
/// löst die Frage aus.
public struct ReminderCard: View {
    let model: RemindersSettingsModel

    public init(model: RemindersSettingsModel) {
        self.model = model
    }

    public var body: some View {
        if model.showsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("reminders.card.title", bundle: .module).font(.headline)
                } icon: {
                    Image(systemName: "bell.badge")
                }
                Text("reminders.card.message", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // Nebeneinander, solange es passt. Bei großer Schrift untereinander statt gequetscht.
                ViewThatFits(in: .horizontal) {
                    HStack { buttons }
                    VStack(alignment: .leading) { buttons }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button { Task { await model.allowFromCard() } } label: {
            Text("reminders.card.allow", bundle: .module)
        }
        .buttonStyle(.borderedProminent)
        Button { model.notNow() } label: {
            Text("reminders.card.notNow", bundle: .module)
        }
        .buttonStyle(.bordered)
    }
}

/// Abschnitt „Erinnerungen“ im Blatt „Einstellungen“.
public struct RemindersSettingsSection: View {
    let model: RemindersSettingsModel
    @Environment(\.openURL) private var openURL

    public init(model: RemindersSettingsModel) {
        self.model = model
    }

    public var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isOn }, set: { on in
                if on { Task { await model.setOn(true) } } else { model.switchOff() }
            })) {
                Text("reminders.toggle", bundle: .module)
            }
            .disabled(model.permission == .denied || model.isAsking)
            if model.permission == .denied {
                Text("reminders.denied", bundle: .module)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                } label: {
                    Text("reminders.openSettings", bundle: .module)
                }
            }
        } header: {
            Text("reminders.section.title", bundle: .module)
        } footer: {
            Text("reminders.footer", bundle: .module)
        }
        .task { await model.load() }
    }
}

/// Für die Vorschauen: Erlaubnis in festem Zustand.
struct PreviewPermission: NotificationPermission {
    let status: NotificationPermissionStatus
    func current() async -> NotificationPermissionStatus { status }
    func request() async -> NotificationPermissionStatus { .allowed }
}

/// Frische Defaults je Vorschau: Ein Tippen auf „Nicht jetzt“ soll die nächste nicht leeren.
@MainActor private func previewModel(_ status: NotificationPermissionStatus) -> RemindersSettingsModel {
    RemindersSettingsModel(
        permission: PreviewPermission(status: status),
        defaults: UserDefaults(suiteName: "preview.\(UUID())")!,
        onChange: { _ in }
    )
}

#Preview("Karte") {
    let model = previewModel(.notDetermined)
    List { ReminderCard(model: model) }
        .task { await model.load() }
}

#Preview("Einstellungen, erlaubt") {
    Form { RemindersSettingsSection(model: previewModel(.allowed)) }
}

#Preview("Einstellungen, abgelehnt") {
    Form { RemindersSettingsSection(model: previewModel(.denied)) }
}
