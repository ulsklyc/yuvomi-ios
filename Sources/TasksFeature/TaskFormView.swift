import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Das Sheet fürs Anlegen und Ändern (Q2): „Abbrechen“ links, „Sichern“ rechts. Mit Änderungen lässt es
/// sich nicht wegwischen, und „Abbrechen“ fragt nach.
struct TaskFormView: View {
    @Bindable var model: TaskFormModel

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let notice = model.notice {
                    ProblemLabel(Text(notice.message, bundle: .module))
                }
                titleSection
                dateSection
                if let people = model.assignablePeople {
                    assigneeSection(people)
                }
                detailsSection
                descriptionSection
            }
            // Während des Sicherns ist der Entwurf schon unterwegs: Was die Person dann noch
            // ändert, käme nie an und ginge mit dem Sheet verloren.
            .disabled(model.isSaving)
            .navigationTitle(Text(model.isEditing ? "tasks.form.edit" : "tasks.form.new", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(model.hasChanges || model.isSaving)
        .task { await model.loadOptions() }
        .onAppear { titleFocused = true }
    }

    // MARK: Abschnitte

    private var titleSection: some View {
        Section {
            // Einzeilig: Mit `axis: .vertical` fügte die Return-Taste einen Umbruch in den Titel ein.
            TextField(text: $model.draft.title) {
                Text("tasks.form.title", bundle: .module)
            }
            .focused($titleFocused)
            .submitLabel(.done)
        } footer: {
            if model.draft.problems.contains(.titleTooLong) {
                Text("tasks.form.title.tooLong", bundle: .module)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Zwei Schalter wie in Erinnerungen (Q17). Die Uhrzeit gibt es nur mit Datum.
    private var dateSection: some View {
        Section {
            Toggle(isOn: $model.hasDue.animation()) {
                Label { Text("tasks.form.date", bundle: .module) } icon: { Image(systemName: "calendar") }
            }
            if model.hasDue {
                DatePicker(selection: $model.dueDate, displayedComponents: .date) {
                    Text("tasks.form.date", bundle: .module)
                }
                Toggle(isOn: $model.hasTime.animation()) {
                    Label { Text("tasks.form.time", bundle: .module) } icon: { Image(systemName: "clock") }
                }
                if model.hasTime {
                    DatePicker(selection: $model.dueTimeDate, displayedComponents: .hourAndMinute) {
                        Text("tasks.form.time", bundle: .module)
                    }
                }
            }
        }
    }

    /// Mehrfachauswahl, die zuerst gewählte Person ist hauptverantwortlich (Q10).
    private func assigneeSection(_ people: [TaskOptions.Person]) -> some View {
        Section {
            ForEach(people) { person in
                let position = model.draft.assigneeIDs.firstIndex(of: person.id)
                Button {
                    model.toggleAssignee(person.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: person.name)
                            if position == 0 {
                                Text("tasks.form.assignees.lead", bundle: .module)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if position != nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
                // Im `Form` färbt ein Knopf sein Label in der Akzentfarbe. Die Namen sind keine Aktion.
                .tint(.primary)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(position != nil ? .isSelected : [])
            }
        } header: {
            Text("tasks.form.assignees", bundle: .module)
        } footer: {
            Text("tasks.form.assignees.footer", bundle: .module)
        }
    }

    private var detailsSection: some View {
        Section {
            Picker(selection: $model.draft.priority) {
                ForEach(TaskPriority.settable, id: \.self) { priority in
                    Text(priority.choiceLabel, bundle: .module).tag(priority)
                }
            } label: {
                Label { Text("tasks.detail.priority", bundle: .module) } icon: { Image(systemName: "flag") }
            }
            if let categories = model.options?.categories, !categories.isEmpty {
                Picker(selection: $model.draft.category) {
                    ForEach(categories) { category in
                        Text(verbatim: category.localizedTitle).tag(category.key)
                    }
                } label: {
                    Label { Text("tasks.form.category", bundle: .module) } icon: { Image(systemName: "folder") }
                }
            }
        }
    }

    /// Rohtext, die Checkliste bleibt Text (Q18). Ab 4500 Zeichen ein Zähler.
    private var descriptionSection: some View {
        Section {
            TextField(text: $model.draft.description, axis: .vertical) {
                Text("tasks.form.description", bundle: .module)
            }
            .lineLimit(4...)
        } footer: {
            if let count = model.descriptionCount {
                Text("tasks.form.description.count \(count)", bundle: .module)
                    .monospacedDigit()
                    .foregroundStyle(count > TaskDraft.descriptionLimit ? .red : .secondary)
                    .accessibilityLabel(Text("tasks.form.description.count.spoken \(count)", bundle: .module))
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                if model.hasChanges { confirmsDiscard = true } else { dismiss() }
            } label: {
                Text("tasks.form.cancel", bundle: .module)
            }
            .disabled(model.isSaving)
            .confirmationDialog(Text("tasks.form.discard.title", bundle: .module), isPresented: $confirmsDiscard) {
                Button(role: .destructive) { dismiss() } label: { Text("tasks.form.discard", bundle: .module) }
                Button(role: .cancel) {} label: { Text("tasks.form.keepEditing", bundle: .module) }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
                    .accessibilityLabel(Text("tasks.form.saving", bundle: .module))
            } else {
                Button { Task { await model.save() } } label: { Text("tasks.form.save", bundle: .module) }
                    .disabled(!model.canSave)
            }
        }
    }
}

extension TaskCategory {
    /// Die acht eingebauten Kategorien haben eigene Texte (Q8). Der Rest zeigt `name` oder Key.
    private static let builtIn: [String: String.LocalizationValue] = [
        "tasks.categoryHousehold": "tasks.category.household",
        "tasks.categorySchool": "tasks.category.school",
        "tasks.categoryShopping": "tasks.category.shopping",
        "tasks.categoryRepair": "tasks.category.repair",
        "tasks.categoryHealth": "tasks.category.health",
        "tasks.categoryFinance": "tasks.category.finance",
        "tasks.categoryLeisure": "tasks.category.leisure",
        "tasks.categoryMisc": "tasks.category.misc",
    ]

    var localizedTitle: String {
        title { Self.builtIn[$0].map { String(localized: $0, bundle: .module) } }
    }
}

extension TaskPriority {
    var choiceLabel: LocalizedStringKey {
        label ?? "tasks.detail.priority.none"
    }
}

#Preview("Neue Aufgabe") {
    TaskFormView(
        model: TaskFormModel(
            editor: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            onUnauthorized: {}, onFinished: { _ in }
        )
    )
}
