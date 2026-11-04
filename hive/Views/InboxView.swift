import SwiftUI

/// M7 · Hive Inbox. One queue across environments and machines for everything that wants a
/// person: blocked agents, tasks waiting on approval, finished work and failed runs. Related
/// updates are grouped by their source, and each row offers its next safe action inline.
struct InboxView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var commandCenter: CommandCenterStore
    let onReview: (HiveEnvironment?, HiveTask?) -> Void
    let onDelegate: (HiveAgent) -> Void
    let onClose: () -> Void

    @State private var plans: [HiveTaskPlan] = []
    @State private var errorMessage: String?
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all, attention, review, finished, failures

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .attention: "Needs you"
            case .review: "Review"
            case .finished: "Finished"
            case .failures: "Failures"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await poll() }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.hiveAmber)
                Text("Inbox").font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
                if !viewModel.isConnected {
                    Label("Runtime unavailable", systemImage: "bolt.horizontal.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close the inbox")
            }

            HStack(spacing: 6) {
                ForEach(Filter.allCases) { item in
                    Button { filter = item } label: {
                        HStack(spacing: 5) {
                            Text(item.title)
                            let count = items(for: item).count
                            if count > 0 {
                                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(ToolbarPillButtonStyle(isActive: filter == item))
                }
                Spacer()
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        let visible = items(for: filter)
        if visible.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: filter == .all ? "checkmark.seal" : "tray",
                description: Text(filter == .all
                    ? "Nothing needs attention right now."
                    : "No \(filter.title.lowercased()) items.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped(visible), id: \.source) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            sourceHeader(group.source)
                            ForEach(group.items) { item in
                                InboxRow(item: item)
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "All clear"
        case .attention: "No one is waiting"
        case .review: "Nothing to review"
        case .finished: "Nothing finished yet"
        case .failures: "No failures"
        }
    }

    private func sourceHeader(_ source: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.hasPrefix("machine:") ? "server.rack" : "folder")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.hiveAmber)
            Text(source.hasPrefix("machine:") ? String(source.dropFirst("machine:".count)) : source)
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: Items

    private func grouped(_ items: [InboxItem]) -> [(source: String, items: [InboxItem])] {
        Dictionary(grouping: items, by: \.source)
            .map { (source: $0.key, items: $0.value) }
            .sorted { $0.source < $1.source }
    }

    private func items(for filter: Filter) -> [InboxItem] {
        let all = allItems()
        switch filter {
        case .all: return all.sorted { $0.kind.rank < $1.kind.rank }
        case .attention: return all.filter { $0.kind == .attention }
        case .review: return all.filter { $0.kind == .review }
        case .finished: return all.filter { $0.kind == .finished }
        case .failures: return all.filter { $0.kind == .failure }
        }
    }

    private func allItems() -> [InboxItem] {
        var items: [InboxItem] = []

        for agent in viewModel.agents {
            if let item = agentItem(agent, machine: nil) { items.append(item) }
        }
        for (machine, agents) in viewModel.machineAgents {
            for agent in agents {
                if let item = agentItem(agent, machine: machine) { items.append(item) }
            }
        }
        for plan in plans {
            for task in plan.tasks {
                if let item = taskItem(task, plan: plan) { items.append(item) }
            }
        }
        for environment in viewModel.environments where (environment.git?.conflicts ?? 0) > 0 {
            let conflicts = environment.git?.conflicts ?? 0
            let name = environment.name.isEmpty ? environment.id : environment.name
            items.append(InboxItem(
                id: "conflict-\(environment.id)",
                kind: .review,
                title: "\(name) has merge conflicts",
                subtitle: "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s")",
                source: environment.id,
                symbol: "exclamationmark.triangle",
                actions: [InboxAction("Review", "checkmark.seal") { onReview(environment, nil) }]
            ))
        }

        return items
    }

    private func agentItem(_ agent: HiveAgent, machine: String?) -> InboxItem? {
        let name = agent.name.isEmpty ? agent.kind : agent.name
        let source = machine.map { "machine:\($0)" } ?? agent.environmentID
        switch agent.state {
        case "blocked":
            var actions: [InboxAction] = []
            if machine == nil {
                actions.append(InboxAction("Approve", "checkmark", prominent: true) {
                    Task { await viewModel.sendKeys(["Enter"], toAgent: agent.id) }
                })
                actions.append(InboxAction("Deny", "xmark") {
                    Task { await viewModel.sendKeys(["Escape"], toAgent: agent.id) }
                })
            }
            actions.append(openAction(for: agent, machine: machine))
            if machine == nil {
                actions.append(InboxAction("Delegate helper…", "arrow.triangle.branch") { onDelegate(agent) })
            }
            return InboxItem(id: "agent-\(agent.id)-blocked", kind: .attention, title: "\(name) needs you",
                             subtitle: agent.reason ?? "Waiting for your decision",
                             source: source, symbol: "sparkles", provider: agent.kind, actions: actions)
        case "done":
            return InboxItem(id: "agent-\(agent.id)-done", kind: .finished, title: "\(name) finished",
                             subtitle: agent.reason, source: source, symbol: "checkmark.circle",
                             provider: agent.kind, actions: [openAction(for: agent, machine: machine)])
        case "exited":
            guard let reason = agent.reason, !reason.isEmpty else { return nil }
            var actions = [openAction(for: agent, machine: machine)]
            if machine == nil {
                actions.append(InboxAction("Resume", "arrow.clockwise") {
                    Task { await viewModel.resumeAgent(agent.id) }
                })
            }
            return InboxItem(id: "agent-\(agent.id)-exited", kind: .failure, title: "\(name) exited",
                             subtitle: reason, source: source, symbol: "xmark.circle", provider: agent.kind, actions: actions)
        default:
            return nil
        }
    }

    private func openAction(for agent: HiveAgent, machine: String?) -> InboxAction {
        if let machine, let saved = viewModel.machines.first(where: { $0.name == machine }) {
            return InboxAction("Open", "arrow.up.forward.app") { viewModel.openRemoteAgent(agent, on: saved) }
        }
        return InboxAction("Open", "arrow.up.forward.app") { viewModel.openAgent(agent.id) }
    }

    private func taskItem(_ task: HiveTask, plan: HiveTaskPlan) -> InboxItem? {
        let title = task.spec.title ?? task.spec.id
        let source = task.environmentID ?? task.spec.environmentID ?? plan.id
        switch task.state {
        case "approval":
            return InboxItem(id: "task-\(plan.id)-\(task.id)", kind: .review, title: "Review: \(title)",
                             subtitle: task.reason ?? "Waiting for approval", source: source, symbol: "hand.raised.fill",
                             actions: [
                                InboxAction("Approve", "checkmark", prominent: true) { approve(task, plan, deny: false) },
                                InboxAction("Deny", "xmark") { approve(task, plan, deny: true) },
                             ])
        case "failed":
            return InboxItem(id: "task-\(plan.id)-\(task.id)", kind: .failure, title: "Failed: \(title)",
                             subtitle: task.result?.summary ?? task.reason, source: source, symbol: "xmark.circle.fill",
                             actions: [InboxAction("Retry", "arrow.clockwise") { retry(task, plan) }])
        case "succeeded":
            guard let changed = task.result?.changed, !changed.isEmpty else { return nil }
            return InboxItem(id: "task-\(plan.id)-\(task.id)", kind: .finished, title: "Done: \(title)",
                             subtitle: task.result?.summary, source: source, symbol: "checkmark.circle.fill",
                             actions: [InboxAction("Review changes", "checkmark.seal") {
                                onReview(viewModel.environments.first { $0.id == source }, task)
                             }])
        default:
            return nil
        }
    }

    // MARK: Actions

    private func approve(_ task: HiveTask, _ plan: HiveTaskPlan, deny: Bool) {
        Task {
            do {
                replace(try await viewModel.workspace.updateTask("task.approve", planID: plan.id, taskID: task.id, deny: deny))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func retry(_ task: HiveTask, _ plan: HiveTaskPlan) {
        Task {
            do {
                replace(try await viewModel.workspace.updateTask("task.retry", planID: plan.id, taskID: task.id))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func replace(_ plan: HiveTaskPlan) {
        if let index = plans.firstIndex(where: { $0.id == plan.id }) { plans[index] = plan } else { plans.append(plan) }
        errorMessage = nil
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    private func refresh() async {
        do {
            let summaries = try await viewModel.workspace.taskSummaries()
            var fetched: [HiveTaskPlan] = []
            for summary in summaries.prefix(12) {
                if let plan = try? await viewModel.workspace.taskPlan(summary.id) {
                    fetched.append(plan)
                    for task in plan.tasks { commandCenter.recordTaskOutcome(task: task, plan: plan) }
                }
            }
            plans = fetched
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row model

struct InboxAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var prominent = false
    let run: () -> Void

    init(_ title: String, _ symbol: String, prominent: Bool = false, run: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.prominent = prominent
        self.run = run
    }
}

struct InboxItem: Identifiable {
    enum Kind: String {
        case attention, review, finished, failure

        var rank: Int {
            switch self {
            case .attention: 0
            case .review: 1
            case .failure: 2
            case .finished: 3
            }
        }

        var tint: Color {
            switch self {
            case .attention: .hiveAmber
            case .review: .blue
            case .finished: .green
            case .failure: .red
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String?
    let source: String
    var symbol: String = "circle"
    var provider: String?
    let actions: [InboxAction]
}

private struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.kind.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let provider = item.provider, !provider.isEmpty {
                        AgentProviderIcon(kind: provider, size: 10)
                    }
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(item.actions) { action in
                    InboxActionButton(action: action)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(item.kind == .attention ? Color.hiveAmber.opacity(0.08) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct InboxActionButton: View {
    let action: InboxAction

    var body: some View {
        if action.prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action.run) {
            Label(action.title, systemImage: action.symbol)
                .font(.system(size: 11.5, weight: .medium))
        }
        .controlSize(.small)
        .help(action.title)
    }
}
