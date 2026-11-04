import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarAgentStore: ObservableObject {
    static let shared = MenuBarAgentStore()

    @Published private(set) var agents: [HiveAgent] = []
    @Published private(set) var connection: HiveWorkspaceStore.Connection = .connecting
    @Published private(set) var actionError: String?

    private var workspace: HiveWorkspaceStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var sessionName: String?
    private var connectingSession: String?
    var openAgentWindow: ((String) -> Void)?

    var needsAttention: Bool { agents.contains { $0.state == "blocked" } }

    func start(sessionName: String) {
        guard self.sessionName != sessionName || (workspace == nil && connectingSession != sessionName) else { return }
        selectSession(sessionName)
    }

    func selectSession(_ name: String) {
        guard sessionName != name || (workspace == nil && connectingSession != name) else { return }
        sessionName = name
        AgentNotifier.shared.resetStateTracking()
        workspace?.stop()
        subscriptions.removeAll()
        workspace = nil
        agents = []
        connection = .connecting
        connectingSession = name
        Task {
            defer { if connectingSession == name { connectingSession = nil } }
            guard let hiveURL = await HiveInstallationService.locateInstalledHive() else {
                connection = .unavailable("Hive CLI was not found.")
                return
            }
            guard self.sessionName == name else { return }
            let store = HiveWorkspaceStore(hiveURL: hiveURL, sessionName: name)
            workspace = store
            store.onAgentChange = { previous, agent in AgentNotifier.shared.agentChanged(from: previous, to: agent) }
            store.$agents
                .sink { [weak self] agents in
                    self?.agents = agents.sorted { $0.stateRank < $1.stateRank }
                    AgentNotifier.shared.updateBadge(for: agents)
                }
                .store(in: &subscriptions)
            store.$connection
                .sink { [weak self] in self?.connection = $0 }
                .store(in: &subscriptions)
            store.start()
        }
    }

    func send(_ keys: [String], to agentID: String) async {
        guard let workspace else { return }
        do {
            try await workspace.sendKeys(toAgent: agentID, keys)
            actionError = nil
        } catch { actionError = error.localizedDescription }
    }

    func openAgent(_ agentID: String) {
        openAgentWindow?(agentID)
    }
}

struct MenuBarAgentPanel: View {
    @ObservedObject var store: MenuBarAgentStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: store.needsAttention ? "bell.badge.fill" : "h.square.fill")
                    .foregroundStyle(store.needsAttention ? Color.hiveAmber : Color.primary)
                    .font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hive agents").font(.headline)
                    Text(connectionDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Hive") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if store.agents.isEmpty {
                ContentUnavailableView("No agents", systemImage: "sparkles", description: Text(connectionDescription))
                    .frame(minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.agents) { agent in agentRow(agent) }
                    }
                }
                .frame(maxHeight: 390)
            }

            if let actionError = store.actionError {
                Text(actionError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 350)
    }

    private func agentRow(_ agent: HiveAgent) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agentStateColor(agent.state))
                .frame(width: 7, height: 7)
            if agent.state != "exited" { AgentProviderIcon(kind: agent.kind, size: 10) }
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name.isEmpty ? agent.kind : agent.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(agent.environmentID) · \(agentStateTitle(agent.state))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if agent.state == "blocked" {
                Button { Task { await store.send(["Enter"], to: agent.id) } } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.mini)
                .help("Approve the highlighted choice")
                Button { Task { await store.send(["Escape"], to: agent.id) } } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Deny the highlighted choice")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(agent.state == "blocked" ? Color.hiveAmber.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var connectionDescription: String {
        switch store.connection {
        case .connecting: "Connecting to Hive…"
        case .connected: "Connected · \(store.agents.count) agents"
        case .unavailable(let message): message
        }
    }
}
