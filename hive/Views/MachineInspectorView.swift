import SwiftUI

/// A saved machine is searchable before remote workspace support is available.
/// This sheet verifies its SSH reachability and shows the saved connection details.
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

            Text("Remote workspace tabs and terminals will be available when machine support is connected to the desktop workspace.")
                .font(.callout)
                .foregroundStyle(.secondary)

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
