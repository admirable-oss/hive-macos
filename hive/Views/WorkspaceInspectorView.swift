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

private struct GitChange: Identifiable, Hashable {
    enum Area { case staged, unstaged }

    let path: String
    let code: Character
    let area: Area

    var id: String { "\(area)-\(path)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    var label: String {
        switch code {
        case "?": "U"
        default: String(code)
        }
    }

    var color: Color {
        switch code {
        case "M": .hiveAmber
        case "A", "?": .teal
        case "D": .red
        case "R", "C": .blue
        case "U": .orange
        default: .secondary
        }
    }

    /// Parses `git status --porcelain=v1 -z` output. Paths are relative to the repository root.
    static func parse(_ output: String) -> [GitChange] {
        var changes: [GitChange] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let index = entry[entry.startIndex]
            let worktree = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            // Renames and copies are followed by their original path.
            if index == "R" || index == "C" { _ = entries.next() }

            if index == "?" {
                changes.append(GitChange(path: path, code: "?", area: .unstaged))
                continue
            }
            if index != " " { changes.append(GitChange(path: path, code: index, area: .staged)) }
            if worktree != " " { changes.append(GitChange(path: path, code: worktree, area: .unstaged)) }
        }
        return changes
    }
}

private struct DiffLine: Identifiable {
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

    private var diffLines: [DiffLine] {
        diffText.components(separatedBy: "\n").enumerated().map { DiffLine(id: $0.offset, text: $0.element) }
    }

    private let git = HiveCLIService(executableURL: URL(fileURLWithPath: "/usr/bin/git"))

    private var isNotRepository: Bool { error?.contains("not a git repository") == true }

    private var staged: [GitChange] { (changes ?? []).filter { $0.area == .staged } }
    private var unstaged: [GitChange] { (changes ?? []).filter { $0.area == .unstaged } }

    var body: some View {
        InspectorCard(
            title: "Changes",
            detail: branch ?? URL(fileURLWithPath: directory).lastPathComponent,
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
                    .frame(minHeight: 120)
                    .contextMenu(forSelectionType: GitChange.ID.self) { ids in
                        if !ids.isEmpty {
                            Button("Open") { ids.forEach { NSWorkspace.shared.open(fileURL(for: $0)) } }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(ids.map(fileURL(for:)))
                            }
                        }
                    } primaryAction: { ids in
                        ids.forEach { NSWorkspace.shared.open(fileURL(for: $0)) }
                    }

                    Group {
                        if let diffError {
                            ContentUnavailableView("Can’t Read Diff", systemImage: "exclamationmark.triangle", description: Text(diffError))
                        } else if diffText.isEmpty {
                            ContentUnavailableView("Select a Changed File", systemImage: "doc.text.magnifyingglass", description: Text("Its Git diff appears here."))
                        } else {
                            ScrollView([.horizontal, .vertical]) {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(diffLines) { line in
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
                                .frame(minWidth: 0, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                    .frame(minHeight: 160)
                }
            }
        }
        .task(id: [changeToken, AnyHashable(reloadToken)]) { await load() }
        .task(id: selection.first) { await loadDiff() }
        .onChange(of: requestedPath) { _, path in selectRequestedPath(path) }
    }

    private func load() async {
        do {
            let root = try await git.run(["-C", directory, "rev-parse", "--show-toplevel"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let output = try await git.run(["-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
            let currentBranch = try? await git.run(["-C", root, "branch", "--show-current"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            repositoryRoot = root
            branch = currentBranch?.isEmpty == false ? currentBranch : nil
            changes = GitChange.parse(output)
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
            let fileURL = URL(fileURLWithPath: root).appendingPathComponent(change.path)
            let text: String
            if change.code == "?" {
                text = try untrackedDiff(path: change.path, fileURL: fileURL)
            } else if change.area == .staged {
                text = try await git.run(["-C", root, "diff", "--cached", "--no-ext-diff", "--", change.path])
            } else {
                text = try await git.run(["-C", root, "diff", "--no-ext-diff", "--", change.path])
            }
            guard !Task.isCancelled, selection.first == id else { return }
            diffText = text.isEmpty ? "No textual diff is available for this file." : text
            diffError = nil
        } catch {
            guard !Task.isCancelled, selection.first == id else { return }
            diffError = error.localizedDescription
        }
    }

    private func untrackedDiff(path: String, fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            return "Binary or non-text file; no text diff is available."
        }
        let lines = contents.components(separatedBy: "\n")
        let visibleLines = contents.hasSuffix("\n") ? Array(lines.dropLast()) : lines
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
        let additions = visibleLines.map { "+\($0)" }.joined(separator: "\n")
        return "diff --git a/\(escapedPath) b/\(escapedPath)\nnew file mode 100644\n--- /dev/null\n+++ b/\(escapedPath)\n@@ -0,0 +1,\(visibleLines.count) @@\n\(additions)"
    }

    private func fileURL(for id: GitChange.ID) -> URL {
        let path = changes?.first(where: { $0.id == id })?.path ?? ""
        return URL(fileURLWithPath: repositoryRoot ?? directory).appendingPathComponent(path)
    }
}

private struct ChangeRow: View {
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
