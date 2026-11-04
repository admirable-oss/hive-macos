import SwiftUI

/// A saved machine's SSH reachability, remote agents, and connection details.
struct MachineInspectorView: View {
    let machine: SavedHiveMachine
    @ObservedObject var viewModel: AppViewModel

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
                        }
                        .font(.callout)
                    }
                }
            }
            Text("Remote tabs and terminals are not yet available in the desktop app.")
                .font(.callout).foregroundStyle(.secondary)

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
        }
    }
}
