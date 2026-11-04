import SwiftUI

/// ⇧⌘O: every agent at a glance, its live screen in a card, grouped by environment
/// with the ones that need you first. Click a card to go to it.
struct OverviewView: View {
    @ObservedObject var viewModel: AppViewModel

    private var groups: [(environment: String, agents: [HiveAgent])] {
        let agents = viewModel.agents.sorted { $0.stateRank < $1.stateRank }
        let byEnvironment = Dictionary(grouping: agents, by: \.environmentID)
        // Environments with an agent that needs you come first.
        return byEnvironment
            .map { (environment: $0.key, agents: $0.value) }
            .sorted { lhs, rhs in
                let left = lhs.agents.first?.stateRank ?? .max
                let right = rhs.agents.first?.stateRank ?? .max
                return left != right ? left < right : lhs.environment < rhs.environment
            }
    }

    var body: some View {
        Group {
            if viewModel.agents.isEmpty {
                ContentUnavailableView(
                    "No Agents",
                    systemImage: "sparkles",
                    description: Text("Start an agent from the sidebar and it shows up here.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(groups, id: \.environment) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                Label(group.environment, systemImage: "folder")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14)], spacing: 14) {
                                    ForEach(group.agents) { agent in
                                        AgentCard(agent: agent, workspace: viewModel.workspace) {
                                            viewModel.openAgent(agent.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onKeyPress(.escape) {
            viewModel.showingOverview = false
            return .handled
        }
    }
}

private struct AgentCard: View {
    let agent: HiveAgent
    let workspace: HiveWorkspaceStore
    let open: () -> Void

    @State private var lines: [String] = []
    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(agentStateColor(agent.state))
                        .frame(width: 8, height: 8)
                        .shadow(color: agent.state == "working" ? agentStateColor(agent.state).opacity(0.7) : .clear, radius: 3)
                    Text(agent.name.isEmpty ? agent.kind : agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(agent.kind)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(agentStateTitle(agent.state))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(agent.state == "blocked" ? agentStateColor(agent.state) : .secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)

                Divider()

                // The live screen, read-only.
                Text(lines.isEmpty ? " " : lines.joined(separator: "\n"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(14)
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .bottomLeading)
                    .padding(10)
                    .clipped()
            }
            .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
            .clipShape(shape)
            .overlay(shape.strokeBorder(agent.state == "blocked" ? agentStateColor(agent.state).opacity(0.6) : Color.primary.opacity(isHovering ? 0.18 : 0.08)))
            .shadow(color: .black.opacity(isHovering ? 0.12 : 0), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(agent.reason ?? "\(agent.kind) · \(agentStateTitle(agent.state))")
        .task(id: agent.paneID) {
            guard let paneID = agent.paneID else { return }
            while !Task.isCancelled {
                if let read = try? await workspace.readPane(paneID, lines: 14) {
                    // Trailing blank rows would push the content off the card.
                    lines = Array(read.reversed().drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed())
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}
