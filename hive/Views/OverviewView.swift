import SwiftUI

/// ⇧⌘O: every agent at a glance, its live screen in a card, grouped by environment
/// with the ones that need you first. Click a card to go to it.
struct OverviewView: View {
    @ObservedObject var viewModel: AppViewModel

    private var groups: [(id: String, name: String, agents: [HiveAgent])] {
        let agents = viewModel.agents.sorted { $0.stateRank < $1.stateRank }
        let byEnvironment = Dictionary(grouping: agents, by: \.environmentID)
        
        return byEnvironment
            .map { (id: $0.key, agents: $0.value) }
            .map { group in
                let env = viewModel.environments.first(where: { $0.id == group.id })
                let name = env.map { $0.name.isEmpty ? $0.id : $0.name } ?? group.id
                return (id: group.id, name: name, agents: group.agents)
            }
            .sorted { lhs, rhs in
                let left = lhs.agents.first?.stateRank ?? .max
                let right = rhs.agents.first?.stateRank ?? .max
                return left != right ? left < right : lhs.name < rhs.name
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            
            Group {
                if viewModel.agents.isEmpty {
                    ContentUnavailableView(
                        "No Agents",
                        systemImage: "sparkles",
                        description: Text("Start an agent from the sidebar and it shows up here.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            ForEach(groups, id: \.id) { group in
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.tertiary)
                                        Text(group.name)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.secondary)
                                            .kerning(0.5)
                                    }
                                    .padding(.leading, 4)
                                    
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 20)], spacing: 20) {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onKeyPress(.escape) {
            viewModel.showOverview(false)
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.hiveAmber)
                Text("Overview")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            
            Spacer()
            
            Button(action: { viewModel.showOverview(false) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}

private struct AgentCard: View {
    let agent: HiveAgent
    let workspace: HiveWorkspaceStore
    let open: () -> Void

    @State private var lines: [String] = []
    @State private var isHovering = false

    private var indicatorState: StatusIndicator.IndicatorState {
        switch agent.state {
        case "blocked": return .needsAttention
        case "working": return .processing
        default: return .ready
        }
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    StatusIndicator(state: indicatorState)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(agent.name.isEmpty ? agent.kind : agent.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.primary.opacity(0.9))
                            
                            AgentProviderIcon(kind: agent.kind, size: 10)
                                .opacity(0.7)
                        }
                        
                        Text(agentStateTitle(agent.state))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(agent.state == "blocked" ? Color.hiveAmber : .secondary)
                            .textCase(.uppercase)
                            .kerning(0.5)
                    }
                    
                    Spacer(minLength: 8)
                    
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color.primary.opacity(0.02))

                Divider().opacity(0.5)

                // The live screen preview
                ZStack(alignment: .bottomLeading) {
                    Color.black.opacity(0.03)
                    
                    if lines.isEmpty {
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Connecting to stream...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(lines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }
                        .padding(12)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipped()
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.04 : 0.02))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        agent.state == "blocked" ? Color.hiveAmber.opacity(0.3) : Color.primary.opacity(isHovering ? 0.12 : 0.06),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(isHovering ? 0.08 : 0.02), radius: isHovering ? 12 : 4, y: isHovering ? 4 : 2)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.spring(duration: 0.3), value: isHovering)
        .help(agent.reason ?? "\(agent.kind) · \(agentStateTitle(agent.state))")
        .task(id: agent.paneID) {
            guard let paneID = agent.paneID else { return }
            while !Task.isCancelled {
                if let read = try? await workspace.readPane(paneID, lines: 14) {
                    let reversed = read.reversed()
                    let trimmedDrop = reversed.drop { line in
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        return trimmed.isEmpty
                    }
                    let restored = Array(trimmedDrop.reversed())
                    lines = restored
                }
                try? await Task.sleep(for: .seconds(2.0))
            }
        }
    }
}

