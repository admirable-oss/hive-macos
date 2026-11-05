import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// M7 · Saved workspace views. Pick what the sidebar shows, how it groups, how dense it is and
/// which inspector opens, then save that as a named view. Built-ins (terminal, overview, status
/// board) are always available; user views sit alongside them. Everything is declarative data —
/// there is no view script anywhere in this flow.
struct WorkspaceViewsView: View {
    @ObservedObject var commandCenter: CommandCenterStore
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var draft: WorkspaceView?
    @State private var showingAgentEditor = false
    @State private var showingRecipes = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                viewList.frame(width: 232)
                Divider()
                editor
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            if selectedID == nil { select(commandCenter.activeView ?? commandCenter.views.first) }
        }
    }

    private var header: some View {
        HiveSheetHeader(
            symbol: "rectangle.3.group.bubble.left",
            title: "Workspace views",
            subtitle: "Save how the workspace looks, then switch between views.",
            onClose: { dismiss() }
        ) {
            if let statusMessage {
                HiveChip(text: statusMessage, tint: .hiveAmber, symbol: "checkmark")
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .id(statusMessage)
            }
            Button { showingRecipes = true } label: { Label("Recipes…", systemImage: "shippingbox") }
                .buttonStyle(.hive)
            Button { duplicateCurrent() } label: { Label("New View", systemImage: "plus") }
                .buttonStyle(.hivePrimary)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: statusMessage)
    }

    private var viewList: some View {
        List(selection: $selectedID) {
            Section("Built-in") {
                ForEach(commandCenter.views.filter(\.builtIn)) { view in
                    row(view)
                }
            }
            if !commandCenter.customViews.isEmpty {
                Section("My views") {
                    ForEach(commandCenter.customViews) { view in
                        row(view)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.primary.opacity(0.02))
        .onChange(of: selectedID) { _, id in
            select(commandCenter.views.first { $0.id == id })
        }
    }

    private func row(_ view: WorkspaceView) -> some View {
        HStack(spacing: 7) {
            Image(systemName: view.settings.kind.symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.hiveAmber)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.hiveAmber.opacity(0.13)))
            Text(view.name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 2)
            if commandCenter.activeViewID == view.id {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color.hiveAmber)
            }
        }
        .tag(view.id)
    }

    @ViewBuilder
    private var editor: some View {
        if let binding = draftBinding {
            editorForm(binding)
        } else {
            ContentUnavailableView("No view selected", systemImage: "rectangle.3.group", description: Text("Pick a view on the left, or create a new one."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorForm(_ view: Binding<WorkspaceView>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HiveSectionTitle(title: "Name", symbol: "textformat")
                    TextField("View name", text: view.name)
                        .textFieldStyle(.hive)
                        .disabled(view.wrappedValue.builtIn)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HiveSectionTitle(title: "Opens onto", symbol: "rectangle.portrait.on.rectangle.portrait")
                    HiveSegmentedPicker(
                        selection: view.settings.kind,
                        options: WorkspaceViewKind.allCases,
                        title: { $0.title },
                        symbol: { $0.symbol }
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HiveSectionTitle(title: "Sidebar", symbol: "sidebar.left")
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Environments", isOn: view.settings.showsEnvironments)
                        Toggle("Agents", isOn: view.settings.showsAgents)
                        Toggle("Machines", isOn: view.settings.showsMachines)
                        Toggle("Group worktrees under their repository", isOn: view.settings.groupsWorktrees)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12.5))
                    .hiveCard(padding: 12)
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HiveSectionTitle(title: "Density", symbol: "line.3.horizontal")
                        HiveSegmentedPicker(
                            selection: view.settings.density,
                            options: WorkspaceDensity.allCases,
                            title: { $0.title }
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HiveSectionTitle(title: "Inspector", symbol: "sidebar.right")
                        Toggle("Show inspector by default", isOn: view.settings.showsInspector)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 12.5))
                        Picker("Panel", selection: inspectorBinding(view)) {
                            Text("None").tag("")
                            ForEach(InspectorPanel.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .disabled(!view.wrappedValue.settings.showsInspector)
                    }
                }

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Button {
                        commandCenter.save(view.wrappedValue)
                        commandCenter.apply(commandCenter.views.first { $0.id == view.wrappedValue.id } ?? view.wrappedValue)
                        statusMessage = "Applied “\(view.wrappedValue.name)”."
                    } label: { Label("Apply", systemImage: "checkmark.circle") }
                        .buttonStyle(.hivePrimary)

                    Button("Save") {
                        commandCenter.save(view.wrappedValue)
                        statusMessage = "Saved."
                    }
                    .buttonStyle(.hive)

                    Button("Revert") { select(commandCenter.views.first { $0.id == view.wrappedValue.id }) }
                        .buttonStyle(.hive)

                    Button { showingAgentEditor = true } label: { Label("Edit with agent…", systemImage: "wand.and.stars") }
                        .buttonStyle(.hive)

                    Spacer()

                    if view.wrappedValue.builtIn {
                        Button("Restore Defaults") {
                            commandCenter.resetToDefault(view.wrappedValue.id)
                            select(commandCenter.views.first { $0.id == view.wrappedValue.id })
                            statusMessage = "Restored built-in defaults."
                        }
                        .buttonStyle(.hive)
                    } else {
                        Button("Delete", role: .destructive) {
                            commandCenter.delete(view.wrappedValue.id)
                            select(commandCenter.views.first { !$0.builtIn } ?? commandCenter.views.first)
                            statusMessage = "Deleted."
                        }
                        .buttonStyle(.hive)
                    }
                }

                HiveNotice(
                    text: "A view is plain configuration: which sections show, how they group, row density and the inspector default. It never runs a script.",
                    kind: .info
                )
            }
            .padding(20)
        }
        .sheet(isPresented: $showingAgentEditor) {
            ViewEditAgentSheet(viewModel: viewModel, base: view.wrappedValue) { settings in
                var updated = view.wrappedValue
                updated.settings = settings
                draft = updated
                commandCenter.save(updated)
                statusMessage = "Applied the agent's suggestion. Save to keep it."
            }
        }
        .sheet(isPresented: $showingRecipes) {
            RecipesSheet(commandCenter: commandCenter)
        }
    }

    private func inspectorBinding(_ view: Binding<WorkspaceView>) -> Binding<String> {
        Binding(
            get: { view.wrappedValue.settings.inspector ?? "" },
            set: { view.wrappedValue.settings.inspector = $0.isEmpty ? nil : $0 }
        )
    }

    private var draftBinding: Binding<WorkspaceView>? {
        guard draft != nil else { return nil }
        return Binding(get: { self.draft ?? WorkspaceView(name: "", settings: WorkspaceViewSettings()) }, set: { self.draft = $0 })
    }

    private func select(_ view: WorkspaceView?) {
        selectedID = view?.id
        draft = view
        statusMessage = nil
    }

    private func duplicateCurrent() {
        let base = draft ?? WorkspaceView(name: "New view", settings: WorkspaceViewSettings())
        var copy = base
        copy.id = UUID().uuidString
        copy.name = uniqueName(from: base.name)
        copy.builtIn = false
        commandCenter.save(copy)
        select(copy)
        statusMessage = "Created “\(copy.name)”."
    }

    private func uniqueName(from name: String) -> String {
        let existing = Set(commandCenter.views.map { $0.name.lowercased() })
        if !existing.contains("\(name) copy") { return "\(name) copy" }
        var index = 2
        while existing.contains("\(name) copy \(index)") { index += 1 }
        return "\(name) copy \(index)"
    }
}

