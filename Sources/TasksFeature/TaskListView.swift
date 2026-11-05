import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Offene Aufgaben, nach Fälligkeit gruppiert. Der Kreis hakt ab, ein Tipp auf den Rest der
/// Zeile öffnet das Detail (Q6).
///
/// `banner` steht über den Abschnitten, etwa die Karte für Erinnerungen. Was darin steht,
/// entscheidet die App, die Liste kennt Erinnerungen nicht.
public struct TaskListView<Banner: View>: View {
    @Bindable var model: TaskListModel
    let onOpenSettings: () -> Void
    let banner: Banner

    public init(model: TaskListModel, onOpenSettings: @escaping () -> Void, @ViewBuilder banner: () -> Banner) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        self.banner = banner()
    }

    public var body: some View {
        NavigationStack(path: $model.path) {
            content
                .navigationTitle(Text("tasks.title", bundle: .module))
                // Außerhalb der `List`, sonst sieht der Stapel das Ziel nicht immer.
                .navigationDestination(for: Int.self) { id in
                    TaskDetailView(model: model.detail(for: id))
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onOpenSettings) {
                            Label { Text("tasks.settings", bundle: .module) } icon: { Image(systemName: "gearshape") }
                        }
                    }
                    // Bei Nur-lesen kein „+“ (Q7).
                    if model.canWrite {
                        ToolbarItem(placement: .primaryAction) {
                            Button { model.startCreating() } label: {
                                Label { Text("tasks.form.new", bundle: .module) } icon: { Image(systemName: "plus") }
                            }
                        }
                    }
                }
        }
        .sheet(item: $model.form) { form in
            TaskFormView(model: form) { model.form = nil }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let problem):
            ContentUnavailableView {
                Label { Text("tasks.failed.title", bundle: .module) } icon: { Image(systemName: "wifi.exclamationmark") }
            } description: {
                Text(problem.message, bundle: .module)
            } actions: {
                Button { Task { await model.load() } } label: { Text("tasks.retry", bundle: .module) }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let sections):
            List {
                if let notice = model.notice {
                    ProblemLabel(Text(notice.message, bundle: .module))
                } else if let problem = model.refreshProblem {
                    ProblemLabel(Text(problem.message, bundle: .module))
                }
                banner
                // In der Liste statt darüber, sonst läge der Hinweis über dem Banner.
                if sections.isEmpty {
                    ContentUnavailableView {
                        Label { Text("tasks.empty.title", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                    } description: {
                        Text("tasks.empty.message", bundle: .module)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.tasks) { task in
                            let toggle = { Task { await model.toggle(task.id) } }
                            NavigationLink(value: task.id) {
                                HStack(spacing: 4) {
                                    if model.canWrite {
                                        CheckCircle(isDone: task.status == .done, isBusy: model.writing.contains(task.id)) { _ = toggle() }
                                    }
                                    TaskRow(task: task, showsDate: section.kind != .today)
                                }
                            }
                            .checkOffAccessibility(isDone: task.status == .done, canWrite: model.canWrite) { _ = toggle() }
                        }
                    } header: {
                        Text(section.kind.title, bundle: .module)
                    }
                }
            }
            .refreshable { await model.load() }
        }
    }
}

struct TaskRow: View {
    let task: TaskSummary
    let showsDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                // Abgehakt bleibt die Zeile durchgestrichen stehen, bis die Liste neu lädt (Q2, Q14).
                Text(verbatim: task.title)
                    .strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                Spacer(minLength: 8)
                if task.priority == .urgent || task.priority == .high {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(task.priority == .urgent ? .red : .orange)
                        .accessibilityLabel(Text(task.priority == .urgent ? "tasks.priority.urgent" : "tasks.priority.high", bundle: .module))
                }
            }
            if detail != nil || task.subtasks != nil {
                HStack(spacing: 6) {
                    if let detail { Text(verbatim: detail) }
                    if let subtasks = task.subtasks {
                        // Sichtbar knapp, VoiceOver liest den ganzen Satz statt „2 Schrägstrich 5“.
                        Label {
                            Text("tasks.row.subtasks \(subtasks.done) \(subtasks.total)", bundle: .module)
                        } icon: {
                            Image(systemName: "checklist")
                        }
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel(Text("tasks.row.subtasks.spoken \(subtasks.done) \(subtasks.total)", bundle: .module))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Datum (außer unter „Heute“), Uhrzeit und Zuständige in einer Zeile.
    private var detail: String? {
        var parts: [String] = []
        if showsDate, let date = task.due?.start() {
            parts.append(date.taskDayText)
        }
        if let time = task.dueTime { parts.append(time) }
        if !task.assignees.isEmpty { parts.append(task.assignees.formatted(.list(type: .and))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Date {
    /// Der Tag einer Aufgabe, etwa „Fr., 6. Nov.“: gleich in Zeile und Detail.
    var taskDayText: String {
        formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

extension TaskSection.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .overdue: "tasks.section.overdue"
        case .today: "tasks.section.today"
        case .upcoming: "tasks.section.upcoming"
        case .noDate: "tasks.section.noDate"
        }
    }
}

extension TaskListModel.Problem {
    var message: LocalizedStringKey {
        switch self {
        case .unreachable: "tasks.problem.unreachable"
        case .unexpectedResponse: "tasks.problem.unexpectedResponse"
        }
    }
}

#Preview("Fixtures") {
    TaskListView(
        model: TaskListModel(
            tasks: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            writer: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            editor: YuvomiTasks(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            permissions: YuvomiMemberPermissions(server: URL(string: "https://yuvomi.example.com")!, credential: "preview", transport: FixtureTransport()),
            today: { CalendarDay(year: 2026, month: 11, day: 3) },
            onUnauthorized: {}
        ),
        onOpenSettings: {}
    ) {
        EmptyView()
    }
}
