import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SidebarItem: Hashable {
    case environment(String)
    case agent(String)
    case machine(String)
}
struct HiveDashboardView: View {
    let hiveURL: URL
    let sessionName: String

    @StateObject private var viewModel: AppViewModel
    @StateObject private var terminals = TerminalStore()
    @StateObject private var commandCenter = CommandCenterStore()
    @State private var searchText = ""
    @AppStorage("hive.desktop.environmentsExpanded") private var environmentsExpanded = true
    @AppStorage("hive.desktop.agentsExpanded") private var agentsExpanded = true
    @AppStorage("hive.desktop.machinesExpanded") private var machinesExpanded = false
    @AppStorage("hive.desktop.inspector") private var inspectorPanel: InspectorPanel?
    @AppStorage("hive.desktop.lastInspector") private var lastInspectorPanel: InspectorPanel = .files
    @AppStorage("hive.menu.pending-agent") private var pendingAgentID = ""
    @State private var showingCreateEnvironment = false
    @State private var showingStartAgent = false
    @State private var startAgentEnvironmentID: String?
    @State private var environmentPendingRemoval: HiveEnvironment?
    @State private var showingAddMachine = false
    @State private var worktreeRepository: HiveEnvironment?
    @State private var machineToRename: SavedHiveMachine?
    @State private var machineToRemove: SavedHiveMachine?
    @State private var machineToRevoke: SavedHiveMachine?
    @State private var machineRenameText = ""
    @State private var showingNearbyMachines = false
    @State private var showingObservers = false
    @State private var showingTaskCenter = false
    @State private var showingLayoutManager = false
    @State private var showingWorkspaceViews = false
    @State private var showingActivity = false
    @State private var showingUsage = false
    @State private var showingDelegation = false
    @State private var delegationParentID: String?
    @State private var reviewEnvironment: HiveEnvironment?
    @State private var requestedChangePath: String?

    init(hiveURL: URL, sessionName: String = "default") {
        self.hiveURL = hiveURL
        self.sessionName = sessionName
        _viewModel = StateObject(wrappedValue: AppViewModel(hiveURL: hiveURL, sessionName: sessionName))
    }

