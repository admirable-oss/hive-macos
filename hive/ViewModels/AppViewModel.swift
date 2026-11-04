import AppKit
import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    /// Something that would stop a running agent, waiting for the user to confirm.
    enum PendingClose: Identifiable {
        case pane(id: String, agent: HiveAgent)
        case tab(id: WorkspaceTab.ID, hiveTabID: String, agents: [HiveAgent])

        var id: String {
            switch self {
            case .pane(let id, _): "pane-\(id)"
            case .tab(let id, _, _): "tab-\(id)"
            }
        }
    }

    /// Hive's state, live from the daemon.
    let workspace: HiveWorkspaceStore

    /// The desktop's tabs: Hive tabs it shows, and local scratch shells. Saved across launches.
    @Published private(set) var tabs: [WorkspaceTab] {
        didSet { saveTabs() }
    }
    @Published var activeTabID: WorkspaceTab.ID? {
        didSet { saveTabs() }
    }
    @Published private(set) var sidebarError: String?
    @Published private(set) var versionMismatch: String?
    @Published private(set) var machines: [SavedHiveMachine] = []
    @Published private(set) var machineStatuses: [String: HiveMachineStatus] = [:]
    @Published private(set) var machineAgents: [String: [HiveAgent]] = [:]
    @Published private(set) var machineEnvironments: [String: [HiveEnvironment]] = [:]
    @Published private(set) var machineAgentKinds: [String: [HiveAgentManifest]] = [:]
    @Published private(set) var refreshingMachines: Set<String> = []
    @Published private(set) var nearbyMachines: [HiveNearbyMachine] = []
    @Published var inspectedMachine: SavedHiveMachine?
    @Published private(set) var machineStatus: HiveMachineStatus?
    @Published private(set) var checkingMachine = false
    @Published var pendingClose: PendingClose?
    @Published var showingQuickOpen = false
    @Published var showingOverview = false

    private let cli: HiveCLIService
    private let notifier = AgentNotifier.shared
    private var subscriptions: Set<AnyCancellable> = []

    private static let savedTabsKey = "hive.desktop.tabs.v2"

    init(hiveURL: URL, sessionName: String = "default") {
        cli = HiveCLIService(executableURL: hiveURL, sessionName: sessionName)
        workspace = HiveWorkspaceStore(hiveURL: hiveURL, sessionName: sessionName)

        let restored = Self.loadTabs()
        tabs = restored.tabs
        activeTabID = restored.activeID

        // Views observe this model; pass the store's changes through.
        workspace.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        workspace.$tabs
            .dropFirst()
            .sink { [weak self] hiveTabs in self?.dropTabsMissingFrom(hiveTabs) }
            .store(in: &subscriptions)
        workspace.$agents
            .sink { [weak self] agents in self?.notifier.updateBadge(for: agents) }
            .store(in: &subscriptions)
        workspace.$connection
            .sink { [weak self] connection in
                guard case .connected(let version, _) = connection else { return }
                Task { await self?.checkVersionMismatch(daemonVersion: version) }
            }
            .store(in: &subscriptions)

        workspace.onAgentChange = { [weak self] previous, agent in
            self?.notifier.agentChanged(from: previous, to: agent)
        }
        notifier.isShowing = { [weak self] agent in self?.isShowing(agent) ?? false }
        notifier.onOpen = { [weak self] id in
            NSApp.activate(ignoringOtherApps: true)
            if let self { self.openAgent(id) }
            else { MenuBarAgentStore.shared.openAgent(id) }
        }
        notifier.onKeys = { id, keys in
            Task { await MenuBarAgentStore.shared.send(keys, to: id) }
        }
    }

    func start() {
        notifier.configure()
        Task {
            await loadRuntimeSettings()
            workspace.start()
        }
        Task { await loadMachines() }
    }

    private func loadRuntimeSettings() async {
        do {
            let data = Data(try await cli.run(["--json", "config", "show"]).utf8)
            let config = try JSONDecoder().decode(HiveConfigDocument.self, from: data)
            notifier.apply(config.notify)
        } catch {
            // Keep Hive's documented defaults until a valid config is available.
        }
    }

    private func checkVersionMismatch(daemonVersion: String) async {
        do {
            let output = try await cli.run(["--json", "version"])
            guard let data = output.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cliVersion = value["version"] as? String else { return }
            versionMismatch = cliVersion == daemonVersion ? nil : "Hive CLI is \(cliVersion), but the running daemon is \(daemonVersion). Update or restart Hive to sync versions."
        } catch { versionMismatch = nil }
    }

    func updateHive() async {
        await perform {
            _ = try await self.cli.run(["update"])
            self.versionMismatch = nil
        }
    }

    private func loadMachines() async {
        guard let output = try? await cli.run(["--json", "machine", "list"]),
              let data = output.data(using: .utf8),
              let machines = try? JSONDecoder().decode([SavedHiveMachine].self, from: data) else { return }
        self.machines = machines
        for machine in machines where machine.disabled != true {
            Task { await refreshMachine(machine) }
        }
    }

    func refreshMachine(_ machine: SavedHiveMachine) async {
        guard !refreshingMachines.contains(machine.name) else { return }
        refreshingMachines.insert(machine.name)
        defer { refreshingMachines.remove(machine.name) }
        do {
            let output = try await cli.run(["--json", "machine", "status", machine.name])
            let statuses = try JSONDecoder().decode([HiveMachineStatus].self, from: Data(output.utf8))
            guard let status = statuses.first else { return }
            machineStatuses[machine.name] = status
            if status.reachable {
                let remoteOutput = try await cli.run(["--machine", machine.name, "--json", "agent", "list"])
                machineAgents[machine.name] = (try? JSONDecoder().decode(HiveAgentList.self, from: Data(remoteOutput.utf8)).agents) ?? []
                async let environmentsOutput = cli.run(["--machine", machine.name, "--json", "env", "list"])
                async let kindsOutput = cli.run(["--machine", machine.name, "--json", "agent", "manifests"])
                if let output = try? await environmentsOutput, let data = output.data(using: .utf8) { machineEnvironments[machine.name] = try? JSONDecoder().decode([HiveEnvironment].self, from: data) }
                if let output = try? await kindsOutput, let data = output.data(using: .utf8) { machineAgentKinds[machine.name] = try? JSONDecoder().decode([HiveAgentManifest].self, from: data) }
            } else {
                machineAgents[machine.name] = []
                machineEnvironments[machine.name] = []
                machineAgentKinds[machine.name] = []
            }
        } catch {
            machineStatuses[machine.name] = HiveMachineStatus(name: machine.name, reachable: false, error: error.localizedDescription, disabled: machine.disabled, agents: nil, state: nil, identity: nil, version: nil)
            machineAgents[machine.name] = []
        }
    }

    func reconnectMachine(_ machine: SavedHiveMachine) async {
        do {
            _ = try await cli.run(["machine", "reconnect", machine.name])
            await refreshMachine(machine)
        } catch { sidebarError = error.localizedDescription }
    }

    func setMachine(_ machine: SavedHiveMachine, enabled: Bool) async {
        do {
            _ = try await cli.run(["machine", enabled ? "enable" : "disable", machine.name])
            await loadMachines()
        } catch { sidebarError = error.localizedDescription }
    }

    func renameMachine(_ machine: SavedHiveMachine, to name: String) async {
        do {
            _ = try await cli.run(["machine", "rename", machine.name, name])
            await loadMachines()
        } catch { sidebarError = error.localizedDescription }
    }

    func removeMachine(_ machine: SavedHiveMachine) async {
        do {
            _ = try await cli.run(["machine", "remove", machine.name])
            machineStatuses.removeValue(forKey: machine.name)
            machineAgents.removeValue(forKey: machine.name)
            await loadMachines()
        } catch { sidebarError = error.localizedDescription }
    }

    func discoverMachines() async {
        do {
            let json = try await cli.run(["--json", "machine", "discover"])
            nearbyMachines = try JSONDecoder().decode(HiveNearbyResponse.self, from: Data(json.utf8)).runtimes
            sidebarError = nil
        } catch { sidebarError = error.localizedDescription }
    }

    func checkPairIdentity(_ nearby: HiveNearbyMachine, as name: String) async throws -> HivePairIdentity {
        let json = try await cli.run(["--json", "machine", "pair", nearby.id, "--as", name, "--check", "--expect-id", nearby.id])
        return try JSONDecoder().decode(HivePairIdentity.self, from: Data(json.utf8))
    }

    func pairMachine(_ nearby: HiveNearbyMachine, as name: String, expectedID: String) async throws {
        _ = try await cli.run(["--json", "machine", "pair", nearby.id, "--as", name, "--yes", "--expect-id", expectedID])
        await loadMachines()
    }

    func revokeMachine(_ machine: SavedHiveMachine) async {
        do {
            _ = try await cli.run(["machine", "revoke", machine.name])
            await loadMachines()
        } catch { sidebarError = error.localizedDescription }
    }

    func inspectMachine(_ machine: SavedHiveMachine) {
        inspectedMachine = machine
        machineStatus = nil
        Task { await refreshMachineStatus() }
    }

    func refreshMachineStatus() async {
        guard let machine = inspectedMachine, !checkingMachine else { return }
        checkingMachine = true
        defer { checkingMachine = false }
        do {
            let output = try await cli.run(["--json", "machine", "status", machine.name])
            let statuses = try JSONDecoder().decode([HiveMachineStatus].self, from: Data(output.utf8))
            if inspectedMachine?.name == machine.name { machineStatus = statuses.first }
        } catch {
            sidebarError = error.localizedDescription
        }
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

    // MARK: What's in front

    var activeTab: WorkspaceTab? {
        tabs.first(where: { $0.id == activeTabID })
    }

    var activeHiveTab: HiveTab? {
        activeTab?.hiveTabID.flatMap(workspace.tab)
    }

    /// The pane keystrokes go to in the active tab.
    var focusedPaneID: String? {
        guard let tab = activeHiveTab else { return nil }
        return tab.zoomed ?? tab.focused ?? tab.paneIDs.first
    }

    /// The agent the active tab is about: the one in the focused pane, else the tab's first.
    var activeAgent: HiveAgent? {
        guard let tab = activeHiveTab else { return nil }
        if let paneID = focusedPaneID, let agent = workspace.agent(inPane: paneID) { return agent }
        return agents.first(where: { $0.tabID == tab.id })
    }

    var activeEnvironment: HiveEnvironment? {
        guard let id = activeHiveTab?.environmentID else { return nil }
        return environments.first(where: { $0.id == id })
    }

    func agents(inTab tabID: String) -> [HiveAgent] {
        agents.filter { $0.tabID == tabID }
    }

    private func isShowing(_ agent: HiveAgent) -> Bool {
        NSApp.isActive && agent.tabID != nil && agent.tabID == activeHiveTab?.id && !showingOverview
    }

    // MARK: Opening

    /// Shows the environment: a tab already open for it, else its active Hive tab,
    /// else a new Hive tab in it.
    func openEnvironment(_ id: String) {
        if let open = tabs.first(where: { $0.hiveTabID.flatMap(workspace.tab)?.environmentID == id }) {
            activeTabID = open.id
            return
        }
        let hiveTabs = workspace.tabs.filter { $0.environmentID == id }
        if let tab = hiveTabs.first(where: { $0.active == true }) ?? hiveTabs.first {
            openHiveTab(tab.id)
        } else {
            Task { await newHiveTab(in: id) }
        }
    }

    /// Shows the agent's tab and moves Hive's focus to its pane.
    func openAgent(_ id: String) {
        guard let agent = agents.first(where: { $0.id == id }), let tabID = agent.tabID else { return }
        openHiveTab(tabID)
        if let paneID = agent.paneID, workspace.tab(tabID)?.focused != paneID {
            focusPane(paneID)
        }
        if agent.state == "done" {
            Task { await workspace.markSeen(agent: id) }
        }
    }

    func openRemoteAgent(_ agent: HiveAgent, on machine: SavedHiveMachine) {
        showingOverview = false
        if let existing = tabs.first(where: { if case .remote(let host, let id, _) = $0.destination { return host == machine.name && id == agent.id }; return false }) {
            activeTabID = existing.id
        } else {
            append(WorkspaceTab(destination: .remote(machine: machine.name, agentID: agent.id, title: agent.name.isEmpty ? agent.kind : agent.name)))
        }
    }

    func openRemoteShell(_ machine: SavedHiveMachine) {
        showingOverview = false
        if let existing = tabs.first(where: { if case .remoteShell(let name, _) = $0.destination { return name == machine.name }; return false }) {
            activeTabID = existing.id
        } else {
            append(WorkspaceTab(destination: .remoteShell(machine: machine.name, host: machine.host)))
        }
    }

    func createRemoteEnvironment(on machine: SavedHiveMachine, id: String, path: String) async {
        do {
            _ = try await cli.run(["--machine", machine.name, "--json", "env", "create", id, "--cwd", path])
            await refreshMachine(machine)
            sidebarError = nil
        } catch { sidebarError = error.localizedDescription }
    }

    func startRemoteAgent(on machine: SavedHiveMachine, kind: String, environmentID: String) async {
        do {
            let output = try await cli.run(["--machine", machine.name, "--json", "agent", "start", "--kind", kind, "--env", environmentID])
            let started = try JSONDecoder().decode(HiveAgentStarted.self, from: Data(output.utf8))
            machineAgents[machine.name, default: []].append(started.agent)
            openRemoteAgent(started.agent, on: machine)
            sidebarError = nil
        } catch { sidebarError = error.localizedDescription }
    }

    func openPane(_ id: String) {
        guard let pane = workspace.panes[id] else { return }
        openHiveTab(pane.tabID)
        if workspace.tab(pane.tabID)?.focused != pane.id { focusPane(pane.id) }
    }

    func openHiveTab(_ hiveTabID: String) {
        showingOverview = false
        if let open = tabs.first(where: { $0.hiveTabID == hiveTabID }) {
            activeTabID = open.id
        } else {
            append(WorkspaceTab(destination: .hive(tabID: hiveTabID)))
        }
    }

    /// A new tab next to what's in front: a Hive tab in the active environment, or a scratch shell.
    func newTab() {
        if let environment = activeEnvironment {
            Task { await newHiveTab(in: environment.id) }
        } else {
            newScratchShell()
        }
    }

    func newHiveTab(in environmentID: String) async {
        await perform {
            let tab = try await self.workspace.createTab(environmentID: environmentID)
            self.openHiveTab(tab.id)
        }
    }

    func newScratchShell() {
        showingOverview = false
        append(WorkspaceTab(destination: .scratch))
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func selectAdjacentTab(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
        activeTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    // MARK: Closing

    /// Closes a desktop tab. A Hive tab is closed in Hive too, after asking if that would stop an agent.
    func requestCloseTab(_ id: WorkspaceTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        guard let hiveTabID = tab.hiveTabID else { return removeTab(id) }
        let running = agents(inTab: hiveTabID).filter { $0.state != "exited" }
        if running.isEmpty {
            Task { await closeHiveTab(hiveTabID) }
        } else {
            pendingClose = .tab(id: id, hiveTabID: hiveTabID, agents: running)
        }
    }

    /// Takes a tab out of this window and leaves everything in it running.
    func hideTab(_ id: WorkspaceTab.ID) {
        removeTab(id)
    }

    func closeHiveTab(_ hiveTabID: String) async {
        await perform { try await self.workspace.closeTab(hiveTabID) }
        tabs.filter { $0.hiveTabID == hiveTabID }.forEach { removeTab($0.id) }
    }

    func closeOtherTabs(_ id: WorkspaceTab.ID) {
        tabs.filter { $0.id != id }.forEach { removeTab($0.id) }
    }

    /// ⌘W: the focused pane, after asking if it runs an agent; for a scratch tab, the tab.
    func requestCloseFocusedPane() {
        guard let tab = activeTab else { return }
        guard tab.hiveTabID != nil, let paneID = focusedPaneID else { return removeTab(tab.id) }
        if let agent = workspace.agent(inPane: paneID), agent.state != "exited" {
            pendingClose = .pane(id: paneID, agent: agent)
        } else {
            Task { await closePane(paneID) }
        }
    }

    func confirm(_ pending: PendingClose) {
        pendingClose = nil
        switch pending {
        case .pane(let id, _): Task { await closePane(id) }
        case .tab(_, let hiveTabID, _): Task { await closeHiveTab(hiveTabID) }
        }
    }

    private func append(_ tab: WorkspaceTab) {
        tabs.append(tab)
        activeTabID = tab.id
    }

    private func removeTab(_ id: WorkspaceTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Hive tabs closed anywhere (here, in the TUI, by an agent) leave this window too.
    private func dropTabsMissingFrom(_ hiveTabs: [HiveTab]) {
        guard workspace.hasSnapshot else { return }
        let known = Set(hiveTabs.map(\.id))
        for tab in tabs {
            if let id = tab.hiveTabID, !known.contains(id) { removeTab(tab.id) }
        }
    }

    // MARK: Panes

    /// `direction` is where the new pane goes: right or down.
    func splitFocusedPane(_ direction: String) {
        guard let paneID = focusedPaneID else { return }
        Task { await perform { try await self.workspace.splitPane(paneID, direction: direction) } }
    }

    func focusPane(_ id: String) {
        Task { await perform { try await self.workspace.focusPane(id) } }
    }

    /// Moves focus to the pane left, right, up or down of the focused one.
    func moveFocus(_ direction: String) {
        guard let paneID = focusedPaneID else { return }
        Task { try? await self.workspace.focusPane(paneID, direction: direction) }
    }

    func toggleZoom() {
        guard let tab = activeHiveTab, let paneID = focusedPaneID, tab.paneIDs.count > 1 else { return }
        let zoomed = tab.zoomed != nil
        Task { await perform { try await self.workspace.zoomPane(paneID, on: !zoomed) } }
    }

    func resizePane(_ id: String, direction: String, cells: Int) {
        Task { await perform { try await self.workspace.resizePane(id, direction: direction, cells: cells) } }
    }

    func resizeHiveTab(_ id: String, width: Int, height: Int) {
        Task { try? await self.workspace.resizeTab(id, width: width, height: height) }
    }

    func renameHiveTab(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { await perform { try await self.workspace.renameTab(id, to: name) } }
    }

    func closePane(_ paneID: String) async {
        await perform { try await self.workspace.closePane(paneID) }
    }

    /// Remembers where each scratch shell is, so a relaunch reopens it in the same folder.
    func updateDirectories(_ directories: [WorkspaceTab.ID: String]) {
        var changed = tabs
        for index in changed.indices {
            if let directory = directories[changed[index].id] { changed[index].directory = directory }
        }
        if changed != tabs { tabs = changed }
    }

    // MARK: Agents

    func sendKeys(_ keys: [String], toAgent id: String) async {
        await perform { try await self.workspace.sendKeys(toAgent: id, keys) }
    }

    func pasteImage(_ png: Data, toAgent id: String) async {
        await perform {
            guard let agent = self.workspace.agents.first(where: { $0.id == id }),
                  let paneID = agent.paneID,
                  let pane = self.workspace.panes[paneID] else {
                throw NSError(domain: "Hive", code: 1, userInfo: [NSLocalizedDescriptionKey: "This agent has no active terminal to receive an image."])
            }
            _ = try await self.workspace.sendImage(png: png, toProcess: pane.processID, viewID: nil)
        }
    }

    func stopAgent(_ id: String) async {
        await perform { try await self.workspace.stopAgent(id) }
    }

    func resumeAgent(_ id: String) async {
        await perform {
            let agent = try await self.workspace.resumeAgent(id)
            self.openAgent(agent.id)
        }
    }

    func startAgent(kind: String, environmentID: String) async {
        await perform {
            let agent = try await self.workspace.startAgent(kind: kind, environmentID: environmentID)
            self.openAgent(agent.id)
        }
    }

    // MARK: Environments

    func createEnvironment(name: String, path: String) async {
        await perform {
            let environment = try await self.workspace.createEnvironment(id: name, root: path)
            self.openEnvironment(environment.id)
        }
    }

    func createWorktree(repo: String, branch: String, base: String?, startAgent: String?) async {
        await perform {
            let environment = try await self.workspace.createWorktree(repo: repo, branch: branch, base: base)
            self.openEnvironment(environment.id)
            if let startAgent, !startAgent.isEmpty {
                let agent = try await self.workspace.startAgent(kind: startAgent, environmentID: environment.id)
                self.openAgent(agent.id)
            }
        }
    }

    func removeEnvironment(_ id: String) async {
        let affected = tabs.filter { $0.hiveTabID.flatMap(workspace.tab)?.environmentID == id }.map(\.id)
        await perform {
            try await self.workspace.removeEnvironment(id)
            affected.forEach(self.removeTab)
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
