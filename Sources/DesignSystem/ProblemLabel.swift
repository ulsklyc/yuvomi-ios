import SwiftUI

/// Fehlermeldung unter einem Formular oder über einer Liste. Der Text kommt aus dem
/// String Catalog des aufrufenden Moduls.
public struct ProblemLabel: View {
    let text: Text

    public init(_ text: Text) {
        self.text = text
    }

    public var body: some View {
        Label { text } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.callout)
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
    }
}

/// Hauptaktion eines Formulars: volle Breite, mit Fortschritt während der Anfrage.
public struct PrimaryButton: View {
    let title: Text
    let isWorking: Bool
    let action: () async -> Void

    public init(_ title: Text, isWorking: Bool, action: @escaping () async -> Void) {
        self.title = title
        self.isWorking = isWorking
        self.action = action
    }

    public var body: some View {
        Button {
            Task { await action() }
        } label: {
            ZStack {
                title.opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView() }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking)
    }
}