    /// The window's frame: sidebar, detail and inspector.
    private var shell: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
                .inspector(isPresented: inspectorIsPresented) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = viewModel.versionMismatch {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    Text(notice).font(.callout)
                    Spacer()
                    Button("Update Hive") { Task { await viewModel.updateHive() } }
                        .buttonStyle(.hivePrimary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.hiveAmber.opacity(0.16))
            }
        }
        .tint(.hiveAmber)
        .background {
            keyboardShortcuts.frame(width: 0, height: 0).hidden()
        }
        .onChange(of: viewModel.tabs) { _, tabs in
            retainSessions(for: tabs)
        }
    }

    var body: some View {
        commandSheets
            .task { viewModel.start() }
            .task { openPendingAgentIfAvailable() }
            .onAppear {
                viewModel.onAgentChange = { previous, agent in
                    commandCenter.recordAgentChange(previous: previous, agent: agent)
                }
                applyActiveView()
            }
            .onChange(of: commandCenter.activeViewID) { _, _ in applyActiveView() }
            .onChange(of: viewModel.agents.count) { _, _ in openPendingAgentIfAvailable() }
            .onChange(of: viewModel.activeTabID) { saveDirectories() }
            .onChange(of: machinesExpanded) { _, expanded in
                if expanded { for machine in viewModel.machines where machine.disabled != true { Task { await viewModel.refreshMachine(machine) } } }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                saveDirectories()
            }
            .frame(minWidth: 820, minHeight: 540)
    }

    private var workspaceSheets: some View {
        shell
            .modifier(QuickOpenOverlay(showing: $viewModel.showingQuickOpen, viewModel: viewModel))
            .modifier(PendingCloseDialog(pending: $viewModel.pendingClose, confirm: viewModel.confirm))
            .sheet(isPresented: $showingCreateEnvironment) {
                CreateEnvironmentSheet { name, path in
                    Task { await viewModel.createEnvironment(name: name, path: path) }
                }
            }
            .sheet(isPresented: $showingStartAgent) {
                StartAgentSheet(
                    environments: viewModel.environments,
                    kinds: viewModel.agentKinds,
                    preferredEnvironmentID: preferredStartEnvironmentID,
                    onStart: startAgent
                )
            }
            .sheet(item: $worktreeRepository) { environment in
                NewWorktreeSheet(environment: environment, kinds: viewModel.agentKinds) { branch, base, agent in
                    Task { await viewModel.createWorktree(repo: environment.path, branch: branch, base: base, startAgent: agent) }
                }
            }
            .modifier(EnvironmentRemovalDialog(
                environment: $environmentPendingRemoval,
                remove: { id in Task { await viewModel.removeEnvironment(id) } }
            ))
            .sheet(isPresented: $showingAddMachine) {
                AddMachineSheet { name, host in
                    Task { await viewModel.addMachine(name: name, host: host) }
                }
            }
            .sheet(item: $viewModel.inspectedMachine) { machine in
                MachineInspectorView(machine: machine, viewModel: viewModel)
            }
            .sheet(isPresented: $showingTaskCenter) {
                TaskCenterView(workspace: viewModel.workspace) { task, path in
                    guard let environmentID = task.environmentID ?? task.spec.environmentID else { return }
                    requestedChangePath = path
                    viewModel.openEnvironment(environmentID)
                    lastInspectorPanel = .changes
                    inspectorPanel = .changes
                }
            }
            .sheet(isPresented: $showingLayoutManager) {
                LayoutManagerView(workspace: viewModel.workspace)
            }
    }

    private var commandSheets: some View {
        workspaceSheets
            .sheet(item: $reviewEnvironment) { environment in
                ReviewCockpitView(environment: environment, viewModel: viewModel)
            }
            .sheet(isPresented: $showingNearbyMachines) {
                NearbyMachinesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $showingObservers) {
                ObserverManagerView(workspace: viewModel.workspace, cli: HiveCLIService(executableURL: hiveURL, sessionName: sessionName))
            }
            .sheet(isPresented: $showingWorkspaceViews) {
                WorkspaceViewsView(commandCenter: commandCenter, viewModel: viewModel)
            }
            .sheet(isPresented: $showingActivity) {
                ActivityHistoryView(commandCenter: commandCenter, hiveURL: hiveURL, sessionName: sessionName)
            }
            .sheet(isPresented: $showingUsage) {
                UsageView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingDelegation) {
                DelegationView(viewModel: viewModel, commandCenter: commandCenter, initialParentID: delegationParentID)
            }
            .alert("Rename machine", isPresented: Binding(get: { machineToRename != nil }, set: { if !$0 { machineToRename = nil } })) {
                TextField("Machine name", text: $machineRenameText)
                Button("Cancel", role: .cancel) { machineToRename = nil }
                Button("Rename") {
                    if let machineToRename { Task { await viewModel.renameMachine(machineToRename, to: machineRenameText.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                    machineToRename = nil
                }
                .disabled(machineRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text("Choose a new name for this saved machine.") }
            .confirmationDialog("Remove saved machine?", isPresented: Binding(get: { machineToRemove != nil }, set: { if !$0 { machineToRemove = nil } }), titleVisibility: .visible) {
                Button("Remove Machine", role: .destructive) {
                    if let machineToRemove { Task { await viewModel.removeMachine(machineToRemove) } }
                    machineToRemove = nil
                }
                Button("Cancel", role: .cancel) { machineToRemove = nil }
            } message: { Text("This forgets the saved connection. Hive and its agents keep running on the remote machine.") }
            .confirmationDialog("Revoke machine identity?", isPresented: Binding(get: { machineToRevoke != nil }, set: { if !$0 { machineToRevoke = nil } }), titleVisibility: .visible) {
                Button("Revoke Identity", role: .destructive) {
                    if let machineToRevoke { Task { await viewModel.revokeMachine(machineToRevoke) } }
                    machineToRevoke = nil
                }
                Button("Cancel", role: .cancel) { machineToRevoke = nil }
            } message: { Text("Hive forgets this machine’s pinned identity and disables it. You can trust it again later.") }
    }

    private func openPendingAgentIfAvailable() {
        guard !pendingAgentID.isEmpty,
              viewModel.agents.contains(where: { $0.id == pendingAgentID }) else { return }
        let agentID = pendingAgentID
        pendingAgentID = ""
        viewModel.openAgent(agentID)
    }

    private var keyboardShortcuts: some View {
            VStack(spacing: 0) {
                Button { viewModel.showingQuickOpen = true } label: { EmptyView() }
                    .keyboardShortcut("k", modifiers: .command)
                Button { viewModel.showOverview(!viewModel.showingOverview) } label: { EmptyView() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button { viewModel.showInbox(!viewModel.showingInbox) } label: { EmptyView() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button { viewModel.requestCloseFocusedPane() } label: { EmptyView() }
                    .keyboardShortcut("w", modifiers: .command)
                Button { viewModel.selectAdjacentTab(-1) } label: { EmptyView() }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .shift])
                Button { viewModel.selectAdjacentTab(1) } label: { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .shift])
                Button { viewModel.splitFocusedPane("right") } label: { EmptyView() }
                    .keyboardShortcut("d", modifiers: .command)
                Button { viewModel.splitFocusedPane("down") } label: { EmptyView() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button { viewModel.toggleZoom() } label: { EmptyView() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button { viewModel.moveFocus("left") } label: { EmptyView() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button { viewModel.moveFocus("right") } label: { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button { viewModel.moveFocus("up") } label: { EmptyView() }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button { viewModel.moveFocus("down") } label: { EmptyView() }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("1") { viewModel.selectTab(at: 0) }.keyboardShortcut("1", modifiers: .command)
                Button("2") { viewModel.selectTab(at: 1) }.keyboardShortcut("2", modifiers: .command)
                Button("3") { viewModel.selectTab(at: 2) }.keyboardShortcut("3", modifiers: .command)
                Button("4") { viewModel.selectTab(at: 3) }.keyboardShortcut("4", modifiers: .command)
                Button("5") { viewModel.selectTab(at: 4) }.keyboardShortcut("5", modifiers: .command)
                Button("6") { viewModel.selectTab(at: 5) }.keyboardShortcut("6", modifiers: .command)
                Button("7") { viewModel.selectTab(at: 6) }.keyboardShortcut("7", modifiers: .command)
                Button("8") { viewModel.selectTab(at: 7) }.keyboardShortcut("8", modifiers: .command)
                Button("9") { viewModel.selectTab(at: 8) }.keyboardShortcut("9", modifiers: .command)
            }
    }

    private var preferredStartEnvironmentID: String? { startAgentEnvironmentID ?? viewModel.activeEnvironment?.id }

    private func startAgent(kind: String, environmentID: String) {
        Task { await viewModel.startAgent(kind: kind, environmentID: environmentID) }
    }

    private func retainSessions(for tabs: [WorkspaceTab]) {
        var scratchIDs: [WorkspaceTab.ID] = []
        var paneIDs: Set<String> = []
        for tab in tabs {
            switch tab.destination {
            case .scratch:
                scratchIDs.append(tab.id)
            case .hive(let id):
                if let hiveTab = viewModel.workspace.tab(id) { paneIDs.formUnion(hiveTab.paneIDs) }
            case .remote, .remoteShell:
                break
            }
        }
        terminals.retain(scratchTabs: scratchIDs, panes: paneIDs)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            WorkspaceTabBar(
                items: viewModel.tabs.map { WorkspaceTabBar.Item(id: $0.id, title: title(for: $0.destination)) },
                activeID: $viewModel.activeTabID,
                onClose: viewModel.requestCloseTab,
                onCloseOthers: viewModel.closeOtherTabs
            )
        }
        .flatToolbarBackground()

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                // Main View Switcher
                HStack(spacing: 0) {
                    modeButton(systemImage: "tray.full", isActive: viewModel.showingInbox, color: .hiveAmber) {
                        viewModel.showInbox(true); viewModel.showOverview(false)
                    }
                    modeButton(systemImage: "terminal", isActive: !viewModel.showingInbox && !viewModel.showingOverview, color: .primary) {
                        viewModel.showInbox(false); viewModel.showOverview(false)
                    }
                    modeButton(systemImage: "rectangle.grid.2x2", isActive: viewModel.showingOverview, color: .hiveAmber) {
                        viewModel.showOverview(true); viewModel.showInbox(false)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5))

                Divider()
                    .frame(height: 12)
                    .opacity(0.2)

                // Compact Groups
                HStack(spacing: 4) {
                    HStack(spacing: 0) {
                        inspectorToggle(.files)
                        inspectorToggle(.changes)
                        inspectorToggle(.agent)
                    }
                    
                    Divider()
                        .frame(height: 12)
                        .opacity(0.2)
                        .padding(.horizontal, 2)
                    
                    HStack(spacing: 0) {
                        Button { reviewEnvironment = viewModel.activeEnvironment } label: {
                            Image(systemName: "checkmark.seal")
                        }
                        .buttonStyle(ToolbarPillButtonStyle())
                        .disabled(viewModel.activeEnvironment == nil)
                        
                        Button { showingTaskCenter = true } label: {
                            Image(systemName: "checklist")
                        }
                        .buttonStyle(ToolbarPillButtonStyle())

                        commandCenterMenu
                    }
                }

                paneMenu

                Button(action: viewModel.newTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.hiveAmber, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(.ultraThinMaterial).opacity(0.5))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    private func modeButton(systemImage: String, isActive: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isActive ? "\(systemImage).fill" : systemImage)
                .font(.system(size: 11, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? color : .secondary)
                .frame(width: 28, height: 22)
                .background {
                    if isActive {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func inspectorToggle(_ panel: InspectorPanel) -> some View {
        Button {
            let isOpening = inspectorPanel != panel
            if isOpening { lastInspectorPanel = panel }
            withAnimation(.easeInOut(duration: 0.2)) { inspectorPanel = isOpening ? panel : nil }
        } label: {
            Image(systemName: panel.symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(ToolbarPillButtonStyle(isActive: inspectorPanel == panel))
        .help(inspectorPanel == panel ? "Hide \(panel.title.lowercased())" : "Show \(panel.title.lowercased())")
    }

    /// Splits, zooms and closes panes in the active Hive tab, tmux style.
    private var paneMenu: some View {
        let hiveTab = viewModel.activeHiveTab
        let isSplit = (hiveTab?.paneIDs.count ?? 0) > 1
        return Menu {
            Button { viewModel.splitFocusedPane("right") } label: { Label("Split Right   ⌘D", systemImage: "rectangle.split.2x1") }
            Button { viewModel.splitFocusedPane("down") } label: { Label("Split Down   ⇧⌘D", systemImage: "rectangle.split.1x2") }
            Divider()
            Button { viewModel.toggleZoom() } label: {
                Label(hiveTab?.zoomed == nil ? "Zoom Pane   ⇧⌘M" : "Restore Layout   ⇧⌘M", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!isSplit)
            Button { viewModel.requestCloseFocusedPane() } label: { Label("Close Pane   ⌘W", systemImage: "xmark") }
                .disabled(!isSplit)
        } label: {
            Image(systemName: isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                .font(.system(size: 12, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .menuIndicator(.hidden)
        .buttonStyle(ToolbarPillButtonStyle(isActive: isSplit))
        .disabled(hiveTab == nil)
        .help(hiveTab == nil ? "Splitting needs a Hive tab in an environment" : "Split pane")
    }

    /// M7 · The personal command center: saved views, helper delegations, activity and usage.
    private var commandCenterMenu: some View {
        Menu {
            Button { showingWorkspaceViews = true } label: { Label("Saved views…", systemImage: "rectangle.3.group.bubble.left") }
            Button { showingDelegation = true } label: { Label("Delegate a helper…", systemImage: "arrow.triangle.branch") }
            Divider()
            Button { showingObservers = true } label: { Label("Observers…", systemImage: "eye") }
            Button { showingLayoutManager = true } label: { Label("Workspace layouts…", systemImage: "rectangle.3.group") }
            Button { showingActivity = true } label: { Label("Activity & sessions…", systemImage: "clock.arrow.circlepath") }
            Button { showingUsage = true } label: { Label("Usage & capacity…", systemImage: "gauge.with.dots.needle.33percent") }
            if let active = commandCenter.activeView {
                Divider()
                Button { commandCenter.clearActiveView(); viewModel.showOverview(false) } label: {
                    Label("Unapply “\(active.name)”", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "command")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(ToolbarPillButtonStyle(isActive: commandCenter.activeViewID != nil, color: .hiveAmber))
        .help("Command center")
    }

    // MARK: - Active view

    /// The settings of the saved view currently applied to the shell, if any.
    private var activeViewSettings: WorkspaceViewSettings? { commandCenter.activeView?.settings }

    private var showsEnvironmentsSection: Bool { activeViewSettings?.showsEnvironments ?? true }
    private var showsAgentsSection: Bool { activeViewSettings?.showsAgents ?? true }
    private var showsMachinesSection: Bool { activeViewSettings?.showsMachines ?? true }
    private var groupsWorktrees: Bool { activeViewSettings?.groupsWorktrees ?? true }
    private var sidebarRowHeight: Double { activeViewSettings?.density.rowHeight ?? 22 }

    /// Applies the active view's declarative settings to the shell. Nothing here executes code;
    /// a view only chooses which sections show, how dense they are and where the detail lands.
    private func applyActiveView() {
        guard let settings = activeViewSettings else { return }
        switch settings.kind {
        case .terminal:
            viewModel.showOverview(false)
            viewModel.showInbox(false)
        case .overview:
            viewModel.showOverview(true)
        case .statusBoard:
            viewModel.showInbox(true)
        }
        if settings.showsInspector, let raw = settings.inspector, let panel = InspectorPanel(rawValue: raw) {
            lastInspectorPanel = panel
            inspectorPanel = panel
        } else {
            inspectorPanel = nil
        }
    }

    @ViewBuilder
    private var inspector: some View {
        let changeToken = AnyHashable(viewModel.activeEnvironment?.git)
        if let tab = viewModel.activeTab, case .scratch = tab.destination {
            ActiveTerminalInspector(
                session: terminals.scratchSession(for: tab) { makeScratchSession(for: tab) },
                panel: lastInspectorPanel,
                changeToken: changeToken,
                selectedChangePath: requestedChangePath,
                viewModel: viewModel
            )
        } else if let paneID = viewModel.focusedPaneID {
            // A Hive tab: follow the focused pane's shell, not the environment it started in.
            // Get-or-create, since the tab view may not have drawn the pane yet.
            ActiveTerminalInspector(
                session: terminals.paneSession(paneID, viewModel: viewModel),
                panel: lastInspectorPanel,
                changeToken: changeToken,
                selectedChangePath: requestedChangePath,
                viewModel: viewModel
            )
        } else {
            WorkspaceInspectorView(
                panel: lastInspectorPanel,
                directory: viewModel.activeEnvironment?.path ?? FileManager.default.homeDirectoryForCurrentUser.path,
                changeToken: changeToken,
                selectedChangePath: requestedChangePath,
                viewModel: viewModel
            )
        }
    }

    private var inspectorIsPresented: Binding<Bool> {
        Binding(
            get: { inspectorPanel != nil },
            set: { if !$0 { inspectorPanel = nil } }
        )
    }

    private func title(for destination: WorkspaceDestination) -> String {
        switch destination {
        case .scratch:
            return "zsh · ~"
        case .hive(let id):
            guard let tab = viewModel.workspace.tab(id) else { return "Hive Tab" }
            let environment = viewModel.environments.first(where: { $0.id == tab.environmentID })
            return "\(tab.name) · \(environment.map(displayName) ?? tab.environmentID)"
        case .remote(let machine, _, let title):
            return "\(title) · \(machine)"
        case .remoteShell(let machine, _):
            return "SSH · \(machine)"
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                if showsEnvironmentsSection {
                    SidebarSectionHeader(title: "Spaces", symbol: "folder", actionIcon: "plus", action: { showingCreateEnvironment = true })
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                    
                    // "This computer" (Local machine) first
                    machineHeader(name: "This computer", symbol: "desktopcomputer", isLocal: true)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                    
                    ForEach(localEnvironments) { environment in
                        EnvironmentSidebarRow(environment: environment, ports: viewModel.listeningPorts[environment.id] ?? [])
                            .tag(SidebarItem.environment(environment.id))
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                            .contextMenu { environmentMenu(environment) }
                    }
                    
                    // Other machines
                    ForEach(filteredMachines) { machine in
                        machineHeader(
                            name: machine.name,
                            symbol: "server.rack",
                            status: viewModel.machineStatuses[machine.name],
                            isRefreshing: viewModel.refreshingMachines.contains(machine.name)
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                        
                        ForEach(environments(for: machine)) { environment in
                            EnvironmentSidebarRow(environment: environment, ports: viewModel.listeningPorts[environment.id] ?? [])
                                .tag(SidebarItem.environment(environment.id))
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                                .contextMenu { environmentMenu(environment) }
                        }
                    }
                }

                if showsAgentsSection {
                    SidebarSectionHeader(title: "Agents", symbol: "square.stack.3d.up", showsDivider: true)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                    
                    ForEach(environmentsWithAgents, id: \.id) { environment in
                        Text(environment.name.isEmpty ? environment.id : environment.name)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .kerning(0.5)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                        
                        ForEach(agents(in: environment)) { agent in
                            AgentSidebarRow(agent: agent) { image in
                                Task { await viewModel.pasteImage(image, toAgent: agent.id) }
                            }
                            .tag(SidebarItem.agent(agent.id))
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                            .contextMenu { agentMenu(agent) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, sidebarRowHeight)
            
            sidebarFooter
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    }

    @ViewBuilder
    private func machineHeader(name: String, symbol: String, status: HiveMachineStatus? = nil, isRefreshing: Bool = false, isLocal: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            Text(name)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
            
            Spacer()
            
            if isLocal {
                Button(action: { showingCreateEnvironment = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            }
            
            if isRefreshing {
                StatusIndicator(state: .processing)
            } else if !isLocal {
                StatusIndicator(state: (status?.reachable == true) ? .ready : .idle)
            } else {
                StatusIndicator(state: .ready)
            }
            
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
        }
        .padding(.vertical, 8)
    }

    private var localEnvironments: [HiveEnvironment] {
        filteredEnvironments.filter { env in
            !viewModel.machines.contains(where: { machine in
                (viewModel.machineEnvironments[machine.name] ?? []).contains(where: { $0.id == env.id })
            })
        }
    }

    private func environments(for machine: SavedHiveMachine) -> [HiveEnvironment] {
        (viewModel.machineEnvironments[machine.name] ?? []).filter { env in
            searchText.isEmpty || env.name.localizedCaseInsensitiveContains(searchText) || env.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var environmentsWithAgents: [HiveEnvironment] {
        let allAgents = filteredAgents + viewModel.machineAgents.values.flatMap { $0 }
        let envIDs = Set(allAgents.map { $0.environmentID })
        return viewModel.environments.filter { envIDs.contains($0.id) }
    }

    private func agents(in environment: HiveEnvironment) -> [HiveAgent] {
        let allAgents = filteredAgents + viewModel.machineAgents.values.flatMap { $0 }
        return allAgents.filter { $0.environmentID == environment.id }
    }

    @ViewBuilder
    private func environmentMenu(_ environment: HiveEnvironment) -> some View {
        let ports = viewModel.listeningPorts[environment.id] ?? []

        Button("Open") { viewModel.openEnvironment(environment.id) }
        Button("New Hive Tab Here") { Task { await viewModel.newHiveTab(in: environment.id) } }
        Button("Start Agent Here…") { startAgent(in: environment.id) }
        if environment.worktree == nil {
            Button("New Worktree…") { worktreeRepository = environment }
        }

        Divider()

        Menu("Kill Ports") {
            ForEach(ports) { port in
                Button(":\(port.port)  \(port.command)") {
                    Task { await viewModel.killPorts([port]) }
                }
            }
            if ports.count > 1 {
                Divider()
                Button("Kill All \(ports.count) Ports") {
                    Task { await viewModel.killPorts(ports) }
                }
            }
        }
        .disabled(ports.isEmpty)

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: environment.path)])
        }
        Button("Copy Path") { copyToPasteboard(environment.path) }

        Divider()

        Button("Remove Environment…", role: .destructive) {
            environmentPendingRemoval = environment
        }
    }

    @ViewBuilder
    private func agentMenu(_ agent: HiveAgent) -> some View {
        Button("Open") { viewModel.openAgent(agent.id) }
        Button("New Hive Tab in \(agent.environmentID)") { Task { await viewModel.newHiveTab(in: agent.environmentID) } }
        Button("Delegate Helper…") { delegationParentID = agent.id; showingDelegation = true }

        Divider()

        Button("Stop Agent") {
            Task { await viewModel.stopAgent(agent.id) }
        }
        .disabled(agent.state == "exited")
        if let paneID = agent.paneID {
            Button("Kill Agent and Close Pane", role: .destructive) {
                Task { await viewModel.closePane(paneID) }
            }
        }

        Divider()

        Button("Copy Agent ID") { copyToPasteboard(agent.id) }
    }

    private func startAgent(in environmentID: String?) {
        startAgentEnvironmentID = environmentID
        showingStartAgent = true
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func displayName(_ environment: HiveEnvironment) -> String {
        environment.name.isEmpty ? environment.id : environment.name
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            if let error = viewModel.sidebarError ?? viewModel.connectionProblem {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack(spacing: 6) {
                StatusIndicator(state: isConnected ? .ready : .idle)
                Text(isConnected ? "Connected" : "Runtime unavailable")
                    .foregroundStyle(.secondary)
                if isConnected && activeAgentCount > 0 {
                    Text("· \(activeAgentCount) active")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                Menu {
                    Button("New Terminal") { viewModel.newTab() }
                    Divider()
                    Button("New Environment…") { showingCreateEnvironment = true }
                    Button("Start Agent…") { startAgent(in: nil) }
                    Divider()
                    Button("Add Machine…") { showingAddMachine = true }
                    Button("Discover Nearby…") { showingNearbyMachines = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if viewModel.showingInbox {
            InboxView(
                viewModel: viewModel,
                commandCenter: commandCenter,
                onReview: { environment, _ in
                    if let environment { reviewEnvironment = environment }
                },
                onDelegate: { agent in
                    delegationParentID = agent.id
                    showingDelegation = true
                },
                onClose: { viewModel.showInbox(false) }
            )
        } else if viewModel.showingOverview {
            OverviewView(viewModel: viewModel)
        } else if let tab = viewModel.activeTab {
            Group {
                switch tab.destination {
                case .hive(let id):
                    if let hiveTab = viewModel.workspace.tab(id) {
                        HiveTabView(tab: hiveTab, viewModel: viewModel, terminals: terminals)
                    } else {
                        ProgressView("Loading tab…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .scratch:
                    TerminalSurface(
                        session: terminals.scratchSession(for: tab) { makeScratchSession(for: tab) },
                        onClose: { viewModel.requestCloseTab(tab.id) }
                    )
                case .remote(let machine, let agentID, _):
                    TerminalSurface(
                        session: terminals.scratchSession(for: tab) {
                            ShellTerminalSession(launch: TerminalLaunch(executable: hiveURL.path, arguments: ["--machine", machine, "agent", "attach", agentID], execName: nil, directory: FileManager.default.homeDirectoryForCurrentUser.path))
                        },
                        onClose: { viewModel.requestCloseTab(tab.id) }
                    )
                case .remoteShell(_, let host):
                    TerminalSurface(
                        session: terminals.scratchSession(for: tab) {
                            ShellTerminalSession(launch: TerminalLaunch(executable: "/usr/bin/ssh", arguments: ["-tt", host], execName: nil, directory: FileManager.default.homeDirectoryForCurrentUser.path))
                        },
                        onClose: { viewModel.requestCloseTab(tab.id) }
                    )
                }
            }
            .id(tab.id)
        } else {
            NoTerminalsView(onNewTerminal: viewModel.newTab)
        }
    }

    private func makeScratchSession(for tab: WorkspaceTab) -> ShellTerminalSession {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = tab.directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? home
        return ShellTerminalSession(launch: TerminalLaunch(executable: "/bin/zsh", arguments: [], execName: "-zsh", directory: directory))
    }

    private func saveDirectories() {
        viewModel.updateDirectories(terminals.scratchDirectories)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch viewModel.activeTab?.destination {
                case .hive(let id):
                    if let agent = viewModel.agents.first(where: { $0.tabID == id }) { .agent(agent.id) }
                    else if let environmentID = viewModel.workspace.tab(id)?.environmentID { .environment(environmentID) }
                    else { nil }
                case .scratch, .remote, .remoteShell, nil: nil
                }
            },
            set: { item in
                switch item {
                case .environment(let id): viewModel.openEnvironment(id)
                case .agent(let id): viewModel.openAgent(id)
                case .machine(let name):
                    if let machine = viewModel.machines.first(where: { $0.name == name }) { viewModel.inspectMachine(machine) }
                case nil: break
                }
            }
        )
    }

    private var isConnected: Bool { viewModel.isConnected }

    private var activeAgentCount: Int { viewModel.agents.filter { $0.state == "working" }.count }

    private var filteredEnvironments: [HiveEnvironment] {
        guard !searchText.isEmpty else { return viewModel.environments }
        return viewModel.environments.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var nonWorktreeEnvironments: [HiveEnvironment] { filteredEnvironments.filter { $0.worktree == nil } }

    private var worktreeRepositories: [String] {
        Array(Set(filteredEnvironments.compactMap { $0.worktree?.repo })).sorted()
    }

    private func worktreeEnvironments(in repo: String) -> [HiveEnvironment] {
        filteredEnvironments.filter { $0.worktree?.repo == repo }.sorted { ($0.worktree?.branch ?? $0.name) < ($1.worktree?.branch ?? $1.name) }
    }

    @ViewBuilder
    private func environmentSidebarRow(_ environment: HiveEnvironment) -> some View {
        EnvironmentSidebarRow(environment: environment, ports: viewModel.listeningPorts[environment.id] ?? [])
            .tag(SidebarItem.environment(environment.id))
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .contextMenu { environmentMenu(environment) }
    }

    private var filteredAgents: [HiveAgent] {
        let agents = viewModel.agents.sorted { $0.stateRank < $1.stateRank }
        guard !searchText.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.kind.localizedCaseInsensitiveContains(searchText) ||
            $0.environmentID.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredMachines: [SavedHiveMachine] {
        guard !searchText.isEmpty else { return viewModel.machines }
        return viewModel.machines.filter { $0.name.localizedCaseInsensitiveContains(searchText) || $0.host.localizedCaseInsensitiveContains(searchText) }
    }
}

private struct EnvironmentRemovalDialog: ViewModifier {
    @Binding var environment: HiveEnvironment?
    let remove: (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(environment.map { $0.name.isEmpty ? $0.id : $0.name } ?? "environment")?",
            isPresented: Binding(
                get: { environment != nil },
                set: { if !$0 { environment = nil } }
            ),
            presenting: environment
        ) { environment in
            Button("Remove Environment", role: .destructive) { remove(environment.id) }
        } message: { environment in
            Text(environment.managed
                 ? "Its agents are stopped and the workspace Hive created is deleted."
                 : "Its agents are stopped. Your folder stays where it is.")
        }
    }
}

private struct PendingCloseDialog: ViewModifier {
    @Binding var pending: AppViewModel.PendingClose?
    let confirm: (AppViewModel.PendingClose) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Close?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            presenting: pending
        ) { item in
            switch item {
            case .pane:
                Button("Close Pane and Stop Agent", role: .destructive) { confirm(item) }
            case .tab:
                Button("Close Tab and Stop Agents", role: .destructive) { confirm(item) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { item in
            switch item {
            case .pane(_, let agent): Text("This stops \(agent.name.isEmpty ? agent.kind : agent.name).")
            case .tab(_, _, let agents): Text("This stops \(agents.count) running agent\(agents.count == 1 ? "" : "s").")
            }
        }
    }
}

private struct QuickOpenOverlay: ViewModifier {
    @Binding var showing: Bool
    @ObservedObject var viewModel: AppViewModel

    func body(content: Content) -> some View {
        content.overlay {
            if showing {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea().onTapGesture { showing = false }
                    QuickOpenView(viewModel: viewModel)
                }
                .transition(.opacity)
            }
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let symbol: String
    var showsDivider = false
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider {
                Divider()
                    .padding(.vertical, 8)
                    .opacity(0.5)
            }
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                
                Spacer()
                
                if let actionIcon, let action {
                    Button(action: action) {
                        Image(systemName: actionIcon)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }
}

private struct SidebarEmptyState: View {
    let text: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .foregroundStyle(.tertiary)
            if let actionTitle {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                        .foregroundStyle(Color.hiveAmber)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.vertical, 1)
        .selectionDisabled()
    }
}

private struct EnvironmentSidebarRow: View {
    let environment: HiveEnvironment
    let ports: [ListeningPort]

    private var branch: String? {
        environment.git?.branch
    }

    private var status: StatusIndicator.IndicatorState {
        if (environment.git?.conflicts ?? 0) > 0 { return .needsAttention }
        if environment.status == "working" { return .processing }
        return environment.status == "ready" ? .ready : .idle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            EnvironmentAvatar(name: environment.name.isEmpty ? environment.id : environment.name)
                .frame(width: 20)

            Text(environment.name.isEmpty ? environment.id : environment.name)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)

            Spacer(minLength: 4)

            HStack(alignment: .center, spacing: 6) {
                if let branch {
                    Text(branch)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Circle()
                        .fill(Color.hiveAmber.opacity(0.8))
                        .frame(width: 4, height: 4)
                }
                
                if (environment.git?.conflicts ?? 0) > 0 {
                    NeedsYouBadge()
                } else {
                    StatusIndicator(state: status)
                }
            }
        }
        .padding(.vertical, 3)
        .help(environment.path)
    }
}

private struct AgentSidebarRow: View {
    let agent: HiveAgent
    let onDropImage: (Data) -> Void
    @State private var isDropTargeted = false

    private var status: StatusIndicator.IndicatorState {
        switch agent.state {
        case "working": return .processing
        case "blocked": return .needsAttention
        case "done", "idle": return .ready
        default: return .idle
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AgentProviderIcon(kind: agent.kind, size: 14)
                .frame(width: 20)
            
            Text(agent.name.isEmpty ? agent.kind : agent.name)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
            
            Spacer(minLength: 4)
            
            HStack(alignment: .center, spacing: 8) {
                if agent.state == "blocked" {
                    NeedsYouBadge()
                } else {
                    let time = formatAgentTime(agent.since)
                    if time.isEmpty || agent.state == "exited" || agent.state == "unknown" {
                        Text(agentStateTitle(agent.state))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(time)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    StatusIndicator(state: status)
                }
            }
        }
        .padding(.horizontal, isDropTargeted ? 5 : 0)
        .background(isDropTargeted ? Color.hiveAmber.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .frame(height: 32)
        .help(agent.reason ?? "\(agent.kind) · \(agent.state)")
        .onDrop(of: [UTType.image.identifier], isTargeted: $isDropTargeted) { providers in
            guard agent.paneID != nil, let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let image = NSImage(data: data),
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { return }
                DispatchQueue.main.async { onDropImage(png) }
            }
            return true
        }
    }
}

private struct MachineSidebarRow: View {
    let machine: SavedHiveMachine
    let status: HiveMachineStatus?
    let isRefreshing: Bool

    private var statusState: StatusIndicator.IndicatorState {
        if machine.disabled == true { return .idle }
        guard let status else { return .idle }
        return status.reachable ? .ready : .idle
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(machine.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 4)
            
            if isRefreshing {
                StatusIndicator(state: .processing)
            } else {
                HStack(spacing: 6) {
                    if let count = status?.agents, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    StatusIndicator(state: statusState)
                }
            }
        }
        .padding(.vertical, 4)
        .help(machine.host)
    }

    private var detail: String {
        if machine.disabled == true { return "Disabled" }
        guard let status else { return "Not checked" }
        return status.reachable ? (status.state.map { "Connected · \($0)" } ?? "Connected") : "Unavailable"
    }
}

/// Follows the terminal's `cd`s so Files and Changes show where you are.
private struct ActiveTerminalInspector: View {
    @ObservedObject var session: TerminalSession
    let panel: InspectorPanel
    let changeToken: AnyHashable
    let selectedChangePath: String?
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        WorkspaceInspectorView(panel: panel, directory: session.currentDirectory, changeToken: changeToken, selectedChangePath: selectedChangePath, viewModel: viewModel)
    }
}

private struct NoTerminalsView: View {
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            Image("HiveBee")
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 58, height: 52)
            Text("No open terminals")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("Pick an environment or agent from the sidebar, or open a shell.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onNewTerminal) { Label("New Terminal", systemImage: "terminal") }
                .buttonStyle(.hivePrimary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CreateEnvironmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folderPath = ""
    let onCreate: (String, String) -> Void

    var body: some View {
        HiveFormSheet(
            symbol: "folder.badge.plus",
            title: "Add an environment",
            subtitle: "Choose a project folder. Hive will use it as the working directory for agents.",
            actionTitle: "Add environment",
            actionSymbol: "plus",
            canSubmit: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folderPath.isEmpty,
            width: 480,
            onCancel: { dismiss() },
            onSubmit: {
                onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), folderPath)
                dismiss()
            }
        ) {
            HiveFieldLabel(title: "Folder") {
                Button(action: chooseFolder) {
                    HStack(spacing: 10) {
                        Image(systemName: folderPath.isEmpty ? "folder.badge.questionmark" : "folder.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.hiveAmber)
                            .contentTransition(.symbolEffect(.replace))
                        Text(folderPath.isEmpty ? "Choose a project folder…" : folderPath)
                            .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(folderPath.isEmpty ? "Choose…" : "Change…")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.hiveAmber)
                    }
                    .hiveCard(padding: 10, interactive: true)
                }
                .buttonStyle(.plain)
            }
            HiveFieldLabel(title: "Name") {
                TextField("Environment name", text: $name)
                    .textFieldStyle(.hive)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a project folder"
        panel.message = "Hive will run agents in this existing folder."
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderPath = url.path
        if name.isEmpty { name = environmentID(from: url.lastPathComponent) }
    }

    private func environmentID(from folderName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let normalized = String(folderName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return String((normalized.isEmpty ? "workspace" : normalized).prefix(64))
    }
}

private struct StartAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let environments: [HiveEnvironment]
    let kinds: [HiveAgentManifest]
    let preferredEnvironmentID: String?
    let onStart: (String, String) -> Void
    @State private var selectedEnvironment = ""
    @State private var selectedKind = ""

    var body: some View {
        HiveFormSheet(
            symbol: "sparkles",
            title: "Start an agent",
            subtitle: "Choose where it should work and which installed agent to start.",
            actionTitle: "Start agent",
            actionSymbol: "play.fill",
            canSubmit: !selectedEnvironment.isEmpty && !selectedKind.isEmpty,
            width: 440,
            onCancel: { dismiss() },
            onSubmit: {
                onStart(selectedKind, selectedEnvironment)
                dismiss()
            }
        ) {
            HiveFieldLabel(title: "Agent") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(kinds) { kind in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selectedKind = kind.id }
                        } label: {
                            HStack(spacing: 8) {
                                AgentProviderIcon(kind: kind.id, size: 13)
                                Text(kind.name.isEmpty ? kind.id : kind.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .hiveCard(padding: 8, interactive: true, isSelected: selectedKind == kind.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HiveFieldLabel(title: "Environment") {
                Picker("Environment", selection: $selectedEnvironment) {
                    ForEach(environments) { environment in
                        Text(environment.name.isEmpty ? environment.id : environment.name).tag(environment.id)
                    }
                }
                .labelsHidden()
            }
        }
        .onAppear {
            selectedEnvironment = environments.first(where: { $0.id == preferredEnvironmentID })?.id
                ?? environments.first?.id
                ?? ""
            selectedKind = kinds.first?.id ?? ""
        }
        .overlay {
            if environments.isEmpty || kinds.isEmpty {
                VStack(spacing: 10) {
                    HiveBadgeIcon(symbol: environments.isEmpty ? "folder" : "sparkles", size: 36)
                    Text(environments.isEmpty ? "Add an environment first" : "No agents are available")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(environments.isEmpty ? "Choose a project folder from the sidebar to create one." : "Install an agent CLI and check `hive agent manifests`.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }
                        .buttonStyle(.hive)
                        .padding(.top, 4)
                }
                .padding(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
    }
}

private struct NewWorktreeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let environment: HiveEnvironment
    let kinds: [HiveAgentManifest]
    let onCreate: (String, String?, String?) -> Void
    @State private var branch = ""
    @State private var base = ""
    @State private var startAgent = false
    @State private var selectedKind = ""

    var body: some View {
        HiveFormSheet(
            symbol: "arrow.triangle.branch",
            title: "New worktree",
            subtitle: "Create a branch and worktree from \(environment.path).",
            actionTitle: "Create worktree",
            actionSymbol: "plus",
            canSubmit: !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(startAgent && selectedKind.isEmpty),
            onCancel: { dismiss() },
            onSubmit: {
                onCreate(branch.trimmingCharacters(in: .whitespacesAndNewlines), base.isEmpty ? nil : base, startAgent ? selectedKind : nil)
                dismiss()
            }
        ) {
            HStack(spacing: 10) {
                HiveFieldLabel(title: "Branch") {
                    TextField("feature/name", text: $branch).textFieldStyle(.hive)
                }
                HiveFieldLabel(title: "Base") {
                    TextField("Optional", text: $base).textFieldStyle(.hive)
                }
            }
            Toggle("Start an agent after creation", isOn: $startAgent.animation(.spring(response: 0.3, dampingFraction: 0.85)))
                .toggleStyle(.switch)
                .controlSize(.small)
            if startAgent {
                Picker("Agent", selection: $selectedKind) {
                    ForEach(kinds) { kind in Text(kind.name.isEmpty ? kind.id : kind.name).tag(kind.id) }
                }
                .disabled(kinds.isEmpty)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { selectedKind = kinds.first?.id ?? "" }
    }
}

private struct AddMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    let onAdd: (String, String) -> Void

    var body: some View {
        HiveFormSheet(
            symbol: "server.rack",
            title: "Add a machine",
            subtitle: "Use an SSH host from ~/.ssh/config or enter user@host. Hive saves it through the CLI; you can connect to it afterward.",
            actionTitle: "Add machine",
            actionSymbol: "plus",
            canSubmit: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            width: 450,
            onCancel: { dismiss() },
            onSubmit: {
                onAdd(name.trimmingCharacters(in: .whitespacesAndNewlines), host.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            }
        ) {
            HiveFieldLabel(title: "Name") {
                TextField("build-box", text: $name).textFieldStyle(.hive)
            }
            HiveFieldLabel(title: "SSH host") {
                TextField("SSH host or user@host", text: $host).textFieldStyle(.hive)
            }
        }
    }
}
