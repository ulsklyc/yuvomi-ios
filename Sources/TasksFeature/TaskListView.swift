import DesignSystem
import SwiftUI
import YuvomiAPI
import YuvomiCore
import YuvomiFixtures

/// Offene Aufgaben, nach Fälligkeit gruppiert. Nur lesend.
public struct TaskListView: View {
    let model: TaskListModel
    let onSignOut: () async -> Void

    public init(model: TaskListModel, onSignOut: @escaping () async -> Void) {
        self.model = model
        self.onSignOut = onSignOut
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("tasks.title", bundle: .module))
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                Task { await onSignOut() }
                            } label: {
                                Label { Text("tasks.signOut", bundle: .module) } icon: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                            }
                        } label: {
                            Label { Text("tasks.account", bundle: .module) } icon: { Image(systemName: "person.crop.circle") }
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
                ForEach(sections) { section in
                    Section {
                        ForEach(section.tasks) { TaskRow(task: $0, showsDate: section.kind != .today) }
                    } header: {
                        Text(section.kind.title, bundle: .module)
                    }
                }
            }
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView {
                        Label { Text("tasks.empty.title", bundle: .module) } icon: { Image(systemName: "checkmark.circle") }
                    } description: {
                        Text("tasks.empty.message", bundle: .module)
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
            if let detail {
                Text(verbatim: detail)
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
        onSignOut: {}
    )
}
