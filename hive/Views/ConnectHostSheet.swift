import SwiftUI

/// Works with Hive on any SSH host without saving it first (`hive --remote host`): checks it,
/// installs Hive there only after you agree, lists its agents to attach to, and can save it.
struct ConnectHostSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case entering
        case checking
        /// Hive isn't on the host; installing it needs a yes.
        case needsInstall(String)
        case connected(version: String)
        case failed(String)
    }

    @State private var host = ""
    @State private var phase: Phase = .entering
    @State private var agents: [HiveAgent] = []
    @State private var saveName = ""
    @State private var saved = false

    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "network",
                title: "Connect to Host",
                subtitle: "Any host you can reach with ssh. Hive runs there and stays there; nothing is saved here unless you ask.",
                onClose: { dismiss() }
            )

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("user@buildbox, or a name from ~/.ssh/config", text: $host)
                        .textFieldStyle(.hive)
                        .onSubmit { Task { await check(install: false) } }
                        .disabled(phase == .checking)
                    Button {
                        Task { await check(install: false) }
                    } label: {
                        if phase == .checking { ProgressView().controlSize(.small) } else { Text("Connect") }
                    }
                    .buttonStyle(.hivePrimary)
                    .disabled(trimmedHost.isEmpty || phase == .checking)
                }

                switch phase {
                case .entering, .checking:
                    EmptyView()
                case .needsInstall(let message):
                    installConsent(message)
                case .failed(let message):
                    HiveNotice(text: message)
                case .connected(let version):
                    connected(version)
                }
            }
            .padding(20)
        }
        .frame(width: 560)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: phase)
    }

    private func installConsent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hive isn’t installed on \(trimmedHost)", systemImage: "shippingbox")
                .font(.system(size: 13, weight: .semibold))
            Text("Installing copies the hive program for that machine into your home directory there, over ssh. It doesn’t need administrator rights and changes nothing else. Its daemon then starts there the first time it’s needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack {
                Spacer()
                Button("Cancel") { phase = .entering }
                    .buttonStyle(.hive)
                Button { Task { await check(install: true) } } label: { Label("Install Hive There", systemImage: "arrow.down.circle") }
                    .buttonStyle(.hivePrimary)
            }
        }
        .hiveCard(padding: 14, tint: .hiveAmber)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func connected(_ version: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Hive \(version) on \(trimmedHost)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer()
                Button { viewModel.openSSHShell(host: trimmedHost); dismiss() } label: { Label("SSH Shell", systemImage: "terminal") }
                    .buttonStyle(.hiveCompact)
            }

            HiveSectionTitle(title: "Agents", symbol: "sparkles", count: agents.isEmpty ? nil : agents.count)
            if agents.isEmpty {
                Text("No agents are running there.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(agents) { agent in
                            HStack(spacing: 10) {
                                AgentProviderIcon(kind: agent.kind, size: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(agent.name.isEmpty ? agent.kind : agent.name).font(.system(size: 12.5, weight: .medium))
                                    Text(agent.environmentID).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                HiveChip(text: agentStateTitle(agent.state), tint: agentStateColor(agent.state))
                                Button("Attach") { viewModel.openRemoteHostAgent(host: trimmedHost, agent: agent); dismiss() }
                                    .buttonStyle(.hiveCompact)
                                    .disabled(agent.state == "exited")
                            }
                            .padding(10)
                            .hiveCard(padding: 0)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            Divider().opacity(0.5)
            HStack(spacing: 8) {
                if saved {
                    Label("Saved. It’s in the sidebar with your other machines.", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Name", text: $saveName)
                        .textFieldStyle(.hive)
                        .frame(width: 180)
                    Button("Save as Machine") { Task { await save() } }
                        .buttonStyle(.hive)
                        .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("Keeps it in the sidebar, with its environments and agents")
                }
                Spacer()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// `hive --remote host status`; with `install`, `--yes` lets Hive install itself there first.
    private func check(install: Bool) async {
        let host = trimmedHost
        guard !host.isEmpty else { return }
        phase = .checking
        let base = ["--remote", host] + (install ? ["--yes"] : [])
        do {
            let output = try await viewModel.cliService.run(base + ["--json", "status"])
            let status = try JSONDecoder().decode(HiveRuntimeStatus.self, from: Data(output.utf8))
            let list = try? await viewModel.cliService.run(["--remote", host, "--json", "agent", "list"])
            agents = list.flatMap { try? JSONDecoder().decode(HiveAgentList.self, from: Data($0.utf8)).agents } ?? []
            if saveName.isEmpty { saveName = host.split(separator: "@").last.map(String.init) ?? host }
            phase = .connected(version: status.version)
        } catch {
            let message = error.localizedDescription
            // Without --yes, Hive won't install itself and says so.
            if !install, message.localizedCaseInsensitiveContains("install") {
                phase = .needsInstall(message)
            } else {
                phase = .failed(message)
            }
        }
    }

    private func save() async {
        await viewModel.addMachine(name: saveName.trimmingCharacters(in: .whitespaces), host: trimmedHost)
        saved = true
    }
}
