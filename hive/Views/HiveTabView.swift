import AppKit
import SwiftUI

/// A Hive tab: its panes laid out the way the daemon arranges them, one live terminal each.
/// Every pane is placed by its own frame rather than nested split views, so a split, a close
/// or a zoom animates: panes glide to their new places and keep their terminals throughout.
struct HiveTabView: View {
    let tab: HiveTab
    @ObservedObject var viewModel: AppViewModel
    let terminals: TerminalStore

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resizeTask: Task<Void, Never>?
    /// The layout on screen. It trails `tab.layout` so changes can be animated.
    @State private var layout: HiveLayoutNode?
    @State private var zoomed: String?
    /// How far each divider (by its path in the layout) has been dragged, until Hive answers.
    @State private var dragOffsets: [String: CGFloat] = [:]
    @State private var hoveredPane: String?

    private var cellSize: CGSize { TerminalSession.cellSize(scale: displayScale) }
    private var shownLayout: HiveLayoutNode? { layout ?? tab.layout }
    private var paneIDs: [String] { shownLayout?.paneIDs ?? [] }
    private var isSplit: Bool { paneIDs.count > 1 }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86) }

    /// Room around and between panes once a tab is split, tmux's borders as gaps.
    private var gap: CGFloat { isSplit ? 6 : 0 }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: gap, dy: gap)
            ZStack(alignment: .topLeading) {
                if let shownLayout {
                    let arrangement = PaneArrangement(node: shownLayout, in: bounds, gap: gap, offsets: dragOffsets)
                    ForEach(paneIDs, id: \.self) { id in
                        let isZoomed = zoomed == id
                        let isHidden = zoomed != nil && !isZoomed
                        let rect = isZoomed ? bounds : arrangement.panes[id] ?? bounds
                        paneCard(id, isHidden: isHidden)
                            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(isHidden ? 0 : 1)
                            .scaleEffect(isHidden ? 0.97 : 1)
                            .allowsHitTesting(!isHidden)
                            .zIndex(isZoomed ? 1 : 0)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .scale(scale: 0.94).combined(with: .opacity)
                            ))
                    }
                    if zoomed == nil {
                        ForEach(arrangement.dividers) { divider in
                            PaneDivider(divider: divider) { offset in
                                dragOffsets[divider.id] = offset
                            } onEnd: { moved in
                                endDrag(divider, moved: moved)
                            }
                            .transition(.opacity)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(isSplit ? Color(nsColor: .windowBackgroundColor) : .clear)
            .onAppear { scheduleTabResize(for: geometry.size) }
            .onChange(of: geometry.size) { _, size in scheduleTabResize(for: size) }
        }
        .onAppear {
            layout = tab.layout
            zoomed = tab.zoomed
        }
        .onChange(of: tab.layout) { _, newLayout in
            // Clear drags in the same transaction, so a divider eases from where it was let go.
            withAnimation(spring) {
                layout = newLayout
                dragOffsets = [:]
            }
        }
        .onChange(of: tab.zoomed) { _, newZoomed in
            withAnimation(spring) { zoomed = newZoomed }
        }
    }

    // MARK: Panes

    private func paneCard(_ id: String, isHidden: Bool) -> some View {
        let focused = viewModel.focusedPaneID == id
        let shape = RoundedRectangle(cornerRadius: isSplit ? 10 : 0, style: .continuous)
        return pane(id, focused: focused, acceptsClicks: !isHidden)
            .clipShape(shape)
            .overlay {
                if isSplit {
                    shape
                        .strokeBorder(focused ? Color.hiveAmber.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: focused ? 1.25 : 0.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Panes you aren't typing in sit back a little, as tmux dims inactive ones.
                if isSplit && !focused {
                    shape.fill(Color.black.opacity(0.14)).allowsHitTesting(false)
                }
            }
            .shadow(color: isSplit && focused ? Color.hiveAmber.opacity(0.16) : .clear, radius: 10)
            .overlay(alignment: .topTrailing) {
                if hoveredPane == id {
                    PaneControls(
                        canSplit: canSplit,
                        canZoom: isSplit,
                        isZoomed: zoomed == id,
                        canClose: isSplit,
                        onSplitRight: { viewModel.splitPane(id, direction: "right") },
                        onSplitDown: { viewModel.splitPane(id, direction: "down") },
                        onZoom: { viewModel.toggleZoom(id) },
                        onClose: { viewModel.requestClosePane(id) }
                    )
                    .padding(8)
                    .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .onHover { inside in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    if inside { hoveredPane = id } else if hoveredPane == id { hoveredPane = nil }
                }
            }
            .animation(.easeOut(duration: 0.18), value: focused)
    }

    private func pane(_ id: String, focused: Bool, acceptsClicks: Bool) -> some View {
        let session = terminals.paneSession(id, viewModel: viewModel)
        return TerminalSurface(
            session: session,
            isFocused: focused,
            showsFocusRing: false,
            acceptsClicks: acceptsClicks,
            menuItems: menuItems(for: id),
            onFocus: { if !focused { viewModel.focusPane(id) } },
            onClose: { viewModel.requestClosePane(id) }
        )
    }

    private var canSplit: Bool { paneIDs.count < AppViewModel.maxPanesPerTab }

    /// The pane half of a terminal's right-click menu; Close comes after it.
    private func menuItems(for id: String) -> [TerminalMenuItem] {
        let splitHelp = canSplit ? "" : " (\(AppViewModel.maxPanesPerTab) panes max)"
        var items = [
            TerminalMenuItem(title: "Split Right" + splitHelp, symbol: "rectangle.split.2x1", key: "d", isEnabled: canSplit) {
                viewModel.splitPane(id, direction: "right")
            },
            TerminalMenuItem(title: "Split Down" + splitHelp, symbol: "rectangle.split.1x2", key: "d", modifiers: [.command, .shift], isEnabled: canSplit) {
                viewModel.splitPane(id, direction: "down")
            },
        ]
        if isSplit {
            let isZoomed = zoomed == id
            items.append(TerminalMenuItem(
                title: isZoomed ? "Restore Layout" : "Zoom Pane",
                symbol: isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                key: "m", modifiers: [.command, .shift]
            ) { viewModel.toggleZoom(id) })
        }
        return items
    }

    // MARK: Dividers

    private func endDrag(_ divider: PaneArrangement.Divider, moved: CGFloat) {
        let cellLength = divider.axis == .horizontal ? cellSize.width : cellSize.height
        let cells = Int((moved / cellLength).rounded())
        guard cells != 0 else {
            withAnimation(spring) { dragOffsets[divider.id] = nil }
            return
        }
        viewModel.resizePane(divider.paneToResize, direction: divider.axis == .horizontal ? "right" : "down", cells: cells)
        // If Hive refuses the move, don't leave the divider stranded.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if dragOffsets[divider.id] != nil {
                withAnimation(spring) { dragOffsets[divider.id] = nil }
            }
        }
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

// MARK: - Arrangement

/// Where each pane and divider of a layout sits within a rectangle.
private struct PaneArrangement {
    struct Divider: Identifiable {
        /// The split's path in the layout tree, e.g. `r.1.0`.
        let id: String
        let axis: HiveLayoutNode.Axis
        let rect: CGRect
        /// The pane `pane.resize` moves to drag this divider.
        let paneToResize: String
    }

    private(set) var panes: [String: CGRect] = [:]
    private(set) var dividers: [Divider] = []

    private static let minimumLength: CGFloat = 60

    init(node: HiveLayoutNode, in rect: CGRect, gap: CGFloat, offsets: [String: CGFloat]) {
        place(node, in: rect, path: "r", gap: gap, offsets: offsets)
    }

    private mutating func place(_ node: HiveLayoutNode, in rect: CGRect, path: String, gap: CGFloat, offsets: [String: CGFloat]) {
        switch node {
        case .pane(let id):
            panes[id] = rect
        case .split(let axis, let ratio, let first, let second):
            let isHorizontal = axis == .horizontal
            let available = max(0, (isHorizontal ? rect.width : rect.height) - gap)
            let minimum = min(Self.minimumLength, available / 2)
            let length = min(max(available * ratio + (offsets[path] ?? 0), minimum), available - minimum)

            let firstRect, dividerRect, secondRect: CGRect
            if isHorizontal {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: length, height: rect.height)
                dividerRect = CGRect(x: rect.minX + length, y: rect.minY, width: gap, height: rect.height)
                secondRect = CGRect(x: rect.minX + length + gap, y: rect.minY, width: available - length, height: rect.height)
            } else {
                firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: length)
                dividerRect = CGRect(x: rect.minX, y: rect.minY + length, width: rect.width, height: gap)
                secondRect = CGRect(x: rect.minX, y: rect.minY + length + gap, width: rect.width, height: available - length)
            }
            dividers.append(Divider(id: path, axis: axis, rect: dividerRect, paneToResize: first.paneOnTrailingEdge(axis)))
            place(first, in: firstRect, path: path + ".0", gap: gap, offsets: offsets)
            place(second, in: secondRect, path: path + ".1", gap: gap, offsets: offsets)
        }
    }
}

