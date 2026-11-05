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
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "dot.radiowaves.left.and.right",
                title: "Nearby Hive machines",
                subtitle: "Discovery only finds announcements. Pairing verifies and pins the runtime’s identity.",
                onClose: { dismiss() }
            ) {
                Button { Task { await viewModel.discoverMachines() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(HiveIconButtonStyle())
                    .help("Scan the local network again")
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            if viewModel.nearbyMachines.isEmpty {
                ContentUnavailableView("No announcements found", systemImage: "dot.radiowaves.left.and.right", description: Text("Only Hive runtimes with network discovery enabled appear here. You can also add a machine by SSH.")).frame(maxHeight: 180)
            } else {
                ForEach(viewModel.nearbyMachines) { machine in
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.hiveAmber)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hiveAmber.opacity(0.13)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(machine.name).font(.system(size: 12.5, weight: .semibold))
                            Text("\(machine.host):\(machine.port) · \(machine.id)")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            if let note = machine.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if machine.machine != nil {
                            HiveChip(text: "Paired", tint: .green, symbol: "checkmark.seal.fill")
                        } else {
                            Button("Verify & Pair…") { beginPairing(machine) }
                                .buttonStyle(.hivePrimaryCompact)
                                .disabled(isChecking || !((machine.capabilities ?? []).contains("ssh")))
                        }
                    }
                    .hiveCard(padding: 10, interactive: true, isSelected: selected?.id == machine.id)
                }
            }
            if isChecking { ProgressView("Verifying runtime identity…").controlSize(.small) }
            if let identity, let selected {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Identity verified", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
                    LabeledContent("Runtime", value: identity.proof.name)
                    LabeledContent("Host", value: identity.proof.hostname ?? selected.host)
                    LabeledContent("Platform", value: identity.proof.platform)
                    LabeledContent("Hive", value: identity.proof.version)
                    LabeledContent("Identity", value: identity.fingerprint).textSelection(.enabled)
                    TextField("Save as", text: $machineName).textFieldStyle(.hive)
                    Text("Pairing saves this SSH machine and pins the verified identity shown above.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Cancel") { self.identity = nil; self.selected = nil }
                            .buttonStyle(.hive)
                        Button { Task { await pair(selected, proof: identity) } } label: { Label("Pair and Trust", systemImage: "checkmark.shield") }
                            .buttonStyle(.hivePrimary)
                            .disabled(isPairing || machineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .font(.system(size: 12))
                .hiveCard(padding: 14, tint: .green)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
            if let errorMessage { HiveNotice(text: errorMessage) }
            }
            .padding(20)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: identity?.fingerprint)
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.nearbyMachines.map(\.id))
            }
        }
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
