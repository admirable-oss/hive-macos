import AppKit
import SwiftUI

// MARK: - Diff lines

struct DiffLine: Identifiable {
    enum Kind { case added, removed, hunk, metadata, context }
    let id: Int
    let text: String
    let kind: Kind

    init(id: Int, text: String) {
        self.id = id
        self.text = text
        if text.hasPrefix("+") && !text.hasPrefix("+++") { kind = .added }
        else if text.hasPrefix("-") && !text.hasPrefix("---") { kind = .removed }
        else if text.hasPrefix("@@") { kind = .hunk }
        else if text.hasPrefix("diff ") || text.hasPrefix("index ") || text.hasPrefix("---") || text.hasPrefix("+++") { kind = .metadata }
        else { kind = .context }
    }

    var foreground: Color {
        switch kind {
        case .added: Color(red: 0.48, green: 0.84, blue: 0.61)
        case .removed: Color(red: 0.98, green: 0.51, blue: 0.49)
        case .hunk: Color(red: 0.48, green: 0.69, blue: 0.98)
        case .metadata: .secondary
        case .context: .primary.opacity(0.84)
        }
    }

    var background: Color {
        switch kind {
        case .added: Color.green.opacity(0.10)
        case .removed: Color.red.opacity(0.10)
        case .hunk: Color.blue.opacity(0.08)
        case .metadata, .context: .clear
        }
    }
}

// MARK: - Change row

struct ChangeRow: View {
    let change: GitChange

    var body: some View {
        HStack(spacing: 8) {
            ChangeStatusBadge(change: change)
            Text(change.fileName)
                .font(.system(size: 12.5))
                .strikethrough(change.code == "D", color: .secondary)
                .lineLimit(1)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .tag(change.id)
        .help(change.path)
    }
}

/// A change's status letter in a tinted tile: M, A, D, U and so on.
struct ChangeStatusBadge: View {
    let change: GitChange

