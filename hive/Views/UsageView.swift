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
            Divider()
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
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Color.hiveAmber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage & capacity").font(.title3.weight(.semibold))
                Text("Source: Hive daemon · updated \(refreshedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var capacitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capacity").font(.subheadline.weight(.semibold))
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
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Color.hiveAmber)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers").font(.subheadline.weight(.semibold))
            Text("Usage and quota appear only when a provider exposes a reliable source.")
                .font(.caption).foregroundStyle(.secondary)
            if providers.isEmpty {
                Text("No agents are installed or running.")
                    .font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(providers, id: \.self) { provider in
                    HStack(spacing: 10) {
                        AgentProviderIcon(kind: provider, size: 12)
                        Text(provider.capitalized).font(.callout.weight(.medium))
                        Spacer()
                        Label("No reliable usage source", systemImage: "questionmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var policyNote: some View {
        Label("Hive Desktop never estimates usage from terminal output. Capacity numbers come from the daemon's live snapshot; provider quotas are shown only through a source the provider publishes.",
              systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
