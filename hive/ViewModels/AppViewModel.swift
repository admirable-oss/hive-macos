import Foundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    /// Hive's state, live from the daemon.
    let workspace: HiveWorkspaceStore

    /// The desktop's own tabs. Saved across launches.
    @Published private(set) var tabs: [WorkspaceTab] {
        didSet { saveTabs() }
    }
    @Published var activeTabID: WorkspaceTab.ID? {
        didSet { saveTabs() }
    }
    @Published private(set) var sidebarError: String?

    private let cli: HiveCLIService
    private var workspaceChanges: AnyCancellable?

    private static let savedTabsKey = "hive.desktop.tabs"

    init(hiveURL: URL) {
        cli = HiveCLIService(executableURL: hiveURL)
        workspace = HiveWorkspaceStore(hiveURL: hiveURL)

        let restored = Self.loadTabs()
        tabs = restored.tabs.isEmpty ? [WorkspaceTab(destination: .shell(environmentID: nil))] : restored.tabs
        activeTabID = restored.tabs.isEmpty ? tabs.first?.id : restored.activeID

        // Views observe this model; pass the store's changes through.
        workspaceChanges = workspace.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        workspace.onSnapshot = { [weak self] isFirst in
            if isFirst { self?.dropTabsForMissingAgents() }
        }
    }

    func start() {
        workspace.start()
    }

    // MARK: Workspace passthrough

    var environments: [HiveEnvironment] { workspace.environments }
    var agents: [HiveAgent] { workspace.agents }
    var agentKinds: [HiveAgentManifest] { workspace.agentKinds }
    var listeningPorts: [String: [ListeningPort]] { workspace.listeningPorts }
    var isConnected: Bool { workspace.isConnected }

    /// Why the runtime can't be reached, when it can't.
    var connectionProblem: String? {
        if case .unavailable(let message) = workspace.connection { return message }
        return nil
    }

    // MARK: Tabs

    var activeTab: WorkspaceTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    var selectedAgentID: String? {
        if case .agent(let id) = activeTab?.destination { return id }
        return nil
    }

    /// The environment the active tab is working in, either directly or through its agent.
    var activeEnvironment: HiveEnvironment? {
        guard let id = activeTab.flatMap({ environmentID(for: $0.destination) }) else { return nil }
        return environments.first(where: { $0.id == id })
    }

    func environmentID(for destination: WorkspaceDestination) -> String? {
        switch destination {
        case .shell(let environmentID): environmentID
        case .agent(let id): agents.first(where: { $0.id == id })?.environmentID
        }
    }

    /// Focuses a tab already working in the environment, otherwise opens one:
    /// attached to its most relevant running agent, or a shell when it has none.
    func openEnvironment(_ id: String) {
        if let tab = tabs.first(where: { environmentID(for: $0.destination) == id }) {
            activeTabID = tab.id
        } else if let agent = agents.filter({ $0.environmentID == id && $0.state != "exited" }).min(by: { $0.stateRank < $1.stateRank }) {
            openAgent(agent.id)
        } else {
            openTab(.shell(environmentID: id))
        }
    }

    func openAgent(_ id: String) {
        if let tab = tabs.first(where: { $0.destination == .agent(id) }) {
            activeTabID = tab.id
        } else {
            openTab(.agent(id))
        }
    }

    func newShell(in environmentID: String?) {
        openTab(.shell(environmentID: environmentID))
    }

    /// A new shell next to whatever the active tab is working on.
    func newTab() {
        newShell(in: activeEnvironment?.id)
    }

    func closeTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeOtherTabs(_ id: WorkspaceTab.ID) {
        tabs.removeAll { $0.id != id }
        activeTabID = id
    }

    /// Remembers where each shell is, so a relaunch reopens it in the same folder.
    func updateDirectories(_ directories: [WorkspaceTab.ID: String]) {
        var changed = tabs
        for index in changed.indices {
            if let directory = directories[changed[index].id] { changed[index].directory = directory }
        }
        if changed != tabs { tabs = changed }
    }

    private func openTab(_ destination: WorkspaceDestination) {
        let tab = WorkspaceTab(destination: destination)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Restored agent tabs whose agent is gone would only show an error.
    private func dropTabsForMissingAgents() {
        let known = Set(agents.map(\.id))
        for tab in tabs {
            if case .agent(let id) = tab.destination, !known.contains(id) { closeTab(tab.id) }
        }
    }

    // MARK: Operations

    func createEnvironment(name: String, path: String) async {
        await perform {
            let environment = try await self.workspace.createEnvironment(id: name, root: path)
            self.openEnvironment(environment.id)
        }
    }

    func startAgent(kind: String, environmentID: String) async {
        await perform {
            let agent = try await self.workspace.startAgent(kind: kind, environmentID: environmentID)
            self.openAgent(agent.id)
        }
    }

    func stopAgent(_ id: String) async {
        await perform { try await self.workspace.stopAgent(id) }
    }

    func closePane(_ paneID: String) async {
        await perform { try await self.workspace.closePane(paneID) }
    }

    func removeEnvironment(_ id: String) async {
        let affected = tabs.filter { environmentID(for: $0.destination) == id }.map(\.id)
        await perform {
            try await self.workspace.removeEnvironment(id)
            affected.forEach(self.closeTab)
        }
    }

    func killPorts(_ ports: [ListeningPort]) async {
        await perform { try PortScanner.kill(ports) }
        // Give the processes a moment to release their sockets before rescanning.
        try? await Task.sleep(for: .milliseconds(400))
        await workspace.refreshPorts()
    }

    func addMachine(name: String, host: String) async {
        // Machines aren't on the socket API yet; the CLI saves them.
        await perform { _ = try await self.cli.run(["machine", "add", name, host, "--no-check"]) }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            sidebarError = nil
        } catch {
            sidebarError = error.localizedDescription
        }
    }

    // MARK: Persistence

    private struct SavedTabs: Codable {
        var tabs: [WorkspaceTab]
        var activeIndex: Int?
    }

    private func saveTabs() {
        let saved = SavedTabs(tabs: tabs, activeIndex: tabs.firstIndex(where: { $0.id == activeTabID }))
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedTabsKey)
        }
    }

    private static func loadTabs() -> (tabs: [WorkspaceTab], activeID: WorkspaceTab.ID?) {
        guard let data = UserDefaults.standard.data(forKey: savedTabsKey),
              let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) else { return ([], nil) }
        let active = saved.activeIndex.flatMap { saved.tabs.indices.contains($0) ? saved.tabs[$0].id : nil }
        return (saved.tabs, active ?? saved.tabs.first?.id)
    }
}
