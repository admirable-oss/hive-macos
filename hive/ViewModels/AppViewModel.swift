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

    /// A tab or pane whose name is being edited.
    enum RenameTarget: Identifiable, Hashable {
        case tab(WorkspaceTab.ID)
        case pane(String)
        case agent(String)

        var id: String {
            switch self {
            case .tab(let id): "tab-\(id)"
            case .pane(let id): "pane-\(id)"
            case .agent(let id): "agent-\(id)"
            }
        }
    }

    /// A "notify me when…" on one agent, running until Hive answers.
    struct AgentWatch: Hashable {
        /// idle, done, blocked, exited, or `stall` for "stops changing".
        let condition: String
        var stallMinutes: Int?

        var title: String {
            if let stallMinutes { return "stalls for \(stallMinutes) min" }
            return "is \(condition)"
        }
    }

    /// Whether switching tabs here moves Hive's active tab, so the TUI follows.
    static let syncTabFocusKey = "hive.desktop.syncTabFocus"

    /// Hive's state, live from the daemon.
    let workspace: HiveWorkspaceStore

    /// The desktop's tabs: Hive tabs it shows, and local scratch shells. Saved across launches.
    @Published private(set) var tabs: [WorkspaceTab] {
        didSet { saveTabs() }
    }
    @Published var activeTabID: WorkspaceTab.ID? {
        didSet {
            saveTabs()
            if activeTabID != oldValue { syncTabFocus() }
        }
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
    @Published var showingInbox = false
    @Published var renaming: RenameTarget?
    /// A pane on its way to a new place in its own tab; its tab keeps showing it meanwhile.
    @Published private(set) var rearrangingPaneID: String?
    /// Agent watches by agent ID.
    @Published private(set) var agentWatches: [String: AgentWatch] = [:]
    private var agentWatchTasks: [String: Task<Void, Never>] = [:]
    @Published var showingShortcuts = false
    @Published var showingRunInPopup = false
    @Published var showingWebObserver = false
    @Published var showingDiagnostics = false
    @Published var showingConnectHost = false
    /// `[[keys.command]]` from config.toml: commands bound to keys in the TUI.
    @Published private(set) var customCommands: [HiveKeyCommand] = []
    /// The last line a background command printed, shown briefly.
    @Published private(set) var commandStatus: String?
    private var commandStatusTask: Task<Void, Never>?

    /// Mirrors Hive's agent-state changes, for the command center's activity log.
    var onAgentChange: ((HiveAgent?, HiveAgent) -> Void)?

    private let cli: HiveCLIService
    private let notifier = AgentNotifier.shared
    private var subscriptions: Set<AnyCancellable> = []

    private static let savedTabsKey = "hive.desktop.tabs.v2"

    /// The CLI for this window's session, for what the socket API doesn't cover.
    var cliService: HiveCLIService { cli }
    var sessionName: String { cli.sessionName ?? "default" }

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
            self?.onAgentChange?(previous, agent)
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
            customCommands = (config.keys?.command ?? []).filter(\.isSupported)
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
        let panes = tab.paneIDs + tab.popupPaneIDs
        // A focus that names a pane already closed falls back to one still on screen.
        return [tab.focused, tab.zoomed].compactMap { $0 }.first(where: panes.contains) ?? tab.popupPaneIDs.last ?? panes.first
    }

    /// Whether the focused pane floats over the tab rather than sitting in its layout.
    var focusedPaneIsPopup: Bool {
        guard let id = focusedPaneID else { return false }
        return activeHiveTab?.popupPaneIDs.contains(id) ?? false
    }

    /// The most panes one tab splits into; past that, terminals get too small to use.
    static let maxPanesPerTab = 4

    /// Whether the Hive tab holding a pane has room for another split.
    func canSplit(_ paneID: String) -> Bool {
        guard let tab = workspace.tabs.first(where: { $0.paneIDs.contains(paneID) }) else { return false }
        return tab.paneIDs.count < Self.maxPanesPerTab
    }

    var canSplitFocusedPane: Bool {
        focusedPaneID.map(canSplit) ?? false
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
        dismissSurfaces()
        if let existing = tabs.first(where: { if case .remote(let host, let id, _) = $0.destination { return host == machine.name && id == agent.id }; return false }) {
            activeTabID = existing.id
        } else {
            append(WorkspaceTab(destination: .remote(machine: machine.name, agentID: agent.id, title: agent.name.isEmpty ? agent.kind : agent.name)))
        }
    }

    /// Opens what a `hive://` link, a Finder service or a Shortcut points at. Waits for the first
    /// snapshot, since links can arrive while the app is still connecting.
    func open(_ link: DeepLink) async {
        for _ in 0..<40 where !workspace.hasSnapshot {
            try? await Task.sleep(for: .milliseconds(250))
        }
        switch link {
        case .agent(let id):
            guard agents.contains(where: { $0.id == id }) else { return missing("agent", id) }
            openAgent(id)
        case .pane(let id):
            guard workspace.panes[id] != nil else { return missing("pane", id) }
            openPane(id)
        case .tab(let id):
            guard workspace.tab(id) != nil else { return missing("tab", id) }
            openHiveTab(id)
        case .environment(let id):
            guard environments.contains(where: { $0.id == id }) else { return missing("environment", id) }
            openEnvironment(id)
        case .open(let path):
            if let environment = environment(containing: path) {
                openEnvironment(environment.id)
            } else {
                dismissSurfaces()
                append(WorkspaceTab(destination: .scratch, directory: path))
            }
        case .newEnvironment(let path):
            if let existing = environments.first(where: { $0.path == path }) { return openEnvironment(existing.id) }
            let name = HiveEnvironment.id(fromFolderName: (path as NSString).lastPathComponent)
            await createEnvironment(name: environments.contains(where: { $0.id == name }) ? "\(name)-\(Int.random(in: 2...999))" : name, path: path)
        }
    }

    /// The environment a path is in: the deepest one whose folder holds it.
    func environment(containing path: String) -> HiveEnvironment? {
        environments
            .filter { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private func missing(_ kind: String, _ id: String) {
        sidebarError = "The link points at \(kind) \(id), which isn’t in this session."
    }

    /// Opens an agent on an SSH host that isn't saved as a machine (`hive --remote host agent attach`).
    func openRemoteHostAgent(host: String, agent: HiveAgent) {
        dismissSurfaces()
        if let existing = tabs.first(where: { if case .remoteHost(let h, let id, _) = $0.destination { return h == host && id == agent.id }; return false }) {
            activeTabID = existing.id
        } else {
            append(WorkspaceTab(destination: .remoteHost(host: host, agentID: agent.id, title: agent.name.isEmpty ? agent.kind : agent.name)))
        }
    }

    /// An SSH login to a host, saved as a machine or not.
    func openSSHShell(host: String) {
        dismissSurfaces()
        if let existing = tabs.first(where: { if case .remoteShell(_, let h) = $0.destination { return h == host }; return false }) {
            activeTabID = existing.id
        } else {
            append(WorkspaceTab(destination: .remoteShell(machine: host, host: host)))
        }
    }

    /// Opens Hive's demo: a tab of four pretend agents to explore with (`hive demo`).
    func openDemo() async {
        struct Demo: Decodable {
            struct Pane: Decodable { let tabID: String; enum CodingKeys: String, CodingKey { case tabID = "tab_id" } }
            let panes: [Pane]
        }
        await perform {
            let demo = try JSONDecoder().decode(Demo.self, from: Data(try await self.cli.run(["--json", "demo"]).utf8))
            guard let tabID = demo.panes.first?.tabID else { return }
            // The tab can be a moment ahead of the snapshot.
            for _ in 0..<20 where self.workspace.tab(tabID) == nil {
                try await Task.sleep(for: .milliseconds(150))
            }
            self.openHiveTab(tabID)
        }
    }

    func openRemoteShell(_ machine: SavedHiveMachine) {
        dismissSurfaces()
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
        dismissSurfaces()
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
        dismissSurfaces()
        append(WorkspaceTab(destination: .scratch))
    }

    /// Switches the detail area to the overview, leaving the inbox.
    func showOverview(_ on: Bool) {
        showingOverview = on
        if on { showingInbox = false }
    }

    /// Switches the detail area to the inbox, leaving the overview.
    func showInbox(_ on: Bool) {
        showingInbox = on
        if on { showingOverview = false }
    }

    private func dismissSurfaces() {
        showingOverview = false
        showingInbox = false
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
        requestClosePane(paneID)
    }

    /// Closes a pane, after asking if it runs an agent. A tab's last pane closes the tab.
    func requestClosePane(_ paneID: String) {
        if let hiveTab = workspace.tabs.first(where: { $0.paneIDs.contains(paneID) }), hiveTab.paneIDs.count == 1,
           let tab = tabs.first(where: { $0.hiveTabID == hiveTab.id }) {
            return requestCloseTab(tab.id)
        }
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
        splitPane(paneID, direction: direction)
    }

    /// Splits a particular pane, as its hover controls do, whether or not it has focus.
    func splitPane(_ paneID: String, direction: String) {
        guard canSplit(paneID) else { return NSSound.beep() }
        Task { await perform { try await self.workspace.splitPane(paneID, direction: direction) } }
    }

    func focusPane(_ id: String) {
        guard workspace.tabs.first(where: { $0.paneIDs.contains(id) })?.focused != id else { return }
        Task { await perform { try await self.workspace.focusPane(id) } }
    }

    /// Moves focus to the pane left, right, up or down of the focused one.
    func moveFocus(_ direction: String) {
        guard let paneID = focusedPaneID else { return }
        Task { try? await self.workspace.focusPane(paneID, direction: direction) }
    }

    func toggleZoom() {
        guard let paneID = focusedPaneID, !focusedPaneIsPopup else { return }
        toggleZoom(paneID)
    }

    /// Zooms a pane to fill its tab, or puts a zoomed tab back to its layout.
    func toggleZoom(_ paneID: String) {
        guard let tab = activeHiveTab, tab.paneIDs.count > 1 else { return }
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

    // MARK: Names

    /// The name a rename starts from.
    func currentName(of target: RenameTarget) -> String {
        switch target {
        case .tab(let id):
            guard let tab = tabs.first(where: { $0.id == id }) else { return "" }
            return tab.hiveTabID.flatMap(workspace.tab)?.name ?? tab.name ?? ""
        case .pane(let id):
            return workspace.panes[id]?.name ?? ""
        case .agent(let id):
            return agents.first(where: { $0.id == id })?.name ?? ""
        }
    }

    func rename(_ target: RenameTarget, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .tab(let id):
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            if let hiveTabID = tabs[index].hiveTabID {
                renameHiveTab(hiveTabID, to: name)
            } else {
                tabs[index].name = name.isEmpty ? nil : name
            }
        case .pane(let id):
            guard !name.isEmpty else { return }
            Task { await perform { try await self.workspace.renamePane(id, to: name) } }
        case .agent(let id):
            guard !name.isEmpty else { return }
            Task { await perform { try await self.workspace.renameAgent(id, to: name) } }
        }
    }

    // MARK: Agent tools

    /// Notifies once the agent reaches `condition`, or stalls for `stallMinutes`. One watch per agent.
    func watch(agent id: String, condition: String, stallMinutes: Int? = nil) {
        cancelWatch(agent: id)
        let watch = AgentWatch(condition: condition, stallMinutes: stallMinutes)
        agentWatches[id] = watch
        agentWatchTasks[id] = Task {
            // A stall watch ends on any state change too, so it waits for "exited" and lets the stall end it.
            let until = stallMinutes == nil ? condition : "exited"
            let result = try? await workspace.waitForAgent(id, until: until, stallMilliseconds: stallMinutes.map { $0 * 60_000 })
            guard !Task.isCancelled else { return }
            agentWatches[id] = nil
            agentWatchTasks[id] = nil
            if let result {
                notifier.notifyWatchEnded(agent: result.agent, condition: condition, outcome: result.outcome)
            }
        }
    }

    func cancelWatch(agent id: String) {
        agentWatchTasks[id]?.cancel()
        agentWatchTasks[id] = nil
        agentWatches[id] = nil
    }

    /// Brings the agent's pane to the front in Hive, for the TUI and other clients.
    func showAgentInTUI(_ id: String) {
        Task { await perform { try await self.workspace.focusAgent(id) } }
    }

    /// Sets an agent's state by hand, for agents without hooks. It holds ten minutes unless replaced.
    func reportAgent(_ id: String, state: String) {
        Task { await perform { try await self.workspace.reportAgent(id, state: state, message: "Set in Hive Desktop") } }
    }

    // MARK: Environments and processes

    func updateVariables(of environmentID: String, set: [String: String], unset: [String]) async throws {
        try await workspace.updateEnvironmentVariables(environmentID, set: set, unset: unset)
    }

    func clearMetadata(pane: String? = nil, environment: String? = nil) {
        Task { await perform { try await self.workspace.clearMetadata(pane: pane, environment: environment) } }
    }

    /// Background processes in an environment: running ones first, then the most recent that ended.
    func backgroundProcesses(in environmentID: String) -> [HiveProcess] {
        workspace.processes.values
            .filter { $0.environmentID == environmentID && !$0.terminal }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return (lhs.startedAt ?? "") > (rhs.startedAt ?? "")
            }
    }

    func startProcess(in environmentID: String, commandLine: String) async throws -> HiveProcess {
        try await workspace.startProcess(in: environmentID, commandLine: commandLine)
    }

    func stopProcess(_ id: String) {
        Task { await perform { try await self.workspace.stopProcess(id) } }
    }

    /// Runs the same command again; a running one is stopped first.
    func restartProcess(_ process: HiveProcess) async throws -> HiveProcess {
        if process.isRunning {
            try await workspace.stopProcess(process.id)
            try? await Task.sleep(for: .milliseconds(300))
        }
        return try await workspace.startProcess(in: process.environmentID, commandLine: process.commandLine)
    }

    /// Listening ports that belong to a process, matched by its PID.
    func ports(of process: HiveProcess) -> [ListeningPort] {
        (listeningPorts[process.environmentID] ?? []).filter { Int($0.pid) == process.pid }
    }

    // MARK: Worktrees

    func openWorktree(path: String) async throws {
        let environment = try await workspace.openWorktree(path: path)
        openEnvironment(environment.id)
    }

    func removeWorktree(path: String, force: Bool) async throws {
        try await workspace.removeWorktree(path: path, force: force)
    }

    func renameActiveTab() {
        if let id = activeTabID { renaming = .tab(id) }
    }

    func renameFocusedPane() {
        if let id = focusedPaneID { renaming = .pane(id) }
    }

    // MARK: Arranging panes

    /// Swaps the focused pane with the one after it (or before it) in the tab, as tmux's `{` and `}` do.
    func swapFocusedPane(forward: Bool) {
        guard let tab = activeHiveTab, let id = focusedPaneID else { return }
        let panes = tab.paneIDs
        guard panes.count > 1, let index = panes.firstIndex(of: id) else { return }
        swapPanes(id, with: panes[(index + (forward ? 1 : -1) + panes.count) % panes.count])
    }

    func swapPanes(_ id: String, with other: String) {
        guard id != other else { return }
        Task { await perform { try await self.workspace.swapPanes(id, with: other) } }
    }

    /// Hive tabs a pane can move into: any other tab with room for one more pane.
    func moveDestinations(for paneID: String) -> [HiveTab] {
        let home = workspace.panes[paneID]?.tabID
        return workspace.tabs.filter { $0.id != home && $0.paneIDs.count < Self.maxPanesPerTab }
    }

    /// Moves a pane beside `target` (or the destination's focused pane), then shows it there.
    func movePane(_ id: String, toTab tabID: String, nextTo target: String? = nil, direction: String = "right") {
        if workspace.panes[id]?.tabID == tabID {
            guard let target, rearrangingPaneID == nil else { return }
            rearrangingPaneID = id
            Task {
                await perform { try await self.workspace.rearrangePane(id, nextTo: target, direction: direction) }
                rearrangingPaneID = nil
            }
            return
        }
        if let destination = workspace.tab(tabID), destination.id != workspace.panes[id]?.tabID,
           destination.paneIDs.count >= Self.maxPanesPerTab {
            return NSSound.beep()
        }
        Task {
            await perform {
                let pane = try await self.workspace.movePane(id, toTab: tabID, nextTo: target, direction: direction)
                self.openHiveTab(pane.tabID)
            }
        }
    }

    /// Moves a pane into a new tab of an environment, its own when `environmentID` is nil.
    func movePaneToNewTab(_ id: String, environmentID: String? = nil) {
        guard let environment = environmentID ?? workspace.panes[id]?.environmentID else { return }
        Task {
            await perform {
                let pane = try await self.workspace.movePane(id, environmentID: environment)
                self.openHiveTab(pane.tabID)
            }
        }
    }

    /// The TUI's effective key bindings (`hive config keys`), as action → how you press it,
    /// e.g. `rename-tab` → `⌃B ,`. Shown beside the desktop shortcuts.
    func tuiKeyBindings() async -> [String: String] {
        struct Document: Decodable {
            struct Binding: Decodable { let mode: String; let action: String; let keys: [String] }
            let prefix: [String]
            let bindings: [Binding]
        }
        guard let output = try? await cli.run(["--json", "config", "keys"]),
              let document = try? JSONDecoder().decode(Document.self, from: Data(output.utf8)) else { return [:] }
        let prefix = document.prefix.first.map(Self.displayKey) ?? "⌃B"
        var result: [String: String] = [:]
        for binding in document.bindings where result[binding.action] == nil {
            guard let key = binding.keys.first else { continue }
            switch binding.mode {
            case "prefix": result[binding.action] = "\(prefix) \(Self.displayKey(key))"
            case "terminal": result[binding.action] = Self.displayKey(key)
            default: break
            }
        }
        return result
    }

    private static func displayKey(_ key: String) -> String {
        let names = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "space": "Space", "esc": "Esc", "enter": "↩",
                     "left": "←", "right": "→", "up": "↑", "down": "↓", "tab": "⇥"]
        let parts = key.split(separator: "+").map(String.init)
        // `o` and `O` are different keys, so case stays, except after a modifier (⌃B, not ⌃b).
        return parts.enumerated().map { index, part in
            names[part] ?? (index > 0 && part.count == 1 ? part.uppercased() : part)
        }.joined()
    }

    // MARK: Popups and commands

    /// Opens a floating pane over the active tab: a shell, or `command` run by the user's shell.
    func openPopup(command: String? = nil, name: String? = nil) {
        guard let tab = activeHiveTab else { return NSSound.beep() }
        let argv = command.map(Self.shellCommand)
        Task { await perform { _ = try await self.workspace.openPopup(inTab: tab.id, command: argv, name: name) } }
    }

    func run(_ command: HiveKeyCommand) {
        switch command.type {
        case "popup":
            openPopup(command: command.command, name: command.title)
        case "pane":
            guard let paneID = focusedPaneID, !focusedPaneIsPopup else { return NSSound.beep() }
            guard canSplit(paneID) else { return NSSound.beep() }
            let argv = Self.shellCommand(command.command ?? "")
            Task { await perform { try await self.workspace.splitPane(paneID, direction: "right", command: argv) } }
        case "shell":
            runInBackground(command)
        default:
            NSSound.beep()
        }
    }

    /// A `shell` command runs out of sight in the active environment; its last line shows briefly.
    private func runInBackground(_ command: HiveKeyCommand) {
        let directory = activeEnvironment?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let argv = Self.shellCommand(command.command ?? "")
        showCommandStatus("\(command.title) …")
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var line: String
            do {
                try process.run()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                if line.isEmpty { line = process.terminationStatus == 0 ? "Done" : "Exited with code \(process.terminationStatus)" }
            } catch {
                line = error.localizedDescription
            }
            await MainActor.run { [line] in self.showCommandStatus("\(command.title): \(line)") }
        }
    }

    private func showCommandStatus(_ text: String) {
        commandStatus = text
        commandStatusTask?.cancel()
        commandStatusTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            commandStatus = nil
        }
    }

    /// Runs a command line the way the user's own shell would, with their PATH.
    private static func shellCommand(_ line: String) -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        return [shell, "-lc", line]
    }

    /// Tells Hive which tab is in front here, so the TUI and other clients follow it.
    private func syncTabFocus() {
        guard UserDefaults.standard.object(forKey: Self.syncTabFocusKey) as? Bool ?? true,
              let hiveTabID = activeTab?.hiveTabID,
              let tab = workspace.tab(hiveTabID), tab.active != true else { return }
        Task { try? await workspace.focusTab(hiveTabID) }
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
