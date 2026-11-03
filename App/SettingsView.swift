import RemindersFeature
import SwiftUI
import YuvomiCore

/// Blatt „Einstellungen“: Erinnerungen und Konto. Die App setzt es zusammen, weil es Teile
/// aus mehreren Modulen zeigt.
struct SettingsView: View {
    let session: Session
    let reminders: RemindersSettingsModel
    let onSignOut: () async -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                RemindersSettingsSection(model: reminders)
                Section {
                    LabeledContent {
                        // Ganze Adresse mit Schema und Port, wie in der Bestätigung beim Koppeln.
                        Text(verbatim: session.server.absoluteString)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } label: {
                        Text("app.settings.server")
                    }
                    Button(role: .destructive) {
                        Task {
                            dismiss()
                            await onSignOut()
                        }
                    } label: {
                        Text("app.settings.signOut")
                    }
                } header: {
                    Text("app.settings.account")
                }
            }
            .navigationTitle(Text("app.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("app.settings.done") }
                }
            }
        }
    }
}
