import SwiftUI

/// Der Kreis zum Abhaken (Q6): leer offen, gefüllt abgehakt. Gesperrt, solange die Anfrage läuft.
///
/// VoiceOver sieht ihn nicht als eigenes Element: Die Zeile trägt Zustand und Aktion
/// (`checkOffAccessibility`), sonst gäbe es zwei Stopps je Aufgabe.
struct CheckCircle: View {
    let isDone: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isDone ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
                // Mindestens 44 Punkte zum Tippen, auch wenn das Symbol kleiner ist.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        // Borderless: In einer Zeile mit `NavigationLink` fängt der Kreis seinen Tipp selbst.
        .buttonStyle(.borderless)
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
        .sensoryFeedback(.success, trigger: isDone) { old, new in !old && new }
        .accessibilityHidden(true)
    }
}

extension View {
    /// Zustand und Aktion zum Abhaken für VoiceOver an der ganzen Zeile.
    func checkOffAccessibility(isDone: Bool, canWrite: Bool, action: @escaping () -> Void) -> some View {
        self
            .accessibilityValue(isDone ? Text("tasks.detail.status.done", bundle: .module) : Text(verbatim: ""))
            .accessibilityActions {
                if canWrite {
                    Button(action: action) {
                        Text(isDone ? "tasks.action.reopen" : "tasks.action.checkOff", bundle: .module)
                    }
                }
            }
    }
}
