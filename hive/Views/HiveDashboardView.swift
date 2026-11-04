import AppKit
import SwiftUI

private enum SidebarItem: Hashable {
    case environment(String)
    case agent(String)
}
struct HiveDashboardView: View {
    let hiveURL: URL

    @StateObject private var viewModel: AppViewModel
    @StateObject private var terminals = TerminalStore()
    @State private var searchText = ""
    @AppStorage("hive.desktop.environmentsExpanded") private var environmentsExpanded = true
    @AppStorage("hive.desktop.agentsExpanded") private var agentsExpanded = true
    @AppStorage("hive.desktop.inspector") private var inspectorPanel: InspectorPanel?
    @AppStorage("hive.desktop.lastInspector") private var lastInspectorPanel: InspectorPanel = .files
    @State private var showingCreateEnvironment = false
    @State private var showingStartAgent = false
    @State private var startAgentEnvironmentID: String?
    @State private var environmentPendingRemoval: HiveEnvironment?
    @State private var showingAddMachine = false

    init(hiveURL: URL) {
        self.hiveURL = hiveURL
        _viewModel = StateObject(wrappedValue: AppViewModel(hiveURL: hiveURL))
    }

    var body: some View {
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
        .tint(.hiveAmber)
        .background {
            keyboardShortcuts.frame(width: 0, height: 0).hidden()
        }
        .onChange(of: viewModel.tabs) { _, tabs in
            retainSessions(for: tabs)
        }
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
        .task { viewModel.start() }
        .onChange(of: viewModel.activeTabID) { saveDirectories() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveDirectories()
        }
        .frame(minWidth: 820, minHeight: 540)
    }

