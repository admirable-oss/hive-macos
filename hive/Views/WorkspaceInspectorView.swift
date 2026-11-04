import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

enum InspectorPanel: String, Hashable, CaseIterable {
    case files
    case changes
    case agent

    var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Changes"
        case .agent: "Agent"
        }
    }

    var symbol: String {
        switch self {
        case .files: "doc"
        case .changes: "arrow.triangle.branch"
        case .agent: "sparkles"
        }
    }
}

/// The right-hand column. Files and Changes follow the active terminal's current directory;
/// Agent shows the active tab's agent.
struct WorkspaceInspectorView: View {
    let panel: InspectorPanel
    let directory: String
    /// Changes whenever Hive reports new git counts, so the Changes panel reloads on its own.
    let changeToken: AnyHashable
    let selectedChangePath: String?
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        switch panel {
        case .files:
            FileBrowserView(directory: directory)
                .id(directory)
        case .changes:
            ChangesView(directory: directory, changeToken: changeToken, requestedPath: selectedChangePath)
                .id(directory)
        case .agent:
            if let agent = viewModel.activeAgent {
                AgentInspectorView(agent: agent, viewModel: viewModel)
                    .id(agent.id)
            } else {
                InspectorCard(title: "Agent", detail: "", onReload: {}) {
                    ContentUnavailableView(
                        "No Agent Here",
                        systemImage: "sparkles",
                        description: Text("Open an agent’s tab, or start one in this environment.")
                    )
                }
            }
        }
    }
}

// MARK: - Card

struct InspectorCard<Content: View>: View {
    let title: String
    let detail: String
    let onReload: () -> Void
    @ViewBuilder var content: Content

    @State private var isHoveringHeader = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHoveringHeader ? 1 : 0)
                .help("Reload")
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
            .onHover { isHoveringHeader = $0 }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        .padding(8)
    }
}

// MARK: - Files

nonisolated private struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    private var type: UTType? { UTType(filenameExtension: url.pathExtension) }

    private static let ignoredNames: Set<String> = [".git", ".DS_Store"]

    var symbol: String {
        if isDirectory { return "folder" }
        guard let type else { return "doc.text" }
        if type.conforms(to: .swiftSource) { return "swift" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
        if type.conforms(to: .archive) { return "archivebox" }
        if type.conforms(to: .json) || type.conforms(to: .sourceCode) || type.conforms(to: .script) {
            return "chevron.left.forwardslash.chevron.right"
        }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// Quick Look can show it. Archives, apps and disk images only ever preview as an icon.
    var isPreviewable: Bool {
        guard !isDirectory else { return false }
        guard let type else { return true }
        return ![.archive, .diskImage, .application, .executable].contains { type.conforms(to: $0) }
    }

    static func children(of url: URL) async -> [FileNode] {
        await Task.detached(priority: .userInitiated) {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            return urls
                .filter { !ignoredNames.contains($0.lastPathComponent) }
                .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        }.value
    }
}

private struct FileBrowserView: View {
    let directory: String

    @State private var nodes: [FileNode]?
    @State private var selection: FileNode?
    @State private var reloadToken = UUID()

    private var rootURL: URL { URL(fileURLWithPath: directory) }

    private var folderName: String {
        directory == FileManager.default.homeDirectoryForCurrentUser.path ? NSUserName() : rootURL.lastPathComponent
    }

    var body: some View {
        InspectorCard(title: "Files", detail: folderName, onReload: { reloadToken = UUID() }) {
            if let nodes, nodes.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else if let selection, selection.isPreviewable {
                VSplitView {
                    tree
                        .frame(minHeight: 140)
                    FilePreviewPane(node: selection)
                        .frame(minHeight: 160, idealHeight: 300)
                }
            } else {
                tree
            }
        }
        .task(id: reloadToken) { nodes = await FileNode.children(of: rootURL) }
    }

    private var tree: some View {
        List(selection: $selection) {
            ForEach(nodes ?? []) { node in
                FileTreeRow(node: node)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: FileNode.self) { nodes in
            let urls = nodes.map(\.url)
            if !urls.isEmpty {
                Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                }
            }
        } primaryAction: { nodes in
            nodes.forEach { NSWorkspace.shared.open($0.url) }
        }
    }
}

private struct FileTreeRow: View {
    let node: FileNode

    @State private var isExpanded = false
    @State private var children: [FileNode]?

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children ?? []) { child in
                    FileTreeRow(node: child)
                }
            } label: {
                FileLabel(node: node)
            }
            .task(id: isExpanded) {
                if isExpanded && children == nil {
                    children = await FileNode.children(of: node.url)
                }
            }
        } else {
            FileLabel(node: node)
        }
    }
}

private struct FileLabel: View {
    let node: FileNode

    var body: some View {
        Label {
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: node.symbol)
                .foregroundStyle(.secondary)
        }
        .tag(node)
        .help(node.url.path)
    }
}

private struct FilePreviewPane: View {
    let node: FileNode

    private var details: String {
        let values = try? node.url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    NSWorkspace.shared.open(node.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open in default app")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            QuickLookPreview(url: node.url)
        }
    }
}

/// Finder's own previewer: text and code, images, PDFs, video, audio, documents.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

// MARK: - Changes

private struct ChangesView: View {
    let directory: String
    let changeToken: AnyHashable
    let requestedPath: String?

