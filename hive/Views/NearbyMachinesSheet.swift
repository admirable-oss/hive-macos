import SwiftUI

struct NearbyMachinesSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: HiveNearbyMachine?
    @State private var identity: HivePairIdentity?
    @State private var machineName = ""
    @State private var isChecking = false
    @State private var isPairing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nearby Hive machines").font(.title2.weight(.semibold))
                    Text("Discovery only finds announcements. Pairing verifies and pins the runtime’s identity.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await viewModel.discoverMachines() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Scan the local network again")
            }
            if viewModel.nearbyMachines.isEmpty {
                ContentUnavailableView("No announcements found", systemImage: "dot.radiowaves.left.and.right", description: Text("Only Hive runtimes with network discovery enabled appear here. You can also add a machine by SSH.")).frame(maxHeight: 180)
            } else {
                List(viewModel.nearbyMachines) { machine in
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.name).font(.callout.weight(.medium))
                            Text("\(machine.host):\(machine.port) · \(machine.id)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            if let note = machine.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if machine.machine != nil {
                            Label("Paired", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                        } else {
                            Button("Verify & Pair…") { beginPairing(machine) }
                                .disabled(isChecking || !((machine.capabilities ?? []).contains("ssh")))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            if isChecking { ProgressView("Verifying runtime identity…").controlSize(.small) }
            if let identity, let selected {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Identity verified", systemImage: "checkmark.shield.fill").font(.headline).foregroundStyle(.green)
                    LabeledContent("Runtime", value: identity.proof.name)
                    LabeledContent("Host", value: identity.proof.hostname ?? selected.host)
                    LabeledContent("Platform", value: identity.proof.platform)
                    LabeledContent("Hive", value: identity.proof.version)
                    LabeledContent("Identity", value: identity.fingerprint).textSelection(.enabled)
                    TextField("Save as", text: $machineName).textFieldStyle(.roundedBorder)
                    Text("Pairing saves this SSH machine and pins the verified identity shown above.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { self.identity = nil; self.selected = nil }
                        Button("Pair and Trust") { Task { await pair(selected, proof: identity) } }
                            .buttonStyle(.borderedProminent).disabled(isPairing || machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(12)
                .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 590)
        .task { await viewModel.discoverMachines() }
    }

    private func beginPairing(_ machine: HiveNearbyMachine) {
        selected = machine
        identity = nil
        machineName = machine.name
        errorMessage = nil
        isChecking = true
        Task {
            defer { isChecking = false }
            do { identity = try await viewModel.checkPairIdentity(machine, as: machineName) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func pair(_ machine: HiveNearbyMachine, proof: HivePairIdentity) async {
        isPairing = true
        defer { isPairing = false }
        do {
            try await viewModel.pairMachine(machine, as: machineName.trimmingCharacters(in: .whitespacesAndNewlines), expectedID: proof.proof.id)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
