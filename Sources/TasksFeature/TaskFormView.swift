import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Das Sheet fürs Anlegen (Q2): „Abbrechen“ links, „Sichern“ rechts. Mit Änderungen lässt es
/// sich nicht wegwischen, und „Abbrechen“ fragt nach.
struct TaskFormView: View {
    @Bindable var model: TaskFormModel
    let onCancel: () -> Void

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
                if model.showsAssignees, let people = model.options?.people {
                    assigneeSection(people)
                }
                detailsSection
                descriptionSection
            }
            .navigationTitle(Text("tasks.form.new", bundle: .module))
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
            TextField(text: $model.draft.title, axis: .vertical) {
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
                DatePicker(selection: dueDate, displayedComponents: .date) {
                    Text("tasks.form.date", bundle: .module)
                }
                Toggle(isOn: $model.hasTime.animation()) {
                    Label { Text("tasks.form.time", bundle: .module) } icon: { Image(systemName: "clock") }
                }
                if model.hasTime {
                    DatePicker(selection: dueTime, displayedComponents: .hourAndMinute) {
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
                                .foregroundStyle(.primary)
                            if position == 0 {
                                Text("tasks.form.assignees.lead", bundle: .module)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if position != nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.rect)
                }
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
                ForEach(TaskPriority.choices, id: \.self) { priority in
                    Text(priority.choiceLabel, bundle: .module).tag(priority)
                }
            } label: {
                Label { Text("tasks.detail.priority", bundle: .module) } icon: { Image(systemName: "flag") }
            }
            if let categories = model.options?.categories, !categories.isEmpty {
                Picker(selection: $model.draft.category) {
                    ForEach(categories) { category in
                        Text(verbatim: category.title(Self.translateCategory)).tag(category.key)
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
                if model.hasChanges { confirmsDiscard = true } else { onCancel() }
            } label: {
                Text("tasks.form.cancel", bundle: .module)
            }
            .disabled(model.isSaving)
            .confirmationDialog(Text("tasks.form.discard.title", bundle: .module), isPresented: $confirmsDiscard) {
                Button(role: .destructive, action: onCancel) { Text("tasks.form.discard", bundle: .module) }
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

    // MARK: Datum und Uhrzeit

    /// Der Tag als `Date` für den Picker, Mitternacht in der Zeitzone des Geräts.
    private var dueDate: Binding<Date> {
        Binding {
            model.draft.due?.start() ?? .now
        } set: { date in
            model.draft.due = CalendarDay(date)
        }
    }

    /// `HH:MM` als `Date` für den Picker. Nur Stunde und Minute zählen.
    private var dueTime: Binding<Date> {
        Binding {
            let parts = (model.draft.dueTime ?? "").split(separator: ":").compactMap { Int($0) }
            let midnight = Calendar.current.startOfDay(for: .now)
            guard parts.count == 2 else { return midnight }
            return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: midnight) ?? midnight
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.draft.dueTime = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
    }

    // MARK: Kategorien

    /// Die acht eingebauten Kategorien haben eigene Texte (Q8). Der Rest zeigt `name` oder Key.
    private static let categoryKeys: [String: String.LocalizationValue] = [
        "tasks.categoryHousehold": "tasks.category.household",
        "tasks.categorySchool": "tasks.category.school",
        "tasks.categoryShopping": "tasks.category.shopping",
        "tasks.categoryRepair": "tasks.category.repair",
        "tasks.categoryHealth": "tasks.category.health",
        "tasks.categoryFinance": "tasks.category.finance",
        "tasks.categoryLeisure": "tasks.category.leisure",
        "tasks.categoryMisc": "tasks.category.misc",
    ]

    static func translateCategory(_ labelKey: String) -> String? {
        categoryKeys[labelKey].map { String(localized: $0, bundle: .module) }
    }
}

extension TaskPriority {
    /// Was das Formular anbietet. `.unknown` kann die App nicht setzen.
    static let choices: [TaskPriority] = [.none, .low, .medium, .high, .urgent]

    var choiceLabel: LocalizedStringKey {
        label ?? "tasks.detail.priority.none"
    }
}

#Preview("Neue Aufgabe") {
    TaskFormView(
        model: TaskFormModel(
            editor: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            onUnauthorized: {}, onFinished: { _ in }
        ),
        onCancel: {}
    )
}