    private var keyboardShortcuts: some View {
            VStack(spacing: 0) {
                Button { viewModel.showingQuickOpen = true } label: { EmptyView() }
                    .keyboardShortcut("k", modifiers: .command)
                Button { viewModel.showingOverview.toggle() } label: { EmptyView() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
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
            HStack(spacing: 4) {
                Button(action: viewModel.newTab) {
                    Image(systemName: "plus")
                }
                .buttonStyle(ToolbarPillButtonStyle())
                .keyboardShortcut("t", modifiers: .command)
                .help("New terminal (⌘T)")
                .accessibilityLabel("New terminal")

                inspectorToggle(.files)
                inspectorToggle(.changes)
                inspectorToggle(.agent)
                Button { viewModel.showingOverview.toggle() } label: {
                    Label("Overview", systemImage: "rectangle.grid.2x2")
                }
                .buttonStyle(ToolbarPillButtonStyle(isActive: viewModel.showingOverview))
                .help("Overview (⇧⌘O)")
            }
        }
        .flatToolbarBackground()
    }

    private func inspectorToggle(_ panel: InspectorPanel) -> some View {
        Button {
            let isOpening = inspectorPanel != panel
            if isOpening { lastInspectorPanel = panel }
            withAnimation(.easeInOut(duration: 0.2)) { inspectorPanel = isOpening ? panel : nil }
        } label: {
            Label(panel.title, systemImage: panel.symbol)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(ToolbarPillButtonStyle(isActive: inspectorPanel == panel))
        .help(inspectorPanel == panel ? "Hide \(panel.title.lowercased())" : "Show \(panel.title.lowercased())")
    }

    @ViewBuilder
    private var inspector: some View {
        let changeToken = AnyHashable(viewModel.activeEnvironment?.git)
        if let tab = viewModel.activeTab, case .scratch = tab.destination {
            ActiveTerminalInspector(
                session: terminals.scratchSession(for: tab) { makeScratchSession(for: tab) },
                panel: lastInspectorPanel,
                changeToken: changeToken,
                viewModel: viewModel
            )
        } else {
            WorkspaceInspectorView(
                panel: lastInspectorPanel,
                directory: viewModel.activeEnvironment?.path ?? FileManager.default.homeDirectoryForCurrentUser.path,
                changeToken: changeToken,
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
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Section(isExpanded: $environmentsExpanded) {
                    if filteredEnvironments.isEmpty {
                        SidebarEmptyState(
                            text: searchText.isEmpty ? "No environments yet" : "No matching environments",
                            actionTitle: searchText.isEmpty ? "Add environment" : nil,
                            action: { showingCreateEnvironment = true }
                        )
                    } else {
                        ForEach(filteredEnvironments) { environment in
                            EnvironmentSidebarRow(environment: environment, ports: viewModel.listeningPorts[environment.id] ?? [])
                                .tag(SidebarItem.environment(environment.id))
                                .contextMenu { environmentMenu(environment) }
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Environments", symbol: "folder", count: filteredEnvironments.count)
                }

                Section(isExpanded: $agentsExpanded) {
                    if filteredAgents.isEmpty {
                        SidebarEmptyState(
                            text: searchText.isEmpty ? "No agents running" : "No matching agents",
                            actionTitle: searchText.isEmpty ? "Start agent" : nil,
                            action: { startAgent(in: nil) }
                        )
                    } else {
                        ForEach(filteredAgents) { agent in
                            AgentSidebarRow(agent: agent)
                                .tag(SidebarItem.agent(agent.id))
                                .contextMenu { agentMenu(agent) }
                        }
                    }
                } header: {
                    SidebarSectionHeader(title: "Agents", symbol: "sparkles", count: filteredAgents.count, showsDivider: true)
                }
            }
            .listStyle(.sidebar)

            sidebarFooter
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    }

    @ViewBuilder
    private func environmentMenu(_ environment: HiveEnvironment) -> some View {
        let ports = viewModel.listeningPorts[environment.id] ?? []

        Button("Open") { viewModel.openEnvironment(environment.id) }
        Button("New Hive Tab Here") { Task { await viewModel.newHiveTab(in: environment.id) } }
        Button("Start Agent Here…") { startAgent(in: environment.id) }

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
                StatusDot(color: isConnected ? .hiveAmber : .red, isGlowing: isConnected)
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
        if viewModel.showingOverview {
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
                case .scratch, nil: nil
                }
            },
            set: { item in
                switch item {
                case .environment(let id): viewModel.openEnvironment(id)
                case .agent(let id): viewModel.openAgent(id)
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

    private var filteredAgents: [HiveAgent] {
        let agents = viewModel.agents.sorted { $0.stateRank < $1.stateRank }
        guard !searchText.isEmpty else { return agents }
        return agents.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.kind.localizedCaseInsensitiveContains(searchText) ||
            $0.environmentID.localizedCaseInsensitiveContains(searchText)
        }
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
    let count: Int
    var showsDivider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsDivider {
                Divider()
                    .padding(.top, 6)
            }
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.hiveAmber)
                    .frame(width: 14)
                Text(title)
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
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
        .padding(.vertical, 2)
        .selectionDisabled()
    }
}

private struct EnvironmentSidebarRow: View {
    let environment: HiveEnvironment
    let ports: [ListeningPort]

    private var detail: String? {
        let parts = [environment.git?.branch].compactMap { $0 }.filter { !$0.isEmpty }
            + ports.map { ":\($0.port)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: environment.status == "ready" ? .hiveAmber : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(environment.name.isEmpty ? environment.id : environment.name)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help(environment.path)
    }
}

private struct AgentSidebarRow: View {
    let agent: HiveAgent

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: agentStateColor(agent.state), isGlowing: agent.state == "working")
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name.isEmpty ? agent.kind : agent.name)
                    .lineLimit(1)
                Text("\(agent.kind) · \(agent.environmentID)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(agentStateTitle(agent.state))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help(agent.reason ?? "\(agent.kind) · \(agent.state)")
    }
}

private struct StatusDot: View {
    let color: Color
    var isGlowing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: isGlowing ? color.opacity(0.7) : .clear, radius: 3)
            .frame(width: 16)
    }
}

/// Follows the terminal's `cd`s so Files and Changes show where you are.
private struct ActiveTerminalInspector: View {
    @ObservedObject var session: TerminalSession
    let panel: InspectorPanel
    let changeToken: AnyHashable
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        WorkspaceInspectorView(panel: panel, directory: session.currentDirectory, changeToken: changeToken, viewModel: viewModel)
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
            Button("New Terminal", action: onNewTerminal)
                .buttonStyle(.borderedProminent)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Add an environment").font(.title2.weight(.semibold))
            Text("Choose a project folder. Hive will use it as the working directory for agents.")
                .foregroundStyle(.secondary)
            TextField("Environment name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(folderPath.isEmpty ? "No folder selected" : folderPath)
                    .font(.callout).foregroundStyle(folderPath.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose folder…", action: chooseFolder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add environment") {
                    onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), folderPath)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderPath.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Start an agent").font(.title2.weight(.semibold))
            Text("Choose where it should work and which installed agent to start.")
                .foregroundStyle(.secondary)
            Picker("Environment", selection: $selectedEnvironment) {
                ForEach(environments) { environment in
                    Text(environment.name.isEmpty ? environment.id : environment.name).tag(environment.id)
                }
            }
            Picker("Agent", selection: $selectedKind) {
                ForEach(kinds) { kind in Text(kind.name.isEmpty ? kind.id : kind.name).tag(kind.id) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start agent") {
                    onStart(selectedKind, selectedEnvironment)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedEnvironment.isEmpty || selectedKind.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            selectedEnvironment = environments.first(where: { $0.id == preferredEnvironmentID })?.id
                ?? environments.first?.id
                ?? ""
            selectedKind = kinds.first?.id ?? ""
        }
        .overlay {
            if environments.isEmpty || kinds.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: environments.isEmpty ? "folder" : "sparkles")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(environments.isEmpty ? "Add an environment first" : "No agents are available")
                        .font(.headline)
                    Text(environments.isEmpty ? "Choose a project folder from the sidebar to create one." : "Install an agent CLI and check `hive agent manifests`.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Close") { dismiss() }.padding(.top, 4)
                }
                .padding(26)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
    }
}

private struct AddMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    let onAdd: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a machine").font(.title2.weight(.semibold))
            Text("Use an SSH host from ~/.ssh/config or enter user@host. Hive saves it through the CLI; you can connect to it from Hive afterward.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("SSH host or user@host", text: $host).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add machine") {
                    onAdd(name.trimmingCharacters(in: .whitespacesAndNewlines), host.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
