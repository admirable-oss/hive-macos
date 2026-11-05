import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

enum InspectorPanel: String, Hashable, CaseIterable {
    case files
    case changes
    case agent
    case processes

    var title: String {
        switch self {
        case .files: "Files"
        case .changes: "Changes"
        case .agent: "Agent"
        case .processes: "Processes"
        }
    }

    var symbol: String {
        switch self {
        case .files: "doc"
        case .changes: "arrow.triangle.branch"
        case .agent: "sparkles"
        case .processes: "gearshape.2"
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
            // No `.id(directory)`: Changes follows `cd`s itself, keeping its state inside one repository.
            ChangesView(directory: directory, changeToken: changeToken, requestedPath: selectedChangePath)
        case .agent:
            if let agent = viewModel.activeAgent {
                AgentInspectorView(agent: agent, viewModel: viewModel)
                    .id(agent.id)
            } else {
                InspectorCard(title: "Agent", symbol: "sparkles", detail: "", onReload: {}) {
                    ContentUnavailableView(
                        "No Agent Here",
                        systemImage: "sparkles",
                        description: Text("Open an agent’s tab, or start one in this environment.")
                    )
                }
            }
        case .processes:
            if let environment = viewModel.activeEnvironment {
                ProcessesInspectorView(environment: environment, viewModel: viewModel)
                    .id(environment.id)
            } else {
                InspectorCard(title: "Processes", symbol: "gearshape.2", detail: "", onReload: {}) {
                    ContentUnavailableView(
                        "No Environment Here",
                        systemImage: "gearshape.2",
                        description: Text("Open a tab in an environment to run background processes in it.")
                    )
                }
            }
        }
    }
}

// MARK: - Card

struct InspectorCard<Content: View>: View {
    let title: String
    var symbol = "sidebar.right"
    let detail: String
    let onReload: () -> Void
    @ViewBuilder var content: Content

    @State private var reloadSpin = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            InspectorPanelHeader(symbol: symbol, title: title, subtitle: detail) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7)) { reloadSpin += 360 }
                    onReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(reloadSpin))
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Reload")
            }

            Divider().opacity(0.5)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspectorPanelChrome()
    }
}

/// The badge, title and subtitle every inspector panel opens with, plus its trailing buttons.
struct InspectorPanelHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            HiveBadgeIcon(symbol: symbol)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 6)

            accessory
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

extension View {
    /// Floats a panel in the inspector column the way the system floats the sidebar: inset from
    /// the window edges, full height, with matching corners and glass.
    func inspectorPanelChrome() -> some View {
        modifier(InspectorPanelChrome())
    }
}

private struct InspectorPanelChrome: ViewModifier {
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
                .padding(8)
                .ignoresSafeArea(.container, edges: .top)
        } else {
            content
                .background {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center))
                }
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.16), Color.primary.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75
                    )
                )
                .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
                .padding(8)
        }
    }
}

// MARK: - Files

