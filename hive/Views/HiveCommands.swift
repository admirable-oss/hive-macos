import SwiftUI

/// The menu bar's Tab, Pane and Commands menus, so every workspace action can be found, and
/// remapped in System Settings → Keyboard. They act on the frontmost Hive window.
struct HiveCommands: Commands {
    @FocusedObject private var viewModel: AppViewModel?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { viewModel?.newTab() }
                .keyboardShortcut("t")
                .disabled(viewModel == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Group {
                Button("Go to Agent or Pane…") { viewModel?.showingQuickOpen = true }
                    .keyboardShortcut("k")
                Button(viewModel?.showingOverview == true ? "Hide Overview" : "Show Overview") {
                    viewModel.map { $0.showOverview(!$0.showingOverview) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button(viewModel?.showingInbox == true ? "Hide Inbox" : "Show Inbox") {
                    viewModel.map { $0.showInbox(!$0.showingInbox) }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            .disabled(viewModel == nil)
        }

        CommandMenu("Tab") { tabMenu }
        CommandMenu("Pane") { paneMenu }
        CommandMenu("Commands") { commandsMenu }

        CommandGroup(after: .help) {
            Group {
                Button("Keyboard Shortcuts") { viewModel?.showingShortcuts = true }
                    .keyboardShortcut("/")
                Button("Try the Demo") { if let viewModel { Task { await viewModel.openDemo() } } }
                Divider()
                Button("Diagnostics…") { viewModel?.showingDiagnostics = true }
            }
            .disabled(viewModel == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Group {
                Button("Web Observer…") { viewModel?.showingWebObserver = true }
                Button("Connect to Host…") { viewModel?.showingConnectHost = true }
            }
            .disabled(viewModel == nil)
        }
    }

    @ViewBuilder
    private var tabMenu: some View {
        let hasTab = viewModel?.activeTab != nil
        Button("New Tab") { viewModel?.newTab() }
            .keyboardShortcut("t")
        Button("Rename Tab…") { viewModel?.renameActiveTab() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasTab)
        Divider()
        Button("Next Tab") { viewModel?.selectAdjacentTab(1) }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(!hasTab)
        Button("Previous Tab") { viewModel?.selectAdjacentTab(-1) }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(!hasTab)
        Menu("Go to Tab") {
            ForEach(Array((viewModel?.tabs ?? []).prefix(9).enumerated()), id: \.element.id) { index, _ in
                Button("Tab \(index + 1)") { viewModel?.selectTab(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        .disabled(!hasTab)
        Divider()
        Button("Close Tab") { if let id = viewModel?.activeTabID { viewModel?.requestCloseTab(id) } }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(!hasTab)
    }

    @ViewBuilder
    private var paneMenu: some View {
        let hasPane = viewModel?.focusedPaneID != nil
        let isPopup = viewModel?.focusedPaneIsPopup ?? false
        let tab = viewModel?.activeHiveTab
        let isSplit = (tab?.paneIDs.count ?? 0) > 1
        let canSplit = (viewModel?.canSplitFocusedPane ?? false) && !isPopup

        Button("Split Right") { viewModel?.splitFocusedPane("right") }
            .keyboardShortcut("d")
            .disabled(!canSplit)
        Button("Split Down") { viewModel?.splitFocusedPane("down") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!canSplit)
        Button(tab?.zoomed == nil ? "Zoom Pane" : "Restore Layout") { viewModel?.toggleZoom() }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!isSplit || isPopup)
        Divider()
        Menu("Move Focus") {
            Button("Left") { viewModel?.moveFocus("left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Right") { viewModel?.moveFocus("right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Up") { viewModel?.moveFocus("up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Down") { viewModel?.moveFocus("down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        .disabled(!isSplit)
        Button("Swap With Next Pane") { viewModel?.swapFocusedPane(forward: true) }
            .keyboardShortcut("]", modifiers: [.command, .control])
            .disabled(!isSplit || isPopup)
        Button("Swap With Previous Pane") { viewModel?.swapFocusedPane(forward: false) }
            .keyboardShortcut("[", modifiers: [.command, .control])
            .disabled(!isSplit || isPopup)
        Button("Move to New Tab") { if let id = viewModel?.focusedPaneID { viewModel?.movePaneToNewTab(id) } }
            .disabled(!isSplit || isPopup)
        Button("Rename Pane…") { viewModel?.renameFocusedPane() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!hasPane)
        Divider()
        Button("Send to Pane…") { viewModel?.composeForPanes() }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(!hasPane || isPopup)
        Button("Send to All Panes…") { viewModel?.composeForPanes(all: true) }
            .keyboardShortcut(.return, modifiers: [.command, .option, .shift])
            .disabled(!isSplit || isPopup)
        Button("Wait for Output…") { viewModel?.watchingOutputOf = viewModel?.focusedPaneID }
            .disabled(!hasPane)
        Divider()
        Button("Open Popup Shell") { viewModel?.openPopup() }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(tab == nil)
        Button("Run in Popup…") { viewModel?.showingRunInPopup = true }
            .keyboardShortcut("p", modifiers: [.command, .option, .shift])
            .disabled(tab == nil)
        Divider()
        // ⌘W is also File → Close; the window's own ⌘W handler runs first and closes the pane.
        Button(isPopup ? "Close Popup" : "Close Pane") { viewModel?.requestCloseFocusedPane() }
            .keyboardShortcut("w")
            .disabled(viewModel?.activeTab == nil)
    }

    @ViewBuilder
    private var commandsMenu: some View {
        let commands = viewModel?.customCommands ?? []
        if commands.isEmpty {
            Text("No commands yet")
            Text("Add [[keys.command]] entries to config.toml")
        } else {
            ForEach(commands) { command in
                if let key = command.shortcutKey {
                    Button(command.menuTitle) { viewModel?.run(command) }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: [.control, .option])
                } else {
                    Button(command.menuTitle) { viewModel?.run(command) }
                }
            }
        }
    }
}

extension HiveKeyCommand {
    var menuTitle: String {
        switch type {
        case "popup": "\(title)  (popup)"
        case "pane": "\(title)  (new pane)"
        default: "\(title)  (background)"
        }
    }
}

// MARK: - Keyboard shortcuts

/// Every desktop shortcut beside the TUI key for the same action, read from the TUI's
/// effective bindings so a remapped `[keys]` shows up as remapped.
struct KeyboardShortcutsSheet: View {
    let viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tuiKeys: [String: String] = [:]
    @State private var query = ""

    private struct Shortcut: Identifiable {
        let title: String
        let desktop: String
        /// The TUI action with the same effect, as `hive config keys` names it.
        var tuiAction: String?
        var id: String { title }
    }

    private static let groups: [(String, [Shortcut])] = [
        ("Tabs", [
            Shortcut(title: "New tab", desktop: "⌘T", tuiAction: "new-tab"),
            Shortcut(title: "Rename tab", desktop: "⇧⌘R  or double-click", tuiAction: "rename-tab"),
            Shortcut(title: "Next tab", desktop: "⌃⇥  or ⌃⇧→", tuiAction: "next-tab"),
            Shortcut(title: "Previous tab", desktop: "⌃⇧⇥  or ⌃⇧←", tuiAction: "prev-tab"),
            Shortcut(title: "Go to tab 1–9", desktop: "⌘1 – ⌘9", tuiAction: "tab-1"),
            Shortcut(title: "Close tab", desktop: "⇧⌘W", tuiAction: "close-tab"),
        ]),
        ("Panes", [
            Shortcut(title: "Split right", desktop: "⌘D", tuiAction: "split-right"),
            Shortcut(title: "Split down", desktop: "⇧⌘D", tuiAction: "split-down"),
            Shortcut(title: "Move focus", desktop: "⌥⌘ ←↑→↓", tuiAction: "focus-left"),
            Shortcut(title: "Zoom pane", desktop: "⇧⌘M", tuiAction: "zoom"),
            Shortcut(title: "Swap with next pane", desktop: "⌃⌘]", tuiAction: "swap-next"),
            Shortcut(title: "Swap with previous pane", desktop: "⌃⌘[", tuiAction: "swap-prev"),
            Shortcut(title: "Swap or move by dragging", desktop: "Drag a pane's title strip"),
            Shortcut(title: "Rename pane", desktop: "⌥⌘R  or double-click its title", tuiAction: "rename-pane"),
            Shortcut(title: "Resize panes", desktop: "Drag the gap between them", tuiAction: "mode-resize"),
            Shortcut(title: "Close pane", desktop: "⌘W", tuiAction: "close-pane"),
        ]),
        ("Popups and commands", [
            Shortcut(title: "Open a popup shell", desktop: "⌥⌘P", tuiAction: "popup"),
            Shortcut(title: "Run a command in a popup", desktop: "⌥⇧⌘P"),
            Shortcut(title: "Your [[keys.command]] entries", desktop: "⌃⌥ + their key"),
            Shortcut(title: "Send to the focused pane", desktop: "⌥⌘↩"),
            Shortcut(title: "Send to every pane in the tab", desktop: "⇧⌥⌘↩"),
        ]),
        ("Finding things", [
            Shortcut(title: "Go to an agent or pane", desktop: "⌘K", tuiAction: "goto"),
            Shortcut(title: "Overview", desktop: "⇧⌘O", tuiAction: "overview"),
            Shortcut(title: "Inbox", desktop: "⇧⌘I"),
            Shortcut(title: "Find in scrollback", desktop: "⌘F", tuiAction: "mode-copy"),
            Shortcut(title: "Show or hide the sidebar", desktop: "⌃⌘S", tuiAction: "toggle-sidebar"),
        ]),
        ("Terminal", [
            Shortcut(title: "Copy / paste", desktop: "⌘C / ⌘V", tuiAction: "paste"),
            Shortcut(title: "Paste an image into an agent", desktop: "⌘V with an image copied", tuiAction: "paste-image"),
            Shortcut(title: "Open a link or path", desktop: "⌘-click"),
            Shortcut(title: "Secure keyboard entry", desktop: "⇧⌘S"),
            Shortcut(title: "Leave, agents keep running", desktop: "Close the window", tuiAction: "detach"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts").font(.title3.weight(.semibold))
                    Text("The TUI column shows your own bindings from config.toml.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Filter", text: $query)
                    .frame(width: 180)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.groups, id: \.0) { group in
                        let rows = group.1.filter(matches)
                        if !rows.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group.0.uppercased())
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 6)
                                ForEach(rows) { row in
                                    HStack {
                                        Text(row.title)
                                        Spacer()
                                        Text(row.desktop)
                                            .font(.system(.callout, design: .rounded).weight(.medium))
                                            .frame(width: 220, alignment: .trailing)
                                        Text(row.tuiAction.flatMap { tuiKeys[$0] } ?? "—")
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 90, alignment: .trailing)
                                    }
                                    .padding(.vertical, 5)
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("Desktop").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 600)
        .task { tuiKeys = await viewModel.tuiKeyBindings() }
    }

    private func matches(_ shortcut: Shortcut) -> Bool {
        query.isEmpty || shortcut.title.localizedCaseInsensitiveContains(query) || shortcut.desktop.localizedCaseInsensitiveContains(query)
    }
}

// MARK: - Run in popup

/// Asks for a command to run in a floating pane over the active tab, like `hive pane popup -- …`.
struct RunInPopupSheet: View {
    let onRun: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Run in Popup", systemImage: "macwindow.on.rectangle")
                .font(.headline)
            TextField("lazygit, htop, npm test…", text: $command)
                .focused($isFocused)
                .onSubmit(run)
            Text("Runs in your shell in the tab's environment. The popup closes when the command exits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isFocused = true }
    }

    private func run() {
        let line = command.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        onRun(line)
        dismiss()
    }
}
