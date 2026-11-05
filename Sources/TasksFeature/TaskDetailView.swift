import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Das Detail einer Aufgabe (Q7): Kopf mit Abhaken, Beschreibung mit Checkliste zum Ankreuzen,
/// Unteraufgaben, Angaben. Bei Nur-lesen sind Kästchen und Kreise nur Zeichen (Q4).
public struct TaskDetailView: View {
    let model: TaskDetailModel

    public init(model: TaskDetailModel) {
        self.model = model
    }

    public var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .gone:
            ContentUnavailableView {
                Label { Text("tasks.detail.gone.title", bundle: .module) } icon: { Image(systemName: "questionmark.folder") }
            } description: {
                Text("tasks.detail.gone.message", bundle: .module)
            }
        case .failed(let problem):
            ContentUnavailableView {
                Label { Text("tasks.detail.failed.title", bundle: .module) } icon: { Image(systemName: "wifi.exclamationmark") }
            } description: {
                Text(problem.message, bundle: .module)
            } actions: {
                Button { Task { await model.load() } } label: { Text("tasks.retry", bundle: .module) }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let task):
            TaskDetailList(task: task, model: model)
                .refreshable { await model.load() }
        }
    }
}

struct TaskDetailList: View {
    let task: TaskDetail
    let model: TaskDetailModel

    var body: some View {
        List {
            if let notice = model.notice {
                ProblemLabel(Text(notice.message, bundle: .module))
            } else if let refreshProblem = model.refreshProblem {
                ProblemLabel(Text(refreshProblem.message, bundle: .module))
            }
            Section {
                TaskDetailHeader(task: task)
                if model.canWrite {
                    StatusButton(isDone: task.status == .done, isBusy: model.writingStatus.contains(task.id)) {
                        Task { await model.toggleStatus() }
                    }
                }
                if let next = model.nextDue?.start() {
                    Label { Text("tasks.detail.nextDue \(next.taskDayText)", bundle: .module) } icon: { Image(systemName: "repeat") }
                        .foregroundStyle(.secondary)
                }
            }
            if !model.blocks.isEmpty {
                Section {
                    ForEach(Array(model.blocks.enumerated()), id: \.offset) { _, block in
                        DescriptionBlockRow(block: block, model: model)
                    }
                } header: {
                    Text("tasks.detail.section.description", bundle: .module)
                }
            }
            if !task.subtasks.isEmpty {
                Section {
                    ForEach(task.subtasks) { subtask in
                        SubtaskRow(subtask: subtask, canWrite: model.canWrite, isBusy: model.writingStatus.contains(subtask.id)) {
                            Task { await model.toggleSubtask(subtask.id) }
                        }
                    }
                } header: {
                    Text("tasks.detail.section.subtasks", bundle: .module)
                }
            }
            TaskFacts(task: task)
        }
    }
}

/// Titel, Status, Fälligkeit und Zuständige.
struct TaskDetailHeader: View {
    let task: TaskDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: task.title)
                .font(.title2.bold())
                .strikethrough(task.status == .done)
                .accessibilityAddTraits(.isHeader)
            if let status = task.status.label {
                Label { Text(status, bundle: .module) } icon: { Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle.dotted") }
                    .font(.subheadline)
                    .foregroundStyle(task.status == .done ? .green : .secondary)
            }
            if let due = task.dueText {
                Label { Text(verbatim: due) } icon: { Image(systemName: "calendar") }
                    .font(.subheadline)
                    .accessibilityLabel(Text("tasks.detail.due \(due)", bundle: .module))
            }
            if !task.assignees.isEmpty {
                let names = task.assignees.formatted(.list(type: .and))
                Label { Text(verbatim: names) } icon: { Image(systemName: "person") }
                    .font(.subheadline)
                    .accessibilityLabel(Text("tasks.detail.assignees \(names)", bundle: .module))
            }
        }
        .padding(.vertical, 4)
    }
}

/// „Abhaken“ oder „Wieder öffnen“ im Kopf des Details (Q2, Q7).
struct StatusButton: View {
    let isDone: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(isDone ? "tasks.action.reopen" : "tasks.action.checkOff", bundle: .module)
            } icon: {
                Image(systemName: isDone ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isDone ? .secondary : .accentColor)
        .disabled(isBusy)
        .sensoryFeedback(.success, trigger: isDone) { old, new in !old && new }
    }
}

/// Text mit Inline-Markdown oder ein Punkt der Checkliste. Darf die Person schreiben, ist der
/// Punkt ein Knopf zum Ankreuzen. Solange die Anfrage läuft, zeigt er den gewählten Zustand.
struct DescriptionBlockRow: View {
    let block: DescriptionBlock
    let model: TaskDetailModel

