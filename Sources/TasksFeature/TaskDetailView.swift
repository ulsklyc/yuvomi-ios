import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Das Detail einer Aufgabe (Q7): Kopf, Beschreibung mit Checkliste, Unteraufgaben, Angaben.
/// In E2 nur lesend, Kästchen und Kreise sind Zeichen.
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
            TaskDetailList(task: task, refreshProblem: model.refreshProblem)
                .refreshable { await model.load() }
        }
    }
}

struct TaskDetailList: View {
    let task: TaskDetail
    let refreshProblem: TaskDetailModel.Problem?

    var body: some View {
        List {
            if let refreshProblem {
                ProblemLabel(Text(refreshProblem.message, bundle: .module))
            }
            Section {
                TaskDetailHeader(task: task)
            }
            let blocks = DescriptionBlock.blocks(of: Checklist(description: task.description))
            if !blocks.isEmpty {
                Section {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        DescriptionBlockRow(block: block)
                    }
                } header: {
                    Text("tasks.detail.section.description", bundle: .module)
                }
            }
            if !task.subtasks.isEmpty {
                Section {
                    ForEach(task.subtasks) { SubtaskRow(subtask: $0) }
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

/// Text mit Inline-Markdown oder ein Punkt der Checkliste.
struct DescriptionBlockRow: View {
    let block: DescriptionBlock

    var body: some View {
        switch block {
        case .text(let text):
            Text(Self.markdown(text))
        case .point(let point):
            Label {
                Text(Self.markdown(point.text))
                    .strikethrough(point.isChecked)
                    .foregroundStyle(point.isChecked ? .secondary : .primary)
            } icon: {
                Image(systemName: point.isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(point.isChecked ? Color.accentColor : .secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(point.isChecked ? "tasks.detail.checked" : "tasks.detail.unchecked", bundle: .module))
        }
    }

    /// Fett, kursiv, Code und Links wie in der Web-App, Umbrüche bleiben. Was sich nicht lesen
    /// lässt, bleibt Text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct SubtaskRow: View {
    let subtask: TaskSummary

    var body: some View {
        Label {
            Text(verbatim: subtask.title)
                .strikethrough(subtask.status == .done)
                .foregroundStyle(subtask.status == .done ? .secondary : .primary)
        } icon: {
            Image(systemName: subtask.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(subtask.status == .done ? Color.accentColor : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(subtask.status == .done ? "tasks.detail.status.done" : "tasks.detail.status.open", bundle: .module))
    }
}

/// Die übrigen Angaben, nur was gesetzt ist (Q7).
struct TaskFacts: View {
    let task: TaskDetail

    var body: some View {
        let priority = task.priority.label
        let start = task.start?.start().map { $0.formatted(date: .abbreviated, time: .omitted) }
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
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
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
            onUnauthorized: {}
        ))
    }
}

#Preview("Fällig mit Zuständiger") {
    NavigationStack {
        TaskDetailView(model: TaskDetailModel(
            taskID: 7,
            tasks: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            onUnauthorized: {}
        ))
    }
}
