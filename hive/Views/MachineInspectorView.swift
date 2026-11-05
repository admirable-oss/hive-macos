import SwiftUI

/// A saved machine's SSH reachability, remote agents, and connection details.
struct MachineInspectorView: View {
    let machine: SavedHiveMachine
    @ObservedObject var viewModel: AppViewModel
    @State private var environmentID = ""
    @State private var environmentPath = ""
    @State private var selectedEnvironmentID = ""
    @State private var selectedAgentKind = ""
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HiveSheetHeader(symbol: "server.rack", title: machine.name, subtitle: machine.host, onClose: { viewModel.inspectedMachine = nil }) {
            if let status = viewModel.machineStatus, status.name == machine.name {
                HiveChip(text: status.reachable ? "Reachable" : "Unavailable", tint: status.reachable ? .green : .red, symbol: "circle.fill")
            }
        }
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Session", value: machine.session ?? "Default")
            if let status = viewModel.machineStatus, status.name == machine.name {
                LabeledContent("Connection") {
                    Label(status.reachable ? "Reachable" : "Unavailable",
                          systemImage: status.reachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.reachable ? .green : .red)
                }
                if let error = status.error, !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
            } else if viewModel.checkingMachine {
                Label("Checking connection…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                Text("Connection has not been checked.").foregroundStyle(.secondary)
            }
            }
            .font(.system(size: 12))
            .hiveCard(padding: 12)

            if let agents = viewModel.machineAgents[machine.name], !agents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HiveSectionTitle(title: "Agents", symbol: "sparkles", count: agents.count)
                    ForEach(agents) { agent in
                        HStack(spacing: 8) {
                            AgentProviderIcon(kind: agent.kind, size: 12)
                            Text(agent.name.isEmpty ? agent.kind : agent.name).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            HiveChip(text: agentStateTitle(agent.state), tint: agent.state == "working" || agent.state == "blocked" ? agentStateColor(agent.state) : nil)
                            Button("Open") { viewModel.openRemoteAgent(agent, on: machine) }
                                .buttonStyle(.hiveCompact)
                        }
                        .hiveCard(padding: 8, interactive: true)
                    }
                }
            }
            if viewModel.machineAgents[machine.name]?.isEmpty != false {
                Text("No remote agents are currently available to attach.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 9) {
                HiveSectionTitle(title: "Remote workspace", symbol: "folder.badge.plus")
                VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Environment ID", text: $environmentID).textFieldStyle(.hive)
                    TextField("Absolute remote path", text: $environmentPath).textFieldStyle(.hive)
                }
                Button("Create Environment") {
                    Task {
                        await viewModel.createRemoteEnvironment(on: machine, id: environmentID.trimmingCharacters(in: .whitespacesAndNewlines), path: environmentPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        if let error = viewModel.sidebarError { actionError = error } else { environmentID = ""; environmentPath = "" }
                    }
                }
                .buttonStyle(.hiveCompact)
                .disabled(environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !environmentPath.hasPrefix("/"))

                HStack {
                    Picker("Environment", selection: $selectedEnvironmentID) {
                        ForEach(viewModel.machineEnvironments[machine.name] ?? []) { env in Text(env.name.isEmpty ? env.id : env.name).tag(env.id) }
                    }
                    Picker("Agent", selection: $selectedAgentKind) {
                        ForEach(viewModel.machineAgentKinds[machine.name] ?? []) { kind in Text(kind.name).tag(kind.id) }
                    }
                    Button("Start") {
                        Task {
                            await viewModel.startRemoteAgent(on: machine, kind: selectedAgentKind, environmentID: selectedEnvironmentID)
                            actionError = viewModel.sidebarError
                        }
                    }
                    .buttonStyle(.hivePrimaryCompact)
                    .disabled(selectedEnvironmentID.isEmpty || selectedAgentKind.isEmpty)
                }
                Button { viewModel.openRemoteShell(machine) } label: { Label("Open SSH Shell", systemImage: "terminal") }
                    .buttonStyle(.hiveCompact)
                if let actionError { HiveNotice(text: actionError) }
                }
                .hiveCard(padding: 12)
            }
            .font(.system(size: 12))

            if let environments = viewModel.machineEnvironments[machine.name], !environments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HiveSectionTitle(title: "Environments", symbol: "folder", count: environments.count)
                    ForEach(environments) { env in
                        LabeledContent(env.name.isEmpty ? env.id : env.name, value: env.path)
                            .font(.caption)
                    }
                }
            }

            HStack {
                Spacer()
                Button { Task { await viewModel.refreshMachineStatus() } } label: {
                    Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.hivePrimary)
                .disabled(viewModel.checkingMachine)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        }
        }
        .frame(width: 460, height: 600)
        .task(id: machine.name) {
            if viewModel.machineStatus?.name != machine.name {
                await viewModel.refreshMachineStatus()
            }
            if let env = viewModel.machineEnvironments[machine.name]?.first { selectedEnvironmentID = env.id }
            if let kind = viewModel.machineAgentKinds[machine.name]?.first { selectedAgentKind = kind.id }
        }
    }
}
