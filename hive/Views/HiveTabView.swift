import AppKit
import SwiftUI

/// A Hive tab: its panes laid out the way the daemon arranges them, one live terminal each.
/// The divider between panes drags like any macOS split view and moves the border in Hive.
struct HiveTabView: View {
    let tab: HiveTab
    @ObservedObject var viewModel: AppViewModel
    let terminals: TerminalStore

    @Environment(\.displayScale) private var displayScale
    @State private var resizeTask: Task<Void, Never>?

    private var cellSize: CGSize { TerminalSession.cellSize(scale: displayScale) }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let zoomed = tab.zoomed {
                    pane(zoomed)
                } else if let layout = tab.layout {
                    LayoutNodeView(node: layout, cellSize: cellSize, pane: { AnyView(pane($0)) }, resize: viewModel.resizePane)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear { scheduleTabResize(for: geometry.size) }
            .onChange(of: geometry.size) { _, size in scheduleTabResize(for: size) }
        }
    }

    private func pane(_ id: String) -> some View {
        let focused = viewModel.focusedPaneID == id
        let session = terminals.paneSession(id) {
            let directory = viewModel.workspace.process(forPane: id)?.workingDirectory
                ?? viewModel.activeEnvironment?.path
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            return PaneTerminalSession(paneID: id, directory: directory, workspace: viewModel.workspace)
        }
        return TerminalSurface(
            session: session,
            isFocused: focused,
            showsFocusRing: tab.paneIDs.count > 1 && tab.zoomed == nil,
            onFocus: { if !focused { viewModel.focusPane(id) } },
            onClose: { Task { await viewModel.closePane(id) } }
        )
        .id(id)
    }

    /// Tells Hive the tab's size in cells, so its layout (and the TUI's, if it's open) matches.
    private func scheduleTabResize(for size: CGSize) {
        let width = Int(size.width / cellSize.width)
        let height = Int(size.height / cellSize.height)
        guard width > 10, height > 4, width != tab.width || height != tab.height else { return }
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            viewModel.resizeHiveTab(tab.id, width: width, height: height)
        }
    }
}

private struct LayoutNodeView: View {
    let node: HiveLayoutNode
    let cellSize: CGSize
    let pane: (String) -> AnyView
    let resize: (_ paneID: String, _ direction: String, _ cells: Int) -> Void

    var body: some View {
        switch node {
        case .pane(let id):
            pane(id)
        case .split(let axis, let ratio, let first, let second):
            SplitView(
                axis: axis,
                ratio: ratio,
                cellLength: axis == .horizontal ? cellSize.width : cellSize.height,
                first: LayoutNodeView(node: first, cellSize: cellSize, pane: pane, resize: resize),
                second: LayoutNodeView(node: second, cellSize: cellSize, pane: pane, resize: resize),
                onDragEnd: { cells in
                    resize(first.paneOnTrailingEdge(axis), axis == .horizontal ? "right" : "down", cells)
                }
            )
        }
    }
}

private struct SplitView<First: View, Second: View>: View {
    let axis: HiveLayoutNode.Axis
    let ratio: Double
    let cellLength: CGFloat
    let first: First
    let second: Second
    let onDragEnd: (_ cells: Int) -> Void

    /// How far the divider has been dragged, until Hive answers with the new ratio.
    @State private var dragOffset: CGFloat = 0

    private static var minimumLength: CGFloat { 60 }

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let firstLength = min(max(total * ratio + dragOffset, Self.minimumLength), max(Self.minimumLength, total - Self.minimumLength))
            if axis == .horizontal {
                HStack(spacing: 0) {
                    first.frame(width: firstLength)
                    divider(total: total)
                    second
                }
            } else {
                VStack(spacing: 0) {
                    first.frame(height: firstLength)
                    divider(total: total)
                    second
                }
            }
        }
        .onChange(of: ratio) { dragOffset = 0 }
    }

    private func divider(total: CGFloat) -> some View {
        let isHorizontal = axis == .horizontal
        return Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: isHorizontal ? 1 : nil, height: isHorizontal ? nil : 1)
            .overlay {
                // A wider, invisible grab area, as AppKit split views have.
                Color.clear
                    .frame(width: isHorizontal ? 8 : nil, height: isHorizontal ? nil : 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                dragOffset = isHorizontal ? value.translation.width : value.translation.height
                            }
                            .onEnded { value in
                                let moved = isHorizontal ? value.translation.width : value.translation.height
                                let cells = Int((moved / cellLength).rounded())
                                if cells == 0 { dragOffset = 0 } else { onDragEnd(cells) }
                                // If Hive refuses the move, don't leave the divider stranded.
                                Task {
                                    try? await Task.sleep(for: .seconds(1.5))
                                    dragOffset = 0
                                }
                            }
                    )
            }
            .zIndex(1)
    }
}
