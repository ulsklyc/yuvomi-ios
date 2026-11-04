import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Offene Aufgaben, nach Fälligkeit gruppiert. Ein Tipp öffnet das Detail.
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
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onOpenSettings) {
                            Label { Text("tasks.settings", bundle: .module) } icon: { Image(systemName: "gearshape") }
                        }
                    }
                }
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
                if let problem = model.refreshProblem {
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
                            NavigationLink(value: task.id) {
                                TaskRow(task: task, showsDate: section.kind != .today)
                            }
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
                Text(verbatim: task.title)
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
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        }
        if let time = task.dueTime { parts.append(time) }
        if !task.assignees.isEmpty { parts.append(task.assignees.formatted(.list(type: .and))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            today: { CalendarDay(year: 2026, month: 11, day: 3) },
            onUnauthorized: {}
        ),
        onOpenSettings: {}
    ) {
        EmptyView()
    }
}
