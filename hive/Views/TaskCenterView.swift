import SwiftUI
import UniformTypeIdentifiers

struct TaskCenterView: View {
    let workspace: HiveWorkspaceStore
    let onOpenChanges: (HiveTask, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [HiveTaskSummary] = []
    @State private var plan: HiveTaskPlan?
    @State private var selectedTaskID: String?
    @State private var showingPlanPicker = false
    @State private var errorMessage: String?

    private var selectedTask: HiveTask? { plan?.tasks.first { $0.id == selectedTaskID } ?? plan?.tasks.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tasks and plans").font(.title2.weight(.semibold))
                    Text(plan.map { "\($0.name ?? $0.id) · \($0.state)" } ?? "Open a plan file to start")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingPlanPicker = true } label: { Label("Open Plan…", systemImage: "doc.badge.plus") }
                    .buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()

            if !summaries.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(summaries) { summary in
                            Button {
                                Task { await loadPlan(summary.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.name ?? summary.id).font(.callout.weight(.medium)).lineLimit(1)
                                    Text("\(summary.state) · \(summary.total) tasks").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(plan?.id == summary.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
                Divider()
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }

            if let plan {
                HStack(spacing: 0) {
                    taskGraph(plan).frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    taskReport.frame(width: 300).frame(maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No plan selected", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Open or drop a Hive plan file to run it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .fileImporter(isPresented: $showingPlanPicker, allowedContentTypes: [UTType(filenameExtension: "toml") ?? .plainText]) { result in
            if case .success(let url) = result { Task { await runPlanFile(url) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await runPlanFile(url) }
            return true
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func taskGraph(_ plan: HiveTaskPlan) -> some View {
        List(selection: $selectedTaskID) {
            ForEach(plan.tasks) { task in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: task.state)).foregroundStyle(color(for: task.state))
                        Text(task.spec.title ?? task.spec.id).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(task.state).font(.caption).foregroundStyle(color(for: task.state))
                    }
                    if let needs = task.spec.needs, !needs.isEmpty {
                        Text("↳ after \(needs.joined(separator: ", "))")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                    if let reason = task.reason, !reason.isEmpty {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.leading, 22)
                    }
                    actionButtons(for: task)
                }
                .padding(.vertical, 4)
                .tag(task.id)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func actionButtons(for task: HiveTask) -> some View {
        HStack(spacing: 7) {
            if task.state == "approval" {
                Button("Approve") { Task { await update(task, method: "task.approve", deny: false) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button("Deny", role: .destructive) { Task { await update(task, method: "task.approve", deny: true) } }
                    .controlSize(.small)
            }
            if ["waiting", "queued", "running", "blocked", "approval"].contains(task.state) {
                Button("Cancel", role: .destructive) { Task { await update(task, method: "task.cancel") } }.controlSize(.small)
            }
            if ["failed", "cancelled", "skipped"].contains(task.state) {
                Button("Retry") { Task { await update(task, method: "task.retry") } }.controlSize(.small)
            }
        }
        .padding(.leading, 22)
    }

    private var taskReport: some View {
        Group {
            if let task = selectedTask {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(task.spec.title ?? task.spec.id).font(.headline)
                        Text(task.result?.summary ?? task.reason ?? task.result?.outcome ?? "No report yet.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let changed = task.result?.changed, !changed.isEmpty {
                            Text("Changed files").font(.subheadline.weight(.semibold))
                            ForEach(changed, id: \.self) { path in
                                Button {
                                    onOpenChanges(task, path)
                                } label: {
                                    Label(path, systemImage: "arrow.up.right.square")
                                        .font(.system(size: 11, design: .monospaced)).lineLimit(2).multilineTextAlignment(.leading)
                                }
                                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                .help("Open this task's environment in the Changes inspector")
                            }
                        }
                        if let screen = task.result?.screen, !screen.isEmpty {
                            Text(screen.suffix(8).joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("Select a task", systemImage: "checklist")
            }
        }
    }

    private func refresh() async {
        do {
            summaries = try await workspace.taskSummaries()
            if let plan, summaries.contains(where: { $0.id == plan.id }) {
                await loadPlan(plan.id)
            } else if plan == nil, let first = summaries.first {
                await loadPlan(first.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadPlan(_ id: String) async {
        do {
            plan = try await workspace.taskPlan(id)
            if !plan!.tasks.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = plan!.tasks.first?.id }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func runPlanFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let toml = try String(contentsOf: url, encoding: .utf8)
            plan = try await workspace.runTaskPlan(toml: toml, source: url.path)
            selectedTaskID = plan?.tasks.first?.id
            summaries = try await workspace.taskSummaries()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func update(_ task: HiveTask, method: String, deny: Bool? = nil) async {
        guard let plan else { return }
        do {
            self.plan = try await workspace.updateTask(method, planID: plan.id, taskID: task.id, deny: deny)
            summaries = try await workspace.taskSummaries()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func symbol(for state: String) -> String {
        switch state {
        case "succeeded": "checkmark.circle.fill"
        case "failed", "cancelled", "skipped": "xmark.circle.fill"
        case "running", "blocked": "gearshape.2.fill"
        case "approval": "hand.raised.fill"
        default: "circle"
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "succeeded": .green
        case "failed", "cancelled", "skipped": .red
        case "running": .blue
        case "blocked", "approval": .orange
        default: .secondary
        }
    }
}