    var body: some View {
        switch block {
        case .text(let text):
            Text(Self.markdown(text))
        case .point(let point):
            let checked = model.ticking[point.index] ?? point.isChecked
            if model.canWrite {
                Button { Task { await model.tick(line: point.index) } } label: { label(point, checked: checked) }
                    .buttonStyle(.plain)
                    .disabled(model.ticking[point.index] != nil)
                    .accessibilityAddTraits(.isToggle)
                    .sensoryFeedback(.selection, trigger: checked)
            } else {
                label(point, checked: checked)
            }
        }
    }

    private func label(_ point: Checklist.Point, checked: Bool) -> some View {
        Label {
            Text(Self.markdown(point.text))
                .strikethrough(checked)
                .foregroundStyle(checked ? .secondary : .primary)
        } icon: {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        // Die ganze Zeile nimmt den Tipp an, nicht nur der Text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(checked ? "tasks.detail.checked" : "tasks.detail.unchecked", bundle: .module))
    }

    /// Fett, kursiv, Code und Links wie in der Web-App, Umbrüche bleiben. Was sich nicht lesen
    /// lässt, bleibt Text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Eine Unteraufgabe. Wechselt `open` ↔ `done` wie in der PWA (Q2).
struct SubtaskRow: View {
    let subtask: TaskSummary
    let canWrite: Bool
    let isBusy: Bool
    let toggle: () -> Void

    var body: some View {
        let done = subtask.status == .done
        HStack(spacing: 4) {
            if canWrite {
                CheckCircle(isDone: done, isBusy: isBusy, action: toggle)
            } else {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: subtask.title)
                .strikethrough(done)
                .foregroundStyle(done ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(done ? "tasks.detail.status.done" : "tasks.detail.status.open", bundle: .module))
        .accessibilityActions {
            if canWrite {
                Button(action: toggle) { Text(done ? "tasks.action.reopen" : "tasks.action.checkOff", bundle: .module) }
            }
        }
    }
}

/// Die übrigen Angaben, nur was gesetzt ist (Q7).
struct TaskFacts: View {
    let task: TaskDetail

    var body: some View {
        let priority = task.priority.label
        let start = task.start?.start().map(\.taskDayText)
        if priority != nil || start != nil || task.isRecurring || !task.tags.isEmpty || task.points > 0 || task.isLocked {
            Section {
                if let priority {
                    LabeledContent { Text(priority, bundle: .module) } label: { Text("tasks.detail.priority", bundle: .module) }
                }
                if let start {
                    LabeledContent { Text(verbatim: start) } label: { Text("tasks.detail.start", bundle: .module) }
                }
                if task.isRecurring {
                    Label { Text("tasks.detail.recurring", bundle: .module) } icon: { Image(systemName: "repeat") }
                }
                if !task.tags.isEmpty {
                    LabeledContent { Text(verbatim: task.tags.formatted(.list(type: .and))) } label: { Text("tasks.detail.tags", bundle: .module) }
                }
                if task.points > 0 {
                    LabeledContent { Text(task.points, format: .number) } label: { Text("tasks.detail.points", bundle: .module) }
                }
                if task.isLocked {
                    Label { Text("tasks.detail.locked", bundle: .module) } icon: { Image(systemName: "lock") }
                }
            } header: {
                Text("tasks.detail.section.details", bundle: .module)
            }
        }
    }
}

extension TaskDetail {
    /// Datum und Uhrzeit der Fälligkeit, wie die Zeile der Liste sie schreibt.
    var dueText: String? {
        guard let date = due?.start() else { return nil }
        let day = date.taskDayText
        return dueTime.map { "\(day), \($0)" } ?? day
    }
}

extension TaskStatus {
    /// `nil` für offen und für einen unbekannten Wert: Das Detail sagt dann nichts zum Status.
    var label: LocalizedStringKey? {
        switch self {
        case .done: "tasks.detail.status.done"
        case .inProgress: "tasks.detail.status.inProgress"
        case .open, .unknown: nil
        }
    }
}

extension TaskPriority {
    /// `nil` für keine und für einen unbekannten Wert.
    var label: LocalizedStringKey? {
        switch self {
        case .low: "tasks.detail.priority.low"
        case .medium: "tasks.detail.priority.medium"
        case .high: "tasks.detail.priority.high"
        case .urgent: "tasks.detail.priority.urgent"
        case .none, .unknown: nil
        }
    }
}

extension TaskDetailModel.Problem {
    var message: LocalizedStringKey {
        switch self {
        case .unreachable: "tasks.problem.unreachable"
        case .unexpectedResponse: "tasks.problem.unexpectedResponse"
        }
    }
}

#Preview("Checkliste und Unteraufgaben") {
    let checklist = FixtureTransport.Response(body: try! Fixtures.data("task-checklist"))
    NavigationStack {
        TaskDetailView(model: TaskDetailModel(
            taskID: 24,
            tasks: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport(overrides: ["getTask": checklist])),
            writer: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            onUnauthorized: {}
        ))
    }
}

#Preview("Fällig mit Zuständiger") {
    NavigationStack {
        TaskDetailView(model: TaskDetailModel(
            taskID: 7,
            tasks: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            writer: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            onUnauthorized: {}
        ))
    }
}
