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
        HStack(spacing: 6) {
            Text(change.fileName)
                .lineLimit(1)
            if !change.directory.isEmpty {
                Text(change.directory)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(change.label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(change.color)
        }
        .tag(change.id)
        .help(change.path)
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
                Section("Staged") {
                    ForEach(staged) { ChangeRow(change: $0) }
                }
            }
            if !unstaged.isEmpty {
                Section("Changes") {
                    ForEach(unstaged) { ChangeRow(change: $0) }
                }
            }
        }
        .listStyle(.sidebar)
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
                    Button(area == .unstaged ? "Stage Hunk" : "Unstage Hunk") {
                        onApplyHunks(file, hunk)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.hiveAmber)
                    .help(area == .unstaged
                          ? "Stage this hunk only"
                          : "Move this hunk back out of the index")
                }
                Text(header.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(header.foreground)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(header.background)

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { index, line in
                row(DiffLine(id: index, text: line))
            }
        }
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
            ReviewContextHeader(environment: environmentName, path: path, branch: branch) { EmptyView() }
            Divider()

            VSplitView {
                List(staged) { ChangeRow(change: $0) }
                    .listStyle(.inset)
                    .frame(minHeight: 80, idealHeight: 130)

                DiffPaneView(
                    diffText: diff,
                    error: loadError,
                    area: nil,
                    placeholder: "Nothing Staged",
                    placeholderDescription: "Stage changes before committing."
                )
                .frame(minHeight: 220)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextField("Commit message", text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                if let commitError {
                    Label(commitError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                HStack {
                    Text(staged.isEmpty
                         ? "Nothing staged"
                         : "\(staged.count) file\(staged.count == 1 ? "" : "s") staged")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Commit") { Task { await commit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCommit)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
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
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.hiveAmber)
            VStack(alignment: .leading, spacing: 1) {
                Text(environment)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Label(branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding(.leading, 6)
            }
            Divider()

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

            Divider()
            commitBar
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
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(staged.isEmpty ? "Nothing staged" : "\(staged.count) staged · \(changes.count) changed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Stage All") { stageAll() }
                .disabled(changes.isEmpty || isBusy)
            Button("Unstage All") { unstageAll() }
                .disabled(staged.isEmpty || isBusy)
            Button("Commit…") { showingCommit = true }
                .buttonStyle(.borderedProminent)
                .disabled(staged.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    // MARK: Context

    private var contextPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                agentSummary
                taskReport
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var agentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent")
                .font(.system(size: 12, weight: .semibold))
            if let agent {
                HStack(spacing: 7) {
                    Circle().fill(agentStateColor(agent.state)).frame(width: 8, height: 8)
                    Text(agent.name.isEmpty ? agent.kind : agent.name).font(.system(size: 12, weight: .medium))
                    Text(agentStateTitle(agent.state))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
            Text("Task report")
                .font(.system(size: 12, weight: .semibold))
            if let task = reportTask {
                Text(task.spec.title ?? task.spec.id)
                    .font(.system(size: 12, weight: .medium))
                Text(task.result?.summary ?? task.reason ?? task.result?.outcome ?? "No report yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let changed = task.result?.changed, !changed.isEmpty {
                    Text("Changed files")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.top, 2)
                    ForEach(changed, id: \.self) { path in
                        Button { selectPath(path) } label: {
                            Label(path, systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Show this file's diff")
                    }
                }
                if let screen = task.result?.screen, !screen.isEmpty {
                    Text("Test output")
                        .font(.system(size: 11, weight: .semibold))
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