// MARK: - Divider

/// The gap between two panes. A grip shows on hover and while dragging; letting go asks Hive
/// to move the border, and the panes ease to wherever it lands.
private struct PaneDivider: View {
    let divider: PaneArrangement.Divider
    let onDrag: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var isHorizontal: Bool { divider.axis == .horizontal }
    private var isActive: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(isDragging ? Color.hiveAmber : Color.primary.opacity(isHovering ? 0.35 : 0))
                .frame(width: isHorizontal ? 3 : (isActive ? 44 : 24), height: isHorizontal ? (isActive ? 44 : 24) : 3)
        }
        // A wider grab area than the gap itself, as AppKit split views have.
        .frame(width: isHorizontal ? max(divider.rect.width, 10) : divider.rect.width,
               height: isHorizontal ? divider.rect.height : max(divider.rect.height, 10))
        .contentShape(Rectangle())
        .position(x: divider.rect.midX, y: divider.rect.midY)
        .onHover { inside in
            isHovering = inside
            if inside {
                (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    onDrag(isHorizontal ? value.translation.width : value.translation.height)
                }
                .onEnded { value in
                    isDragging = false
                    onEnd(isHorizontal ? value.translation.width : value.translation.height)
                }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragging)
        .zIndex(2)
    }
}

// MARK: - Pane controls