    var body: some View {
        Text(change.label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(change.color)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(change.color.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(change.color.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Change list

/// Staged and unstaged files, with stage/unstage on the selection's context menu.
struct ChangeListView: View {
    let changes: [GitChange]
    @Binding var selection: Set<GitChange.ID>
    var isBusy = false
    let onStage: ([GitChange]) -> Void
    let onUnstage: ([GitChange]) -> Void
    let onOpen: (GitChange.ID) -> Void
    let onReveal: (GitChange.ID) -> Void

    private var staged: [GitChange] { changes.filter { $0.area == .staged } }
    private var unstaged: [GitChange] { changes.filter { $0.area == .unstaged } }

    var body: some View {
        List(selection: $selection) {
            if !staged.isEmpty {
                Section {
                    ForEach(staged) { ChangeRow(change: $0) }
                } header: {
                    HiveSectionTitle(title: "Staged", count: staged.count)
                }
            }
            if !unstaged.isEmpty {
                Section {
                    ForEach(unstaged) { ChangeRow(change: $0) }
                } header: {
                    HiveSectionTitle(title: "Changes", count: unstaged.count)
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: changes.map(\.id))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: GitChange.ID.self) { ids in
            let stageable = unstaged.filter { ids.contains($0.id) }
            let unstageable = staged.filter { ids.contains($0.id) }
            if !stageable.isEmpty {
                Button(stageable.count == 1 ? "Stage File" : "Stage \(stageable.count) Files") { onStage(stageable) }
                    .disabled(isBusy)
            }
            if !unstageable.isEmpty {
                Button(unstageable.count == 1 ? "Unstage File" : "Unstage \(unstageable.count) Files") { onUnstage(unstageable) }
                    .disabled(isBusy)
            }
            if !ids.isEmpty {
                Divider()
                Button("Open") { ids.forEach(onOpen) }
                Button("Reveal in Finder") { ids.forEach(onReveal) }
            }
        } primaryAction: { ids in
            ids.forEach(onOpen)
        }
    }
}

// MARK: - Diff pane

/// A unified diff, split into files and hunks. When `onApplyHunks` is set and
/// `area` names a direction, each hunk header carries a stage or unstage button.
struct DiffPaneView: View {
    let diffText: String
    let error: String?
    /// The area the diff is read from; decides whether a hunk is staged or unstaged.
    let area: GitChangeArea?
    var isBusy = false
    var placeholder = "Select a Changed File"
    var placeholderDescription = "Its Git diff appears here."
    /// The repository's root; with it, lines and hunks open in the user's editor.
    var root: String?
    var onApplyHunks: (FileDiff, DiffHunk) -> Void = { _, _ in }

    private var files: [FileDiff] { FileDiff.parse(diffText) }

    var body: some View {
        if let error {
            ContentUnavailableView("Can’t Read Diff", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if diffText.isEmpty {
            ContentUnavailableView(placeholder, systemImage: "doc.text.magnifyingglass", description: Text(placeholderDescription))
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { file in
                        fileBlock(file)
                    }
                }
                .frame(minWidth: 0, alignment: .leading)
                .padding(.vertical, 6)
            }
        }
    }

    private func fileBlock(_ file: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(file.preamble.enumerated()), id: \.offset) { index, line in
                row(DiffLine(id: index, text: line))
            }
            ForEach(file.hunks) { hunk in
                hunkBlock(file: file, hunk: hunk)
            }
        }
        .padding(.bottom, 4)
    }

    private func hunkBlock(file: FileDiff, hunk: DiffHunk) -> some View {
        let header = DiffLine(id: 0, text: hunk.header)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let area, !isBusy {
                    Button {
                        onApplyHunks(file, hunk)
                    } label: {
                        Label(area == .unstaged ? "Stage Hunk" : "Unstage Hunk", systemImage: area == .unstaged ? "plus" : "minus")
                            .font(.system(size: 10, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.hiveAmber)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.hiveAmber.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help(area == .unstaged
                          ? "Stage this hunk only"
                          : "Move this hunk back out of the index")
                }
                Text(header.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(header.foreground)
                    .textSelection(.enabled)
                if let url = fileURL(file), let start = hunk.newStart {
                    Button {
                        Editor.preferred.open(url, line: start)
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open in \(Editor.preferred.name) at line \(start)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(header.background)

            let numbers = hunk.newLineNumbers
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                row(DiffLine(id: index, text: line))
                    .contextMenu {
                        if let url = fileURL(file) {
                            OpenInEditorMenu(url: url, line: numbers[index])
                        }
                    }
            }
        }
    }

    private func fileURL(_ file: FileDiff) -> URL? {
        guard let root, let path = file.path, path != "/dev/null" else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(path)
    }

    private func row(_ line: DiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(line.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(line.background)
            .textSelection(.enabled)
    }
}

// MARK: - Commit

/// The explicit review step before a commit: what is staged, the diff it will
/// record, the message, and the environment and branch it lands on.
struct CommitSheet: View {
    let environmentName: String
    let path: String
    let branch: String?
    let root: String
    let client: GitClient
    let onCommitted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var staged: [GitChange] = []
    @State private var diff = ""
    @State private var loadError: String?
    @State private var commitError: String?
    @State private var isCommitting = false

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCommit: Bool { !staged.isEmpty && !trimmedMessage.isEmpty && !isCommitting }

    var body: some View {
        VStack(spacing: 0) {
            ReviewContextHeader(environment: environmentName, path: path, branch: branch, symbol: "checkmark.circle") { EmptyView() }

            VSplitView {
                List {
                    Section {
                        ForEach(staged) { ChangeRow(change: $0) }
                    } header: {
                        HiveSectionTitle(title: "Staged", symbol: "tray.full", count: staged.count)
                    }
                }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80, idealHeight: 130)

                DiffPaneView(
                    diffText: diff,
                    error: loadError,
                    area: nil,
                    placeholder: "Nothing Staged",
                    placeholderDescription: "Stage changes before committing.",
                    root: root
                )
                .frame(minHeight: 220)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Commit message", text: $message, axis: .vertical)
                    .textFieldStyle(.hive)
                    .lineLimit(2...5)
                if let commitError {
                    HiveNotice(text: commitError)
                }
                HStack(spacing: 8) {
                    Text(staged.isEmpty
                         ? "Nothing staged"
                         : "\(staged.count) file\(staged.count == 1 ? "" : "s") staged")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isCommitting { ProgressView().controlSize(.small) }
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.hive)
                        .keyboardShortcut(.cancelAction)
                    Button { Task { await commit() } } label: { Label("Commit", systemImage: "checkmark") }
                        .buttonStyle(.hivePrimary)
                        .disabled(!canCommit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .top) { Divider().opacity(0.5) }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: commitError)
        }
        .frame(minWidth: 620, minHeight: 580)
        .task { await load() }
    }

    private func load() async {
        do {
            staged = try await client.status(root: root).filter { $0.area == .staged }
            diff = try await client.stagedDiff(root: root)
            loadError = nil
        } catch {
            staged = []
            diff = ""
            loadError = error.localizedDescription
        }
    }

    private func commit() async {
        isCommitting = true
        commitError = nil
        defer { isCommitting = false }
        do {
            _ = try await client.commit(root: root, message: trimmedMessage)
            onCommitted()
            dismiss()
        } catch {
            commitError = error.localizedDescription
        }
    }
}

// MARK: - Context header

/// Names the environment and branch every action in this window affects.
struct ReviewContextHeader<Trailing: View>: View {
    let environment: String
    let path: String
    let branch: String?
    var detail: String?
    var symbol = "arrow.triangle.branch"
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            HiveBadgeIcon(symbol: symbol, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(environment)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HiveChip(text: branch ?? "Detached HEAD", tint: .hiveAmber, symbol: "arrow.triangle.branch")
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            trailing
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

// MARK: - Review cockpit

/// Everything one worktree's review needs in one window: the agent's summary,
/// its task report and test output, the changed files, the diff, and the commit.
struct ReviewCockpitView: View {
    let environment: HiveEnvironment
    @ObservedObject var viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var root: String?
    @State private var branch: String?
    @State private var changes: [GitChange] = []
    @State private var selection: Set<GitChange.ID> = []
    @State private var diffText = ""
    @State private var diffError: String?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isBusy = false
    @State private var reloadToken = UUID()
    @State private var showingCommit = false

    @State private var agent: HiveAgent?
    @State private var explanation: HiveAgentExplanation?
    @State private var reportTask: HiveTask?

    private var client: GitClient { GitClient(directory: environment.path) }
    private var staged: [GitChange] { changes.filter { $0.area == .staged } }
    private var selectedChange: GitChange? { changes.first { selection.contains($0.id) } }
    private var environmentName: String { environment.name.isEmpty ? environment.id : environment.name }

    var body: some View {
        VStack(spacing: 0) {
            ReviewContextHeader(
                environment: environmentName,
                path: environment.path,
                branch: branch,
                detail: environment.worktree.map { "worktree · \($0.branch)" }
            ) {
                HiveCloseButton { dismiss() }
                    .padding(.leading, 6)
            }

            if let loadError {
                ContentUnavailableView(
                    "Can’t Read Changes",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }

            commitBar
                .background(Color.primary.opacity(0.025))
                .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(minWidth: 940, minHeight: 640)
        .task(id: reloadToken) { await refresh() }
        .task(id: selection.first) { await loadDiff() }
        .task { await loadContext() }
        .sheet(isPresented: $showingCommit) {
            if let root {
                CommitSheet(
                    environmentName: environmentName,
                    path: environment.path,
                    branch: branch,
                    root: root,
                    client: client
                ) {
                    reloadToken = UUID()
                    Task { await loadContext() }
                }
            }
        }
    }

    private var content: some View {
        HSplitView {
            ChangeListView(
                changes: changes,
                selection: $selection,
                isBusy: isBusy,
                onStage: stage,
                onUnstage: unstage,
                onOpen: { open($0) },
                onReveal: { reveal($0) }
            )
            .frame(minWidth: 240, idealWidth: 300)

            VSplitView {
                DiffPaneView(
                    diffText: diffText,
                    error: diffError,
                    area: selectedChange?.area,
                    isBusy: isBusy,
                    placeholder: "Select a Changed File",
                    root: root ?? environment.path,
                    onApplyHunks: applyHunks
                )
                .frame(minHeight: 240)

                contextPanel
                    .frame(minHeight: 170, idealHeight: 220)
            }
        }
    }

    private var commitBar: some View {
        HStack(spacing: 10) {
            if let actionError {
                HiveNotice(text: actionError)
                    .frame(maxWidth: 420)
            } else {
                Text(staged.isEmpty ? "Nothing staged" : "\(staged.count) staged · \(changes.count) changed")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            Button { stageAll() } label: { Label("Stage All", systemImage: "plus") }
                .buttonStyle(.hive)
                .disabled(changes.isEmpty || isBusy)
            Button { unstageAll() } label: { Label("Unstage All", systemImage: "minus") }
                .buttonStyle(.hive)
                .disabled(staged.isEmpty || isBusy)
            Button { showingCommit = true } label: { Label("Commit…", systemImage: "checkmark") }
                .buttonStyle(.hivePrimary)
                .disabled(staged.isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: staged.count)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: actionError)
    }

    // MARK: Context

    private var contextPanel: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                agentSummary.hiveCard(padding: 12)
                taskReport.hiveCard(padding: 12)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HiveSectionTitle(title: "Agent", symbol: "sparkles")
            if let agent {
                HStack(spacing: 7) {
                    AgentProviderIcon(kind: agent.kind, size: 12)
                    Text(agent.name.isEmpty ? agent.kind : agent.name).font(.system(size: 12.5, weight: .semibold))
                    HiveChip(text: agentStateTitle(agent.state), tint: agent.state == "working" || agent.state == "blocked" ? agentStateColor(agent.state) : nil)
                }
                if let reason = agent.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let verdict = explanation?.verdict {
                    Text(verdict.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Rule \(verdict.rule) of the \(explanation?.manifest ?? agent.kind) manifest matched.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No agent is working in this environment.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var taskReport: some View {
        VStack(alignment: .leading, spacing: 6) {
            HiveSectionTitle(title: "Task report", symbol: "checklist")
            if let task = reportTask {
                Text(task.spec.title ?? task.spec.id)
                    .font(.system(size: 12, weight: .medium))
                Text(task.result?.summary ?? task.reason ?? task.result?.outcome ?? "No report yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let changed = task.result?.changed, !changed.isEmpty {
                    HiveSectionTitle(title: "Changed files", count: changed.count)
                        .padding(.top, 2)
                    ForEach(changed, id: \.self) { path in
                        Button { selectPath(path) } label: {
                            Label(path, systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.hiveAmber)
                        .help("Show this file's diff")
                    }
                }
                if let screen = task.result?.screen, !screen.isEmpty {
                    HiveSectionTitle(title: "Test output", symbol: "terminal")
                        .padding(.top, 2)
                    Text(screen.suffix(16).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No task has reported in this environment.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Loading

    private func refresh() async {
        await load()
        await loadDiff()
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let root = try await client.root()
            self.root = root
            branch = await client.branch(root: root)
            changes = try await client.status(root: root)
            selection.formIntersection(Set(changes.map(\.id)))
            if selection.isEmpty, let first = changes.first { selection = [first.id] }
            loadError = nil
        } catch {
            root = nil
            branch = nil
            changes = []
            selection = []
            diffText = ""
            diffError = nil
            loadError = error.localizedDescription
        }
    }

    private func loadDiff() async {
        guard let root, let change = selectedChange else {
            diffText = ""
            diffError = nil
            return
        }
        let id = change.id
        do {
            let text = try await client.diff(root: root, change: change)
            guard selection.first == id else { return }
            diffText = text
            diffError = nil
        } catch {
            guard selection.first == id else { return }
            diffText = ""
            diffError = error.localizedDescription
        }
    }

    private func loadContext() async {
        agent = viewModel.agents
            .filter { $0.environmentID == environment.id && $0.isCodingAgent }
            .sorted { $0.stateRank < $1.stateRank }
            .first
        if let agent {
            explanation = try? await viewModel.workspace.explain(agent: agent.id)
        } else {
            explanation = nil
        }
        reportTask = await latestTask()
    }

    private func latestTask() async -> HiveTask? {
        guard let summaries = try? await viewModel.workspace.taskSummaries() else { return nil }
        var found: HiveTask?
        for summary in summaries {
            guard let plan = try? await viewModel.workspace.taskPlan(summary.id) else { continue }
            for task in plan.tasks where (task.environmentID ?? task.spec.environmentID) == environment.id {
                if task.result != nil { found = task }
            }
        }
        return found
    }

    // MARK: Actions

    private func stage(_ list: [GitChange]) {
        mutate { try await client.stage(root: $0, paths: list.map(\.path)) }
    }

    private func unstage(_ list: [GitChange]) {
        mutate { try await client.unstage(root: $0, paths: list.map(\.path)) }
    }

    private func stageAll() {
        mutate { try await client.stageAll(root: $0) }
    }

    private func unstageAll() {
        mutate { try await client.unstageAll(root: $0) }
    }

    private func applyHunks(file: FileDiff, hunk: DiffHunk) {
        guard let area = selectedChange?.area else { return }
        let patch = file.patch(selecting: [hunk])
        mutate { try await client.applyToIndex(root: $0, patch: patch, reverse: area == .staged) }
    }

    private func mutate(_ operation: @escaping (String) async throws -> Void) {
        guard let root, !isBusy else { return }
        Task {
            isBusy = true
            do {
                try await operation(root)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            isBusy = false
            await refresh()
        }
    }

    private func selectPath(_ path: String) {
        guard let change = changes.first(where: { $0.path == path || $0.path.hasSuffix("/" + path) }) else { return }
        selection = [change.id]
    }

    private func open(_ id: GitChange.ID) {
        guard let change = changes.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(fileURL(for: change))
    }

    private func reveal(_ id: GitChange.ID) {
        guard let change = changes.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: change)])
    }

    private func fileURL(for change: GitChange) -> URL {
        URL(fileURLWithPath: root ?? environment.path).appendingPathComponent(change.path)
    }
}
