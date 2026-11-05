import SwiftUI

/// M7 · Agent delegation and report-back. Start a helper agent from a parent, attach it to the
/// parent's work, steer or stop it, and return its report to the parent and the Inbox. Parent and
/// child relationships are shown explicitly, and each helper's reach stays visible.
struct DelegationView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var commandCenter: CommandCenterStore
    /// A parent to preselect, when opened from an agent.
    var initialParentID: String?

    @Environment(\.dismiss) private var dismiss
    @State private var parentAgentID = ""
    @State private var helperKind = ""
    @State private var environmentID = ""
    @State private var title = ""
    @State private var instruction = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var steering: Delegation?
    @State private var steerText = ""

    private var runningAgents: [HiveAgent] { viewModel.agents.filter { $0.state != "exited" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    form
                    children
                }
                .padding(20)
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: commandCenter.delegations.map(\.id))
                .animation(.spring(response: 0.32, dampingFraction: 0.85), value: errorMessage)
            }
        }
        .frame(width: 620, height: 620)
        .onAppear {
            parentAgentID = initialParentID ?? runningAgents.first?.id ?? ""
            helperKind = viewModel.agentKinds.first?.id ?? ""
            environmentID = viewModel.environments.first?.id ?? ""
        }
    }

    private var header: some View {
        HiveSheetHeader(
            symbol: "arrow.triangle.branch",
            title: "Delegate a helper task",
            subtitle: "Start a helper for an agent and return its report to the parent.",
            onClose: { dismiss() }
        )
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HiveSectionTitle(title: "New helper", symbol: "plus.circle")
            VStack(alignment: .leading, spacing: 12) {
            Picker("For agent", selection: $parentAgentID) {
                Text("Choose a parent").tag("")
                ForEach(runningAgents) { agent in
                    Text(agent.name.isEmpty ? agent.kind : agent.name).tag(agent.id)
                }
            }

            HStack(spacing: 14) {
                Picker("Helper", selection: $helperKind) {
                    ForEach(viewModel.agentKinds) { kind in Text(kind.name.isEmpty ? kind.id : kind.name).tag(kind.id) }
                }
                Picker("In environment", selection: $environmentID) {
                    ForEach(viewModel.environments) { environment in
                        Text(environment.name.isEmpty ? environment.id : environment.name).tag(environment.id)
                    }
                }
            }

            TextField("Title (what the helper is doing)", text: $title)
                .textFieldStyle(.hive)
            TextField("Instruction for the helper (optional)", text: $instruction, axis: .vertical)
                .textFieldStyle(.hive)
                .lineLimit(1...4)

            permissionsNote

            HStack(spacing: 10) {
                Button { Task { await startHelper() } } label: {
                    Label("Start helper", systemImage: "play.fill")
                }
                .buttonStyle(.hivePrimary)
                .disabled(!canStart || isWorking)
                if isWorking { ProgressView().controlSize(.small) }
            }
            if let errorMessage { HiveNotice(text: errorMessage) }
            }
            .hiveCard(padding: 14)
        }
    }

    private var permissionsNote: some View {
        HiveNotice(
            text: "This helper runs as \(kindName) in \(environmentName) — it can read and change that environment's files and terminals, exactly like an agent you start yourself.",
            kind: .info
        )
    }

    private var children: some View {
        VStack(alignment: .leading, spacing: 10) {
            HiveSectionTitle(title: "Helpers", symbol: "person.2", count: commandCenter.delegations.count)
            if commandCenter.delegations.isEmpty {
                Text("No helpers yet. Start one above.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ForEach(commandCenter.delegations) { delegation in
                    delegationCard(delegation)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
        }
    }

    private func delegationCard(_ delegation: Delegation) -> some View {
        let helper = delegation.helperAgentID.flatMap { id in viewModel.agents.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AgentProviderIcon(kind: delegation.helperKind, size: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text(delegation.title).font(.system(size: 12.5, weight: .semibold))
                    Text("\(delegation.parentName) → \(kindLabel(delegation.helperKind)) · \(delegation.environmentID)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                stateBadge(delegation, helper: helper)
            }

            if let instruction = delegation.instruction, !instruction.isEmpty {
                Text(instruction).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            if let report = delegation.report, !report.isEmpty {
                Text(report).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            }

            HStack(spacing: 7) {
                if let helper, helper.state != "exited" {
                    Button("Steer") { steering = delegation; steerText = "" }
                        .buttonStyle(.hiveCompact)
                    Button("Open") { viewModel.openAgent(helper.id) }
                        .buttonStyle(.hiveCompact)
                    Button("Return report") { Task { await returnReport(delegation, helper: helper) } }
                        .buttonStyle(.hivePrimaryCompact)
                    Button("Stop", role: .destructive) { Task { await stop(delegation, helper: helper) } }
                        .buttonStyle(.hiveCompact)
                } else {
                    Text("Helper is not running").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Forget", role: .destructive) { commandCenter.removeDelegation(delegation.id) }
                    .buttonStyle(.hiveCompact)
            }
        }
        .hiveCard(padding: 12, interactive: true)
        .alert("Steer “\(delegation.title)”", isPresented: Binding(get: { steering?.id == delegation.id }, set: { if !$0 { steering = nil } })) {
            TextField("Message", text: $steerText)
            Button("Cancel", role: .cancel) { steering = nil }
            Button("Send") {
                let text = steerText
                steering = nil
                if let helper { Task { await steer(helper: helper, text: text) } }
            }
            .disabled(steerText.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: { Text("The helper gets this as a prompt.") }
    }

    private func stateBadge(_ delegation: Delegation, helper: HiveAgent?) -> some View {
        let state = helper?.state ?? (delegation.state == .running ? "unknown" : delegation.state.rawValue)
        return HiveChip(
            text: delegation.state == .reported ? "Reported" : agentStateTitle(state),
            tint: delegation.state == .reported ? .blue : (state == "working" || state == "blocked" ? agentStateColor(state) : nil),
            symbol: "circle.fill"
        )
    }

    private var canStart: Bool {
        !parentAgentID.isEmpty && !helperKind.isEmpty && !environmentID.isEmpty
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var kindName: String {
        viewModel.agentKinds.first { $0.id == helperKind }?.name ?? (helperKind.isEmpty ? "the helper" : helperKind)
    }

    private var environmentName: String {
        viewModel.environments.first { $0.id == environmentID }.map { $0.name.isEmpty ? $0.id : $0.name } ?? environmentID
    }

    private func kindLabel(_ id: String) -> String {
        viewModel.agentKinds.first { $0.id == id }?.name ?? id
    }

    // MARK: Actions

    private func startHelper() async {
        guard let parent = viewModel.agents.first(where: { $0.id == parentAgentID }) else { return }
        let parentName = parent.name.isEmpty ? parent.kind : parent.name
        isWorking = true
        defer { isWorking = false }
        var delegation = Delegation(
            parentAgentID: parent.id,
            parentName: parentName,
            taskID: nil,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            helperKind: helperKind,
            environmentID: environmentID,
            instruction: instruction.isEmpty ? nil : instruction
        )
        commandCenter.addDelegation(delegation)
        do {
            let agent = try await viewModel.workspace.startAgent(kind: helperKind, environmentID: environmentID)
            delegation.helperAgentID = agent.id
            commandCenter.attachHelper(agent.id, to: delegation.id)
            if let text = delegation.instruction, !text.isEmpty {
                _ = try? await viewModel.workspace.prompt(agent: agent.id, text: text, wait: false)
            }
            title = ""
            instruction = ""
            errorMessage = nil
        } catch {
            commandCenter.markStopped(delegation.id)
            errorMessage = error.localizedDescription
        }
    }

    private func steer(helper: HiveAgent, text: String) async {
        do {
            _ = try await viewModel.workspace.prompt(agent: helper.id, text: text, wait: false)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func stop(_ delegation: Delegation, helper: HiveAgent) async {
        do {
            try await viewModel.workspace.stopAgent(helper.id)
            commandCenter.markStopped(delegation.id)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func returnReport(_ delegation: Delegation, helper: HiveAgent) async {
        isWorking = true
        defer { isWorking = false }
        var report = "Helper finished with state \(helper.state)."
        if let paneID = helper.paneID, let lines = try? await viewModel.workspace.readPane(paneID, lines: 40) {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { report = text }
        }
        commandCenter.markReported(delegation.id, report: report)
        if let parent = viewModel.agents.first(where: { $0.id == delegation.parentAgentID }) {
            let message = "Report from your helper “\(delegation.title)”:\n\n\(report)"
            _ = try? await viewModel.workspace.prompt(agent: parent.id, text: message, wait: false)
        }
        errorMessage = nil
    }
}