/// The glass pill on a hovered pane: split it either way, zoom it, or close it.
private struct PaneControls: View {
    let canSplit: Bool
    let canZoom: Bool
    let isZoomed: Bool
    let canClose: Bool
    let onSplitRight: () -> Void
    let onSplitDown: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Group {
                control("rectangle.split.2x1", help: canSplit ? "Split right  ⌘D" : Self.fullHelp, action: onSplitRight)
                control("rectangle.split.1x2", help: canSplit ? "Split down  ⇧⌘D" : Self.fullHelp, action: onSplitDown)
            }
            .disabled(!canSplit)
            if canZoom {
                control(isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: isZoomed ? "Restore layout  ⇧⌘M" : "Zoom pane  ⇧⌘M",
                        action: onZoom)
            }
            if canClose {
                Divider().frame(height: 12).opacity(0.4).padding(.horizontal, 2)
                control("xmark", help: "Close pane  ⌘W", action: onClose)
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private static let fullHelp = "A tab holds up to \(AppViewModel.maxPanesPerTab) panes"

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(PaneControlButtonStyle())
        .help(help)
    }
}

private struct PaneControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PaneControlButton(configuration: configuration)
    }

    private struct PaneControlButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: 24, height: 22)
                .background(Capsule().fill(Color.primary.opacity(isHovering && isEnabled ? 0.1 : 0)))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}
