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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(Color.hiveAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.title2.weight(.semibold))
                    Text(machine.host).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

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

            if let agents = viewModel.machineAgents[machine.name], !agents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agents").font(.headline)
                    ForEach(agents) { agent in
                        HStack {
                            Circle().fill(agentStateColor(agent.state)).frame(width: 7, height: 7)
                            Text(agent.name.isEmpty ? agent.kind : agent.name)
                            Spacer()
                            Text(agentStateTitle(agent.state)).foregroundStyle(.secondary)
                            Button("Open") { viewModel.openRemoteAgent(agent, on: machine) }
                                .buttonStyle(.borderless)
                        }
                        .font(.callout)
                    }
                }
            }
            if viewModel.machineAgents[machine.name]?.isEmpty != false {
                Text("No remote agents are currently available to attach.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Remote workspace").font(.headline)
                HStack {
                    TextField("Environment ID", text: $environmentID)
                    TextField("Absolute remote path", text: $environmentPath)
                }
                Button("Create Environment") {
                    Task {
                        await viewModel.createRemoteEnvironment(on: machine, id: environmentID.trimmingCharacters(in: .whitespacesAndNewlines), path: environmentPath.trimmingCharacters(in: .whitespacesAndNewlines))
                        if let error = viewModel.sidebarError { actionError = error } else { environmentID = ""; environmentPath = "" }
                    }
                }
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
                    .disabled(selectedEnvironmentID.isEmpty || selectedAgentKind.isEmpty)
                }
                Button { viewModel.openRemoteShell(machine) } label: { Label("Open SSH Shell", systemImage: "terminal") }
                    .buttonStyle(.bordered)
                if let actionError { Text(actionError).font(.caption).foregroundStyle(.red) }
            }
            .font(.callout)

            if let environments = viewModel.machineEnvironments[machine.name], !environments.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Environments").font(.headline)
                    ForEach(environments) { env in
                        LabeledContent(env.name.isEmpty ? env.id : env.name, value: env.path)
                            .font(.caption)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Close") { viewModel.inspectedMachine = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Check Connection") { Task { await viewModel.refreshMachineStatus() } }
                    .disabled(viewModel.checkingMachine)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task(id: machine.name) {
            if viewModel.machineStatus?.name != machine.name {
                await viewModel.refreshMachineStatus()
            }
            if let env = viewModel.machineEnvironments[machine.name]?.first { selectedEnvironmentID = env.id }
            if let kind = viewModel.machineAgentKinds[machine.name]?.first { selectedAgentKind = kind.id }
        }
    }
}