    @State private var repositoryRoot: String?
    @State private var branch: String?
    @State private var changes: [GitChange]?
    @State private var selection: Set<GitChange.ID> = []
    @State private var error: String?
    @State private var reloadToken = UUID()
    @State private var diffText = ""
    @State private var diffError: String?
    @State private var isBusy = false
    @State private var actionError: String?
    @State private var showingCommit = false

    private var git: GitClient { GitClient(directory: directory) }

    private var isNotRepository: Bool { error?.contains("not a git repository") == true }
    private var staged: [GitChange] { (changes ?? []).filter { $0.area == .staged } }
    private var selectedChange: GitChange? { changes?.first { selection.contains($0.id) } }
    private var folderName: String { URL(fileURLWithPath: directory).lastPathComponent }

    var body: some View {
        InspectorCard(
            title: "Changes",
            detail: branch ?? folderName,
            onReload: { reloadToken = UUID() }
        ) {
            if isNotRepository {
                ContentUnavailableView(
                    "Not a Git Repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Initialize Git in this folder to track changes.")
                )
            } else if let error {
                ContentUnavailableView("Can’t Read Changes", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let changes, changes.isEmpty {
                ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
            } else {
                VSplitView {
                    ChangeListView(
                        changes: changes ?? [],
                        selection: $selection,
                        isBusy: isBusy,
                        onStage: stage,
                        onUnstage: unstage,
                        onOpen: { open($0) },
                        onReveal: { reveal($0) }
                    )
                    .frame(minHeight: 120)

                    DiffPaneView(
                        diffText: diffText,
                        error: diffError,
                        area: selectedChange?.area,
                        isBusy: isBusy,
                        onApplyHunks: applyHunks
                    )
                    .frame(minHeight: 160)
                }
            }

            Divider()
            commitBar
        }
        .task(id: [changeToken, AnyHashable(reloadToken)]) { await load() }
        .task(id: selection.first) { await loadDiff() }
        .onChange(of: requestedPath) { _, path in selectRequestedPath(path) }
        .sheet(isPresented: $showingCommit) {
            if let repositoryRoot {
                CommitSheet(
                    environmentName: folderName,
                    path: directory,
                    branch: branch,
                    root: repositoryRoot,
                    client: git
                ) {
                    reloadToken = UUID()
                }
            }
        }
    }

    private var commitBar: some View {
        HStack(spacing: 8) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(staged.isEmpty ? "No staged changes" : "\(staged.count) staged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Stage All") { stageAll() }
                .buttonStyle(.borderless)
                .disabled((changes ?? []).isEmpty || isBusy)
                .help("Stage every change")
            Button("Unstage All") { unstageAll() }
                .buttonStyle(.borderless)
                .disabled(staged.isEmpty || isBusy)
                .help("Move every staged change back out of the index")
            Button("Commit") { showingCommit = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(staged.isEmpty)
                .help("Review and commit what is staged")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func load() async {
        do {
            let root = try await git.root()
            repositoryRoot = root
            branch = await git.branch(root: root)
            changes = try await git.status(root: root)
            selection.formIntersection(Set(changes?.map(\.id) ?? []))
            selectRequestedPath(requestedPath)
            if selection.isEmpty, let first = changes?.first { selection = [first.id] }
            error = nil
        } catch {
            repositoryRoot = nil
            branch = nil
            changes = nil
            selection = []
            diffText = ""
            diffError = nil
            self.error = error.localizedDescription
        }
    }

    private func selectRequestedPath(_ path: String?) {
        guard let path, let change = changes?.first(where: { $0.path == path || $0.path.hasSuffix("/" + path) }) else { return }
        selection = [change.id]
    }

    private func loadDiff() async {
        guard let id = selection.first, let change = changes?.first(where: { $0.id == id }), let root = repositoryRoot else {
            diffText = ""
            diffError = nil
            return
        }
        diffText = ""
        diffError = nil
        do {
            let text = try await git.diff(root: root, change: change)
            guard !Task.isCancelled, selection.first == id else { return }
            diffText = text.isEmpty ? "No textual diff is available for this file." : text
            diffError = nil
        } catch {
            guard !Task.isCancelled, selection.first == id else { return }
            diffError = error.localizedDescription
        }
    }

    private func stage(_ list: [GitChange]) {
        mutate { try await git.stage(root: $0, paths: list.map(\.path)) }
    }

    private func unstage(_ list: [GitChange]) {
        mutate { try await git.unstage(root: $0, paths: list.map(\.path)) }
    }

    private func stageAll() {
        mutate { try await git.stageAll(root: $0) }
    }

    private func unstageAll() {
        mutate { try await git.unstageAll(root: $0) }
    }

    private func applyHunks(file: FileDiff, hunk: DiffHunk) {
        guard let area = selectedChange?.area else { return }
        let patch = file.patch(selecting: [hunk])
        mutate { try await git.applyToIndex(root: $0, patch: patch, reverse: area == .staged) }
    }

    private func mutate(_ operation: @escaping (String) async throws -> Void) {
        guard let repositoryRoot, !isBusy else { return }
        Task {
            isBusy = true
            do {
                try await operation(repositoryRoot)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
            isBusy = false
            await load()
            await loadDiff()
        }
    }

    private func open(_ id: GitChange.ID) {
        guard let change = changes?.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(fileURL(for: change))
    }

    private func reveal(_ id: GitChange.ID) {
        guard let change = changes?.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: change)])
    }

    private func fileURL(for change: GitChange) -> URL {
        URL(fileURLWithPath: repositoryRoot ?? directory).appendingPathComponent(change.path)
    }
}