nonisolated private struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isHidden: Bool { name.hasPrefix(".") }
    private var type: UTType? { UTType(filenameExtension: url.pathExtension) }

    private static let ignoredNames: Set<String> = [".git", ".DS_Store"]
    /// Folders a search never descends into: they are huge and almost never what you're after.
    private static let unsearchedNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".next", "dist", ".venv", "target",
    ]

    var symbol: String {
        if isDirectory { return "folder.fill" }
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

    var tint: Color {
        if isDirectory { return .hiveAmber }
        guard let type else { return .secondary }
        if type.conforms(to: .swiftSource) { return .orange }
        if type.conforms(to: .image) { return .purple }
        if type.conforms(to: .pdf) { return .red }
        if type.conforms(to: .audiovisualContent) { return .pink }
        if type.conforms(to: .archive) { return .brown }
        if type.conforms(to: .json) || type.conforms(to: .sourceCode) || type.conforms(to: .script) { return .blue }
        return .secondary
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

    /// Names under `root` containing `query`, shallowest first. Bounded so a home folder stays quick.
    static func search(_ query: String, in root: URL, limit: Int = 200) async -> [FileNode] {
        let task = Task.detached(priority: .userInitiated) { () -> [FileNode] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { return [] }
            var matches: [FileNode] = []
            var visited = 0
            while let url = enumerator.nextObject() as? URL, visited < 25_000, matches.count < limit {
                visited += 1
                if visited.isMultiple(of: 500), Task.isCancelled { return [] }
                let name = url.lastPathComponent
                if unsearchedNames.contains(name) || ignoredNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard name.localizedCaseInsensitiveContains(query) else { continue }
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                matches.append(FileNode(url: url, isDirectory: isDirectory))
            }
            return matches.sorted {
                let left = $0.url.pathComponents.count, right = $1.url.pathComponents.count
                if left != right { return left < right }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

/// One visible line of the tree: a node and how deep it sits.
private struct FileRowItem: Identifiable {
    let node: FileNode
    let depth: Int
    var id: URL { node.url }
}

private struct FileBrowserView: View {
    let directory: String

    @State private var nodes: [FileNode]?
    @State private var children: [URL: [FileNode]] = [:]
    @State private var expanded: Set<URL> = []
    @State private var loading: Set<URL> = []
    @State private var selection: FileNode?
    @State private var hovered: URL?
    @State private var query = ""
    @State private var results: [FileNode]?
    @State private var reloadSpin = 0.0
    @State private var previewHeight: CGFloat = 280
    @FocusState private var isTreeFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rootURL: URL { URL(fileURLWithPath: directory) }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var folderName: String {
        directory == FileManager.default.homeDirectoryForCurrentUser.path ? NSUserName() : rootURL.lastPathComponent
    }

    private var rows: [FileRowItem] {
        if isSearching { return (results ?? []).map { FileRowItem(node: $0, depth: 0) } }
        var rows: [FileRowItem] = []
        func append(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                rows.append(FileRowItem(node: node, depth: depth))
                if expanded.contains(node.url), let kids = children[node.url] {
                    append(kids, depth: depth + 1)
                }
            }
        }
        append(nodes ?? [], depth: 0)
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().opacity(0.5)
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let selection, selection.isPreviewable {
                        PreviewResizeHandle(height: $previewHeight, range: 140...max(140, proxy.size.height - 120))
                        FilePreviewPane(node: selection) {
                            withAnimation(spring) { self.selection = nil }
                        }
                        .frame(height: min(previewHeight, max(140, proxy.size.height - 120)))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .inspectorPanelChrome()
        .task { await reload() }
        .task(id: query) { await runSearch() }
    }

    // MARK: Header

    private var header: some View {
        InspectorPanelHeader(
            symbol: "folder.fill",
            title: "Files",
            subtitle: nodes.map { "\(folderName) · \($0.count) items" } ?? folderName
        ) {
            HStack(spacing: 6) {
                if !expanded.isEmpty && !isSearching {
                    Button {
                        withAnimation(spring) { expanded.removeAll() }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .buttonStyle(HiveIconButtonStyle())
                    .help("Collapse all folders")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }

                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7)) { reloadSpin += 360 }
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(reloadSpin))
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Reload")
            }
        }
        .help(directory)
        .animation(spring, value: expanded.isEmpty)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSearchFocused ? Color.hiveAmber : Color.secondary)
            TextField("Filter files", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) {
                    guard let first = rows.first else { return .ignored }
                    select(first.node)
                    isTreeFocused = true
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if isSearching && results == nil {
                ProgressView().controlSize(.mini)
                    .transition(.opacity)
            } else if !query.isEmpty {
                Button {
                    withAnimation(spring) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(isSearchFocused ? 0.07 : 0.045)))
        .overlay(Capsule().strokeBorder(isSearchFocused ? Color.hiveAmber.opacity(0.45) : Color.primary.opacity(0.05), lineWidth: 0.75))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(spring, value: isSearchFocused)
        .animation(spring, value: query.isEmpty)
    }

    // MARK: Tree

    @ViewBuilder
    private var content: some View {
        if nodes == nil {
            ProgressView().controlSize(.small)
        } else if let nodes, nodes.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
        } else if isSearching, let results, results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            tree
        }
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        FileTreeRow(
                            node: row.node,
                            depth: row.depth,
                            subtitle: isSearching ? relativeParent(of: row.node) : nil,
                            isExpanded: expanded.contains(row.node.url),
                            isLoading: loading.contains(row.node.url),
                            isSelected: selection?.url == row.node.url,
                            isHovered: hovered == row.node.url,
                            namespace: selectionNamespace,
                            onSelect: {
                                select(row.node)
                                if row.node.isDirectory && !isSearching { toggle(row.node) }
                                isTreeFocused = true
                            },
                            onOpen: { NSWorkspace.shared.open(row.node.url) },
                            onToggle: { toggle(row.node) },
                            relativePath: relativePath(of: row.node)
                        )
                        .id(row.node.url)
                        .onHover { inside in
                            if inside { hovered = row.node.url } else if hovered == row.node.url { hovered = nil }
                        }
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .animation(spring, value: hovered)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($isTreeFocused)
            .onKeyPress(.downArrow) { move(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { move(by: -1, proxy: proxy) }
            .onKeyPress(.rightArrow) {
                guard let selection, selection.isDirectory, !expanded.contains(selection.url) else { return .ignored }
                toggle(selection)
                return .handled
            }
            .onKeyPress(.leftArrow) { collapseOrSelectParent(proxy: proxy) }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                NSWorkspace.shared.open(selection.url)
                return .handled
            }
        }
    }

    // MARK: Actions

    private func select(_ node: FileNode) {
        withAnimation(spring) { selection = node }
    }

    private func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.url) {
            withAnimation(spring) { _ = expanded.remove(node.url) }
            return
        }
        withAnimation(spring) { _ = expanded.insert(node.url) }
        guard children[node.url] == nil else { return }
        loading.insert(node.url)
        Task {
            let kids = await FileNode.children(of: node.url)
            withAnimation(spring) {
                children[node.url] = kids
                loading.remove(node.url)
            }
        }
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = rows
        guard !rows.isEmpty else { return .ignored }
        let index = selection.flatMap { current in rows.firstIndex { $0.node.url == current.url } }
        let next = index.map { min(max($0 + offset, 0), rows.count - 1) } ?? (offset > 0 ? 0 : rows.count - 1)
        select(rows[next].node)
        proxy.scrollTo(rows[next].node.url)
        return .handled
    }

    private func collapseOrSelectParent(proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let selection else { return .ignored }
        if selection.isDirectory, expanded.contains(selection.url) {
            toggle(selection)
            return .handled
        }
        let parent = selection.url.deletingLastPathComponent()
        guard let row = rows.first(where: { $0.node.url == parent }) else { return .ignored }
        select(row.node)
        proxy.scrollTo(row.node.url)
        return .handled
    }

    private func reload() async {
        let root = await FileNode.children(of: rootURL)
        var refreshed: [URL: [FileNode]] = [:]
        for url in expanded {
            refreshed[url] = await FileNode.children(of: url)
        }
        withAnimation(spring) {
            nodes = root
            children = refreshed
        }
        if isSearching { await runSearch() }
    }

    private func runSearch() async {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = nil
            return
        }
        results = nil
        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled else { return }
        let found = await FileNode.search(query, in: rootURL)
        guard !Task.isCancelled else { return }
        withAnimation(spring) { results = found }
    }

    private func relativePath(of node: FileNode) -> String {
        let root = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return node.url.path.hasPrefix(root) ? String(node.url.path.dropFirst(root.count)) : node.url.path
    }

    private func relativeParent(of node: FileNode) -> String? {
        let parent = (relativePath(of: node) as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }
}

private struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    let subtitle: String?
    let isExpanded: Bool
    let isLoading: Bool
    let isSelected: Bool
    let isHovered: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onToggle: () -> Void
    let relativePath: String

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                if depth > 0 {
                    HStack(spacing: 0) {
                        ForEach(0..<depth, id: \.self) { _ in
                            Rectangle()
                                .fill(Color.primary.opacity(0.07))
                                .frame(width: 1)
                                .frame(width: 14)
                        }
                    }
                }

                disclosure
                    .frame(width: 10)

                Image(systemName: node.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(node.tint.opacity(node.isDirectory ? 0.9 : 1))
                    .symbolEffect(.bounce, value: isExpanded)
                    .frame(width: 16)

                Text(node.name)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                if isHovered {
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(HiveIconButtonStyle(size: 18))
                    .help("Open in default app")
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .opacity(node.isHidden ? 0.6 : 1)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                if isSelected {
                    shape
                        .fill(Color.hiveAmber.opacity(0.16))
                        .overlay(shape.strokeBorder(Color.hiveAmber.opacity(0.28), lineWidth: 0.5))
                        .matchedGeometryEffect(id: "file-selection", in: namespace)
                } else if isHovered {
                    shape.fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !node.isDirectory { onOpen() } })
        .draggable(node.url)
        .help(node.url.path)
        .contextMenu {
            Button("Open") { onOpen() }
            if !node.isDirectory {
                OpenInEditorMenu(url: node.url)
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            if node.isDirectory {
                Button(isExpanded ? "Collapse" : "Expand") { onToggle() }
            }
            Divider()
            Button("Copy Path") { copy(node.url.path) }
            Button("Copy Relative Path") { copy(relativePath) }
        }
    }

    @ViewBuilder
    private var disclosure: some View {
        if isLoading {
            ProgressView().controlSize(.mini).scaleEffect(0.6)
        } else if node.isDirectory {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// The grabber between the tree and the preview; drag it to give either more room.
private struct PreviewResizeHandle: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var dragStart: CGFloat?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Divider().opacity(0.5)
            Capsule()
                .fill(Color.primary.opacity(isHovering || dragStart != nil ? 0.3 : 0.14))
                .frame(width: isHovering || dragStart != nil ? 44 : 32, height: 4)
        }
        .frame(height: 12)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start - value.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragStart != nil)
    }
}