// MARK: - Agent-directed view editing

/// Ask a running agent to adjust a saved view. The agent's answer is parsed as declarative
/// configuration and shown as a before/after comparison; nothing is applied until the user
/// confirms, and the same config can be edited by hand.
struct ViewEditAgentSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let base: WorkspaceView
    let onApply: (WorkspaceViewSettings) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .agent
    @State private var instruction = ""
    @State private var selectedAgentID = ""
    @State private var proposed: WorkspaceViewSettings?
    @State private var manualJSON = ""
    @State private var status: String?
    @State private var isWorking = false

    enum Mode: String, CaseIterable, Identifiable {
        case agent, manual
        var id: String { rawValue }
        var title: String { self == .agent ? "Ask an agent" : "Edit configuration" }
    }

    private var runningAgents: [HiveAgent] { viewModel.agents.filter { $0.state != "exited" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        HiveSheetHeader(
            symbol: "wand.and.stars",
            title: "Adjust “\(base.name)”",
            subtitle: "Describe the change, or edit the declarative configuration directly. The result is previewed before it is applied."
        )
        VStack(alignment: .leading, spacing: 14) {
            HiveSegmentedPicker(
                selection: $mode.animation(.spring(response: 0.3, dampingFraction: 0.85)),
                options: Mode.allCases,
                title: { $0.title },
                symbol: { $0 == .agent ? "sparkles" : "curlybraces" }
            )

            if mode == .agent {
                HStack {
                    Picker("Agent", selection: $selectedAgentID) {
                        Text("Choose an agent").tag("")
                        ForEach(runningAgents) { agent in
                            Text(agent.name.isEmpty ? agent.kind : agent.name).tag(agent.id)
                        }
                    }
                    .frame(maxWidth: 260)
                    Spacer()
                }
                TextField("e.g. “Compact rows, hide machines, open the Changes inspector”", text: $instruction)
                    .textFieldStyle(.hive)
                Button { Task { await askAgent() } } label: {
                    Label("Ask agent", systemImage: "paperplane")
                }
                .buttonStyle(.hivePrimaryCompact)
                .disabled(selectedAgentID.isEmpty || instruction.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                if runningAgents.isEmpty {
                    HiveNotice(text: "No running agents. Start one, or edit the configuration by hand.", kind: .info)
                }
            } else {
                HiveSectionTitle(title: "Configuration", symbol: "curlybraces")
                TextEditor(text: $manualJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                Button { parseManual() } label: { Label("Preview configuration", systemImage: "eye") }
                    .buttonStyle(.hiveCompact)
            }

            if isWorking { ProgressView().controlSize(.small) }

            if let proposed {
                HiveSectionTitle(title: "Preview", symbol: "eye")
                previewTable(proposed)
                    .hiveCard(padding: 12, tint: .hiveAmber)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }

            if let status {
                HiveNotice(text: status, kind: .info)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: proposed)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: status)

            HStack(spacing: 8) {
                if proposed != nil {
                    Button("Undo preview") { proposed = nil; status = nil }
                        .buttonStyle(.hive)
                }
                Button("Restore defaults") {
                    if let original = CommandCenterStore.builtInViews.first(where: { $0.id == base.id })?.settings {
                        proposed = original
                        status = "Previewing the built-in defaults."
                    } else {
                        proposed = WorkspaceViewSettings()
                        status = "Previewing the default configuration."
                    }
                }
                .buttonStyle(.hive)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.hive)
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let proposed { onApply(proposed) }
                    dismiss()
                } label: { Label("Apply", systemImage: "checkmark") }
                .buttonStyle(.hivePrimary)
                .disabled(proposed == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 640, height: 600)
        .onAppear {
            manualJSON = Self.encode(base.settings)
            selectedAgentID = runningAgents.first?.id ?? ""
        }
    }

    private func previewTable(_ proposed: WorkspaceViewSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(diff(base.settings, proposed), id: \.label) { change in
                HStack(spacing: 8) {
                    Text(change.label).font(.system(size: 11.5, weight: .medium)).frame(width: 130, alignment: .leading)
                    Text(change.before).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(change.after).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.hiveAmber)
                }
            }
            if diff(base.settings, proposed).isEmpty {
                Text("No changes from the current settings.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func askAgent() async {
        guard let agent = viewModel.agents.first(where: { $0.id == selectedAgentID }) else { return }
        isWorking = true
        defer { isWorking = false }
        let prompt = """
        You are adjusting a Hive Desktop workspace view. Reply with ONLY a JSON object and no other text.
        Schema: {"kind":"terminal"|"overview"|"statusBoard","showsEnvironments":bool,"showsAgents":bool,"showsMachines":bool,"groupsWorktrees":bool,"density":"comfortable"|"compact","inspector":"files"|"changes"|"agent"|null,"showsInspector":bool}
        Current settings: \(Self.encode(base.settings))
        Request: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        do {
            let result = try await viewModel.workspace.prompt(agent: agent.id, text: prompt, wait: true)
            guard let json = Self.extractJSON(from: (result.output ?? []).joined(separator: "\n")),
                  let settings = Self.decode(json) else {
                status = "The agent's reply didn't contain usable configuration. Try rephrasing, or edit the configuration by hand."
                return
            }
            proposed = settings
            status = "Parsed the agent's suggestion."
        } catch {
            status = error.localizedDescription
        }
    }

    private func parseManual() {
        guard let settings = Self.decode(manualJSON) else {
            status = "That configuration couldn't be parsed. Check the JSON and try again."
            return
        }
        proposed = settings
        status = nil
    }

    // MARK: Diff

    private struct Change { let label: String; let before: String; let after: String }

    private func diff(_ a: WorkspaceViewSettings, _ b: WorkspaceViewSettings) -> [Change] {
        var changes: [Change] = []
        func compare(_ label: String, _ x: String, _ y: String) {
            if x != y { changes.append(Change(label: label, before: x, after: y)) }
        }
        compare("Opens onto", a.kind.title, b.kind.title)
        compare("Environments", onOff(a.showsEnvironments), onOff(b.showsEnvironments))
        compare("Agents", onOff(a.showsAgents), onOff(b.showsAgents))
        compare("Machines", onOff(a.showsMachines), onOff(b.showsMachines))
        compare("Group worktrees", onOff(a.groupsWorktrees), onOff(b.groupsWorktrees))
        compare("Density", a.density.title, b.density.title)
        compare("Inspector", a.inspector ?? "None", b.inspector ?? "None")
        compare("Show inspector", onOff(a.showsInspector), onOff(b.showsInspector))
        return changes
    }

    private func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    static func encode(_ settings: WorkspaceViewSettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) -> WorkspaceViewSettings? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkspaceViewSettings.self, from: data)
    }

    static func extractJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }
}

// MARK: - Recipes

/// M7 · Shareable workspace recipes. Export and import versioned declarative views with a preview
/// and a compatibility check. Recipes describe views; they never carry executable content.
struct RecipesSheet: View {
    @ObservedObject var commandCenter: CommandCenterStore

    @Environment(\.dismiss) private var dismiss
    @State private var pendingImport: WorkspaceRecipe?
    @State private var showingImporter = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(
                symbol: "shippingbox",
                title: "Workspace recipes",
                subtitle: "Versioned sets of saved views you can preview, export and import.",
                onClose: { dismiss() }
            ) {
                Button("Export My Views…") { exportCurrentViews() }
                    .buttonStyle(.hive)
                Button { showingImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.hivePrimary)
            }

            if commandCenter.recipes.isEmpty {
                ContentUnavailableView("No recipes", systemImage: "shippingbox", description: Text("Import a recipe file to add its views."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                  VStack(spacing: 8) {
                    ForEach(commandCenter.recipes) { recipe in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.hiveAmber)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hiveAmber.opacity(0.13)))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(recipe.name).font(.system(size: 12.5, weight: .semibold))
                                    if recipe.builtIn {
                                        HiveChip(text: "First-party", tint: .hiveAmber)
                                    }
                                    if !recipe.compatible {
                                        HiveChip(text: "Needs newer app", tint: .red)
                                    }
                                }
                                Text("\(recipe.views.count) view\(recipe.views.count == 1 ? "" : "s") · format v\(recipe.formatVersion)")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(recipe.views.map(\.name).joined(separator: ", "))
                                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button("Export…") { export(recipe) }
                                .buttonStyle(.hiveCompact)
                            if !recipe.builtIn {
                                Button("Delete", role: .destructive) { commandCenter.deleteRecipe(recipe.id) }
                                    .buttonStyle(.hiveCompact)
                            }
                        }
                        .hiveCard(padding: 12, interactive: true)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                    }
                  }
                  .padding(16)
                  .animation(.spring(response: 0.32, dampingFraction: 0.85), value: commandCenter.recipes.map(\.id))
                }
            }

            if let message {
                HiveNotice(text: message, kind: .info).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(width: 620, height: 460)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { loadRecipe(url) }
        }
        .sheet(isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
            if let pendingImport { importPreview(pendingImport) }
        }
    }

    private func importPreview(_ recipe: WorkspaceRecipe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
        HiveSheetHeader(symbol: "shippingbox", title: "Preview “\(recipe.name)”", subtitle: recipe.author.map { "by \($0)" })
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                HiveChip(text: "Format v\(recipe.formatVersion)", symbol: "doc.badge.gearshape")
                if recipe.compatible {
                    HiveChip(text: "Compatible", tint: .green, symbol: "checkmark.seal.fill")
                } else {
                    HiveChip(text: "Needs a newer version of Hive Desktop", tint: .red, symbol: "exclamationmark.triangle.fill")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recipe.views) { view in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(view.name, systemImage: view.settings.kind.symbol).font(.system(size: 12.5, weight: .semibold))
                            Text(summary(view.settings)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .hiveCard(padding: 10)
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Text("Importing adds these views to “My views”.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { pendingImport = nil }
                    .buttonStyle(.hive)
                    .keyboardShortcut(.cancelAction)
                Button {
                    let result = commandCenter.importRecipe(recipe)
                    message = result.message
                    pendingImport = nil
                } label: { Label("Add Views", systemImage: "plus") }
                .buttonStyle(.hivePrimary)
                .disabled(!recipe.compatible)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        }
        .frame(width: 560, height: 480)
    }

    private func summary(_ settings: WorkspaceViewSettings) -> String {
        var parts: [String] = ["Opens \(settings.kind.title)", settings.density.title]
        var sections: [String] = []
        if settings.showsEnvironments { sections.append("environments") }
        if settings.showsAgents { sections.append("agents") }
        if settings.showsMachines { sections.append("machines") }
        parts.append("shows " + (sections.isEmpty ? "no sections" : sections.joined(separator: ", ")))
        parts.append(settings.showsInspector ? "inspector: \(settings.inspector ?? "none")" : "no inspector")
        return parts.joined(separator: " · ")
    }

    private func loadRecipe(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let recipe = try JSONDecoder().decode(WorkspaceRecipe.self, from: data)
            pendingImport = recipe
            message = nil
        } catch {
            message = "That file couldn't be read as a workspace recipe."
        }
    }

    private func export(_ recipe: WorkspaceRecipe) {
        write(recipe, suggestedName: recipe.name)
    }

    private func exportCurrentViews() {
        let views = commandCenter.customViews.isEmpty ? commandCenter.views : commandCenter.customViews
        let recipe = WorkspaceRecipe(name: "My workspace views", views: views)
        write(recipe, suggestedName: "my-workspace-views")
    }

    private func write(_ recipe: WorkspaceRecipe, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).hiveview.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipe).write(to: url, options: .atomic)
            message = "Exported “\(recipe.name)”."
        } catch {
            message = error.localizedDescription
        }
    }
}
