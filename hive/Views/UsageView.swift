import SwiftUI

/// M7 · Usage and capacity. Hive shows provider usage or quota only where the provider exposes a
/// reliable source, and labels that source and its last refresh. Where there is no such source it
/// says so plainly rather than guessing from terminal output.
struct UsageView: View {
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var refreshedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    capacitySection
                    providerSection
                    policyNote
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 600)
        .task {
            while !Task.isCancelled {
                refreshedAt = Date()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var header: some View {
        HiveSheetHeader(
            symbol: "gauge.with.dots.needle.33percent",
            title: "Usage & capacity",
            subtitle: "Source: Hive daemon · updated \(refreshedAt.formatted(date: .omitted, time: .standard))",
            onClose: { dismiss() }
        ) {
            HiveChip(
                text: viewModel.isConnected ? "Connected" : "Offline",
                tint: viewModel.isConnected ? .green : .red,
                symbol: viewModel.isConnected ? "bolt.fill" : "bolt.slash.fill"
            )
        }
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HiveSectionTitle(title: "Capacity", symbol: "square.stack.3d.up")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 10)], spacing: 10) {
                metric("Environments", "\(viewModel.environments.count)", "folder", "\(worktreeCount) worktrees")
                metric("Agents", "\(viewModel.agents.count)", "sparkles", "\(workingCount) running · \(blockedCount) waiting")
                metric("Machines", "\(viewModel.machines.count)", "server.rack", "\(reachableMachines) reachable")
                metric("Panes", "\(viewModel.workspace.panes.count)", "rectangle.split.2x1", "\(viewModel.workspace.tabs.count) tabs")
                metric("Listening ports", "\(portCount)", "network", portCount == 0 ? "none detected" : "scanned locally")
                metric("Connection", viewModel.isConnected ? "Connected" : "Unavailable", "bolt.horizontal", apiLevelLabel)
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ symbol: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.hiveAmber)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.hiveAmber.opacity(0.14)))
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .hiveCard(padding: 12, interactive: true)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: value)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HiveSectionTitle(title: "Providers", symbol: "sparkles", count: providers.count)
            Text("Usage and quota appear only when a provider exposes a reliable source.")
                .font(.caption).foregroundStyle(.secondary)
            if providers.isEmpty {
                Text("No agents are installed or running.")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(providers, id: \.self) { provider in
                    HStack(spacing: 10) {
                        AgentProviderIcon(kind: provider, size: 12)
                        Text(provider.capitalized).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        HiveChip(text: "No reliable usage source", symbol: "questionmark")
                    }
                    .hiveCard(padding: 10, interactive: true)
                }
            }
        }
    }

    private var policyNote: some View {
        HiveNotice(
            text: "Hive Desktop never estimates usage from terminal output. Capacity numbers come from the daemon's live snapshot; provider quotas are shown only through a source the provider publishes.",
            kind: .info
        )
    }

    // MARK: Derived values

    private var providers: [String] {
        let running = Set(viewModel.agents.map(\.kind))
        let installed = Set(viewModel.agentKinds.map(\.id))
        return Array(running.union(installed)).filter { !$0.isEmpty }.sorted()
    }

    private var worktreeCount: Int { viewModel.environments.filter { $0.worktree != nil }.count }
    private var workingCount: Int { viewModel.agents.filter { $0.state == "working" }.count }
    private var blockedCount: Int { viewModel.agents.filter { $0.state == "blocked" }.count }
    private var reachableMachines: Int { viewModel.machineStatuses.values.filter(\.reachable).count }
    private var portCount: Int { viewModel.listeningPorts.values.reduce(0) { $0 + $1.count } }

    private var apiLevelLabel: String {
        switch viewModel.workspace.connection {
        case .connected(let version, let level): "Hive \(version) · API \(level)"
        case .connecting: "Connecting…"
        case .unavailable: "No daemon"
        }
    }
}