private struct FilePreviewPane: View {
    let node: FileNode
    let onClose: () -> Void

    private var details: String {
        let values = try? node.url.resourceValues(forKeys: [.fileSizeKey, .localizedTypeDescriptionKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [values?.localizedTypeDescription, size].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .id(node.url)
                .transition(.opacity)
                Spacer(minLength: 4)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Reveal in Finder")
                Button {
                    NSWorkspace.shared.open(node.url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Open in default app")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Close preview")
            }
            .padding(.horizontal, 4)

            QuickLookPreview(url: node.url)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: node.url)
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

/// Git changes for whichever repository `directory` sits in. It follows the terminal's `cd`s,
/// keeping its state while you move around inside one repository, and watches the working tree
/// so status and the open diff update as files change on disk.
private struct ChangesView: View {
    let directory: String
    let changeToken: AnyHashable
    let requestedPath: String?

    @State private var isResolved = false
    @State private var repositoryRoot: String?
    @State private var branch: String?
    @State private var changes: [GitChange]?
    @State private var selection: Set<GitChange.ID> = []
    @State private var hovered: GitChange.ID?
    @State private var error: String?
    @State private var diffText = ""
    @State private var diffError: String?
    @State private var diffStats = (added: 0, removed: 0)
    @State private var diffHeight: CGFloat = 300
    @State private var isBusy = false
    @State private var actionError: String?
    @State private var showingCommit = false
    @State private var watcher: DirectoryWatcher?
    @State private var watchedPath: String?
    @State private var isLoading = false
    @State private var needsReload = false
    @State private var pulse = 0
    @State private var reloadSpin = 0.0
    @FocusState private var isListFocused: Bool
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var git: GitClient { GitClient(directory: repositoryRoot ?? directory) }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82) }

    private var isNotRepository: Bool { error?.contains("not a git repository") == true }
    private var staged: [GitChange] { (changes ?? []).filter { $0.area == .staged } }
    private var unstaged: [GitChange] { (changes ?? []).filter { $0.area == .unstaged } }
    private var ordered: [GitChange] { staged + unstaged }
    private var selectedChange: GitChange? { ordered.first { selection.contains($0.id) } }
    private var folderName: String { URL(fileURLWithPath: repositoryRoot ?? directory).lastPathComponent }
    private var subtitle: String { [folderName, branch].compactMap { $0 }.joined(separator: " · ") }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            GeometryReader { proxy in
                let maxDiff = max(140, proxy.size.height - 120)
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let selectedChange {
                        PreviewResizeHandle(height: $diffHeight, range: 140...maxDiff)
                        diffPane(selectedChange)
                            .frame(height: min(diffHeight, maxDiff))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            if repositoryRoot != nil {
                Divider().opacity(0.5)
                commitBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .inspectorPanelChrome()
        .task(id: directory) { await resolveRepository() }
        .task(id: selection.first) { await loadDiff(clearing: true) }
        .onChange(of: changeToken) { scheduleReload() }
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
                    scheduleReload()
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        InspectorPanelHeader(symbol: "arrow.triangle.branch", title: "Changes", subtitle: subtitle) {
            HStack(spacing: 6) {
                if repositoryRoot != nil && watcher != nil {
                    LiveBadge(pulse: pulse)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7)) { reloadSpin += 360 }
                    Task { await resolveRepository() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(reloadSpin))
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Reload")
            }
        }
        .help(repositoryRoot ?? directory)
        .animation(spring, value: repositoryRoot)
    }

    // MARK: List

    @ViewBuilder
    private var content: some View {
        if !isResolved {
            ProgressView().controlSize(.small)
        } else if isNotRepository {
            ContentUnavailableView(
                "Not a Git Repository",
                systemImage: "arrow.triangle.branch",
                description: Text("cd into a repository and its changes show up here, live.")
            )
            .transition(.opacity)
        } else if let error {
            ContentUnavailableView("Can’t Read Changes", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if changes == nil {
            ProgressView().controlSize(.small)
        } else if ordered.isEmpty {
            ContentUnavailableView("No Changes", systemImage: "checkmark.circle", description: Text("The working tree is clean."))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !staged.isEmpty {
                        ChangeSectionHeader(title: "Staged", count: staged.count, symbol: "minus", help: "Unstage all", isBusy: isBusy) {
                            unstageAll()
                        }
                        ForEach(staged) { row($0) }
                    }
                    if !unstaged.isEmpty {
                        ChangeSectionHeader(title: "Changes", count: unstaged.count, symbol: "plus", help: "Stage all", isBusy: isBusy) {
                            stageAll()
                        }
                        .padding(.top, staged.isEmpty ? 0 : 8)
                        ForEach(unstaged) { row($0) }
                    }
                }
                .padding(6)
                .animation(spring, value: hovered)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onKeyPress(.downArrow) { move(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { move(by: -1, proxy: proxy) }
            .onKeyPress(.space) {
                guard let selectedChange else { return .ignored }
                toggleStage([selectedChange])
                return .handled
            }
            .onKeyPress(.return) {
                guard let selectedChange else { return .ignored }
                open(selectedChange)
                return .handled
            }
        }
    }

    private func row(_ change: GitChange) -> some View {
        GitChangeRow(
            change: change,
            isSelected: selection.contains(change.id),
            usesMatchedSelection: selection.count == 1,
            isHovered: hovered == change.id,
            isBusy: isBusy,
            namespace: selectionNamespace,
            onSelect: { select(change) },
            onToggleStage: { toggleStage([change]) },
            onOpen: { open(change) },
            fileURL: fileURL(for: change)
        )
        .id(change.id)
        .onHover { inside in
            if inside { hovered = change.id } else if hovered == change.id { hovered = nil }
        }
        .contextMenu { menu(for: change) }
        .transition(.opacity.combined(with: .offset(y: -6)))
    }

    @ViewBuilder
    private func menu(for change: GitChange) -> some View {
        let targets = selection.contains(change.id) ? ordered.filter { selection.contains($0.id) } : [change]
        let stageable = targets.filter { $0.area == .unstaged }
        let unstageable = targets.filter { $0.area == .staged }
        if !stageable.isEmpty {
            Button(stageable.count == 1 ? "Stage File" : "Stage \(stageable.count) Files") { stage(stageable) }
                .disabled(isBusy)
        }
        if !unstageable.isEmpty {
            Button(unstageable.count == 1 ? "Unstage File" : "Unstage \(unstageable.count) Files") { unstage(unstageable) }
                .disabled(isBusy)
        }
        Divider()
        Button("Open") { targets.forEach(open) }
        if targets.count == 1 {
            OpenInEditorMenu(url: fileURL(for: change))
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets.map(fileURL)) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }

    // MARK: Diff

    private func diffPane(_ change: GitChange) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ChangeStatusBadge(change: change)
                VStack(alignment: .leading, spacing: 0) {
                    Text(change.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(change.area == .staged ? "Staged" : (change.code == "?" ? "Untracked" : "Not staged"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .id(change.id)
                .transition(.opacity)

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Text("+\(diffStats.added)").foregroundStyle(DiffLine(id: 0, text: "+").foreground)
                    Text("−\(diffStats.removed)").foregroundStyle(DiffLine(id: 0, text: "-").foreground)
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .contentTransition(.numericText())

                Button { toggleStage([change]) } label: {
                    Image(systemName: change.area == .staged ? "minus" : "plus")
                }
                .buttonStyle(HiveIconButtonStyle())
                .disabled(isBusy)
                .help(change.area == .staged ? "Unstage file" : "Stage file")

                Button { open(change) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(HiveIconButtonStyle())
                .help("Open in default app")
            }
            .padding(.horizontal, 4)

            DiffPaneView(
                diffText: diffText,
                error: diffError,
                area: change.area,
                isBusy: isBusy,
                root: repositoryRoot ?? directory,
                onApplyHunks: applyHunks
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: change.id)
        .animation(spring, value: diffStats.added + diffStats.removed)
    }

    // MARK: Commit bar

    private var commitBar: some View {
        HStack(spacing: 8) {
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .transition(.opacity)
            } else {
                HStack(spacing: 4) {
                    if staged.isEmpty {
                        Text("Nothing staged")
                    } else {
                        Text("\(staged.count)")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(.primary)
                        Text(staged.count == 1 ? "file staged" : "files staged")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button { showingCommit = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("Commit")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(Color.hiveAmber.gradient)
                        .shadow(color: Color.hiveAmber.opacity(staged.isEmpty ? 0 : 0.3), radius: 3, y: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(staged.isEmpty)
            .opacity(staged.isEmpty ? 0.4 : 1)
            .scaleEffect(staged.isEmpty ? 0.96 : 1)
            .help("Review and commit what is staged")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .animation(spring, value: staged.count)
        .animation(spring, value: actionError)
    }

    // MARK: Loading

    /// Finds the repository around `directory`. A new repository resets the panel and moves
    /// the watcher; moving around inside the same one keeps everything as it is.
    private func resolveRepository() async {
        var root: String?
        var failure: String?
        do {
            root = try await GitClient(directory: directory).root()
        } catch {
            failure = error.localizedDescription
        }
        guard !Task.isCancelled else { return }

        if root != repositoryRoot || !isResolved {
            withAnimation(spring) {
                repositoryRoot = root
                branch = nil
                changes = nil
                selection = []
                diffText = ""
                diffError = nil
                actionError = nil
                error = failure
                isResolved = true
            }
        }
        // Outside a repository the watcher sits on the folder itself, so it moves with every `cd`.
        if watchedPath != root ?? directory { watch(root ?? directory) }
        if root != nil { scheduleReload() }
    }

    private func watch(_ path: String) {
        watcher?.stop()
        watchedPath = path
        watcher = DirectoryWatcher(path: path) { paths in handleFileEvents(paths) }
    }

    private func handleFileEvents(_ paths: [String]) {
        guard let root = repositoryRoot else {
            // Not a repository yet: only a `git init` (or clone) right here matters.
            let watched = directory.hasSuffix("/") ? directory : directory + "/"
            let relevant = paths.contains { path in
                let folder = path.hasSuffix("/") ? path : path + "/"
                return folder == watched || folder.hasPrefix(watched + ".git/")
            }
            if relevant { Task { await resolveRepository() } }
            return
        }
        let noise = ["/.git/objects", "/.git/logs"].map { root + $0 }
        if paths.contains(where: { path in !noise.contains { path.hasPrefix($0) } }) {
            scheduleReload()
        }
    }

    /// Reloads now, or once more after the load in flight, so bursts of file events coalesce.
    private func scheduleReload() {
        guard !isLoading else {
            needsReload = true
            return
        }
        isLoading = true
        Task {
            repeat {
                needsReload = false
                await load()
            } while needsReload
            isLoading = false
        }
    }

    private func load() async {
        guard let root = repositoryRoot else { return }
        let git = GitClient(directory: root)
        do {
            let newBranch = await git.branch(root: root)
            let newChanges = try await git.status(root: root)
            guard root == repositoryRoot else { return }
            let isFirstLoad = changes == nil
            if newChanges != changes || newBranch != branch {
                withAnimation(spring) {
                    branch = newBranch
                    changes = newChanges
                    selection.formIntersection(Set(newChanges.map(\.id)))
                    selectRequestedPath(requestedPath)
                    if selection.isEmpty, let first = (newChanges.filter { $0.area == .staged } + newChanges.filter { $0.area == .unstaged }).first {
                        selection = [first.id]
                    }
                }
                if !isFirstLoad { pulse += 1 }
            }
            if error != nil { withAnimation(spring) { error = nil } }
            await loadDiff(clearing: false)
        } catch {
            guard root == repositoryRoot else { return }
            withAnimation(spring) {
                changes = nil
                selection = []
                diffText = ""
                diffError = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func selectRequestedPath(_ path: String?) {
        guard let path, let change = changes?.first(where: { $0.path == path || $0.path.hasSuffix("/" + path) }) else { return }
        selection = [change.id]
    }

    /// `clearing` empties the pane first, for a new selection; a live refresh swaps in place.
    private func loadDiff(clearing: Bool) async {
        guard let change = selectedChange, let root = repositoryRoot else {
            diffText = ""
            diffError = nil
            diffStats = (0, 0)
            return
        }
        if clearing {
            diffText = ""
            diffError = nil
        }
        do {
            let text = try await GitClient(directory: root).diff(root: root, change: change)
            guard !Task.isCancelled, selectedChange?.id == change.id else { return }
            let shown = text.isEmpty ? "No textual diff is available for this file." : text
            guard shown != diffText || diffError != nil else { return }
            diffText = shown
            diffError = nil
            diffStats = Self.stats(of: text)
        } catch {
            guard !Task.isCancelled, selectedChange?.id == change.id else { return }
            diffError = error.localizedDescription
            diffStats = (0, 0)
        }
    }

    private static func stats(of diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        diff.enumerateLines { line, _ in
            switch DiffLine(id: 0, text: line).kind {
            case .added: added += 1
            case .removed: removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    // MARK: Actions

    private func select(_ change: GitChange) {
        isListFocused = true
        withAnimation(spring) {
            if NSEvent.modifierFlags.contains(.command) {
                if selection.contains(change.id), selection.count > 1 {
                    selection.remove(change.id)
                } else {
                    selection.insert(change.id)
                }
            } else {
                selection = [change.id]
            }
        }
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let ordered = ordered
        guard !ordered.isEmpty else { return .ignored }
        let index = selectedChange.flatMap { current in ordered.firstIndex { $0.id == current.id } }
        let next = index.map { min(max($0 + offset, 0), ordered.count - 1) } ?? 0
        withAnimation(spring) { selection = [ordered[next].id] }
        proxy.scrollTo(ordered[next].id)
        return .handled
    }

    private func toggleStage(_ list: [GitChange]) {
        let stageable = list.filter { $0.area == .unstaged }
        if stageable.isEmpty { unstage(list) } else { stage(stageable) }
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
            scheduleReload()
        }
    }

    private func open(_ change: GitChange) {
        NSWorkspace.shared.open(fileURL(for: change))
    }

    private func fileURL(for change: GitChange) -> URL {
        URL(fileURLWithPath: repositoryRoot ?? directory).appendingPathComponent(change.path)
    }
}

private struct ChangeSectionHeader: View {
    let title: String
    let count: Int
    let symbol: String
    let help: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentTransition(.numericText())
            Spacer()
            Button(action: action) {
                Image(systemName: symbol)
            }
            .buttonStyle(HiveIconButtonStyle(size: 18))
            .disabled(isBusy)
            .help(help)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

private struct GitChangeRow: View {
    let change: GitChange
    let isSelected: Bool
    /// Only a single selection slides between rows; several selected rows each draw their own.
    let usesMatchedSelection: Bool
    let isHovered: Bool
    let isBusy: Bool
    let namespace: Namespace.ID
    let onSelect: () -> Void
    let onToggleStage: () -> Void
    let onOpen: () -> Void
    let fileURL: URL

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ChangeStatusBadge(change: change)

                Text(change.fileName)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .strikethrough(change.code == "D", color: .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 4)

                if isHovered {
                    HStack(spacing: 4) {
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(HiveIconButtonStyle(size: 18))
                        .help("Open in default app")
                        Button(action: onToggleStage) {
                            Image(systemName: change.area == .staged ? "minus" : "plus")
                        }
                        .buttonStyle(HiveIconButtonStyle(size: 18))
                        .disabled(isBusy)
                        .help(change.area == .staged ? "Unstage file" : "Stage file")
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                if isSelected {
                    if usesMatchedSelection {
                        selectionShape.matchedGeometryEffect(id: "change-selection", in: namespace)
                    } else {
                        selectionShape
                    }
                } else if isHovered {
                    shape.fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .draggable(fileURL)
        .help(change.path)
    }

    private var selectionShape: some View {
        shape
            .fill(Color.hiveAmber.opacity(0.16))
            .overlay(shape.strokeBorder(Color.hiveAmber.opacity(0.28), lineWidth: 0.5))
    }
}

/// Shows that the panel is watching the disk, and pulses each time it picks up a change.
private struct LiveBadge: View {
    let pulse: Int

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .keyframeAnimator(initialValue: 1.0, trigger: pulse) { content, scale in
                        content
                            .scaleEffect(scale)
                            .opacity(2 - scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(1.9, duration: 0.2)
                            SpringKeyframe(1.0, duration: 0.4)
                        }
                    }
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .help("Updates as files change on disk")
    }
}
