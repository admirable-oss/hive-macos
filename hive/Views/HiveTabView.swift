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
    @Environment(\.colorScheme) private var colorScheme
    @State private var resizeTask: Task<Void, Never>?
    /// The layout on screen. It trails `tab.layout` so changes can be animated.
    @State private var layout: HiveLayoutNode?
    @State private var zoomed: String?
    /// How far each divider (by its path in the layout) has been dragged, until Hive answers.
    @State private var dragOffsets: [String: CGFloat] = [:]
    @State private var hoveredPane: String?
    /// A pane being dragged by its title strip, and where it would land.
    @State private var paneDrag: PaneDrag?

    private var cellSize: CGSize { TerminalSession.cellSize(scale: displayScale) }
    private var shownLayout: HiveLayoutNode? { layout ?? tab.layout }
    private var paneIDs: [String] { shownLayout?.paneIDs ?? [] }
    private var popups: [HivePopup] { tab.popups ?? [] }
    private var isSplit: Bool { paneIDs.count > 1 }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86) }

    /// Room around and between panes once a tab is split, tmux's borders as gaps.
    private var gap: CGFloat { isSplit ? 6 : 0 }

    private static let space = "hive-tab"

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
                        paneCard(id, isHidden: isHidden, arrangement: arrangement)
                            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(isHidden ? 0 : paneDrag?.paneID == id ? 0.55 : 1)
                            .scaleEffect(isHidden ? 0.97 : paneDrag?.paneID == id ? 0.985 : 1)
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
                    if let paneDrag {
                        dropPreview(paneDrag, in: arrangement)
                    }
                } else {
                    ProgressView()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                popupLayer(in: CGRect(origin: .zero, size: geometry.size))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(isSplit ? Color(nsColor: .windowBackgroundColor) : .clear)
            .coordinateSpace(name: Self.space)
            .onAppear { scheduleTabResize(for: geometry.size) }
            .onChange(of: geometry.size) { _, size in scheduleTabResize(for: size) }
        }
        .onAppear {
            layout = tab.layout
            zoomed = tab.zoomed
        }
        .onChange(of: tab.layout) { _, newLayout in
            // A pane hopping to a new place leaves the tab for a moment; keep it on screen until it lands.
            if let moving = viewModel.rearrangingPaneID, layout?.paneIDs.contains(moving) == true,
               newLayout?.paneIDs.contains(moving) != true {
                return
            }
            // Clear drags in the same transaction, so a divider eases from where it was let go.
            withAnimation(spring) {
                layout = newLayout
                dragOffsets = [:]
            }
        }
        .onChange(of: viewModel.rearrangingPaneID) { _, moving in
            if moving == nil, layout != tab.layout { withAnimation(spring) { layout = tab.layout } }
        }
        .onChange(of: tab.zoomed) { _, newZoomed in
            withAnimation(spring) { zoomed = newZoomed }
        }
    }

    // MARK: Panes

    private func paneCard(_ id: String, isHidden: Bool, arrangement: PaneArrangement) -> some View {
        let focused = viewModel.focusedPaneID == id
        let shape = RoundedRectangle(cornerRadius: isSplit ? 10 : 0, style: .continuous)
        // A popup covers the layout, so clicks there belong to it.
        let acceptsClicks = !isHidden && popups.isEmpty
        return VStack(spacing: 0) {
            if isSplit {
                PaneTitleStrip(
                    title: paneTitle(id),
                    isFocused: focused,
                    showsControls: hoveredPane == id && paneDrag == nil,
                    controls: controls(for: id),
                    onFocus: { if !focused { viewModel.focusPane(id) } },
                    onRename: { viewModel.renaming = .pane(id) }
                )
                .gesture(paneDragGesture(id, arrangement: arrangement))
            }
            pane(id, focused: focused, acceptsClicks: acceptsClicks)
        }
        .background(TerminalSurface.background(colorScheme))
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
            // One pane has no title strip, so its controls float over the terminal.
            if !isSplit && hoveredPane == id {
                controls(for: id)
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

    private func controls(for id: String) -> PaneControls {
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
    }

    private func pane(_ id: String, focused: Bool, acceptsClicks: Bool, isPopup: Bool = false) -> some View {
        let session = terminals.paneSession(id, viewModel: viewModel)
        return TerminalSurface(
            session: session,
            isFocused: focused,
            showsFocusRing: false,
            acceptsClicks: acceptsClicks,
            menuItems: isPopup ? [] : menuItems(for: id),
            onFocus: { if !focused { viewModel.focusPane(id) } },
            onClose: { viewModel.requestClosePane(id) }
        )
    }

    private func paneTitle(_ id: String) -> String {
        let name = viewModel.workspace.panes[id]?.name ?? ""
        return name.isEmpty ? "Pane \((paneIDs.firstIndex(of: id) ?? 0) + 1)" : name
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

        items.append(TerminalMenuItem(title: "Rename Pane…", symbol: "pencil", key: "r", modifiers: [.command, .option], startsGroup: true) {
            viewModel.renaming = .pane(id)
        })
        if isSplit {
            let others = paneIDs.filter { $0 != id }
            items.append(TerminalMenuItem(
                title: "Swap With",
                symbol: "arrow.left.arrow.right",
                children: others.map { other in TerminalMenuItem(title: paneTitle(other)) { viewModel.swapPanes(id, with: other) } }
            ))
        }
        items.append(moveMenu(for: id))
        items.append(TerminalMenuItem(title: "Open Popup Shell", symbol: "macwindow.on.rectangle", key: "p", modifiers: [.command, .option], startsGroup: true) {
            viewModel.openPopup()
        })
        return items
    }

    /// Move to another tab, a new tab, or a new tab in another environment.
    private func moveMenu(for id: String) -> TerminalMenuItem {
        let environments = viewModel.environments
        let tabs = viewModel.moveDestinations(for: id).map { destination in
            let environment = environments.first(where: { $0.id == destination.environmentID })?.name ?? destination.environmentID
            return TerminalMenuItem(title: "\(destination.name) · \(environment)") {
                viewModel.movePane(id, toTab: destination.id)
            }
        }
        let home = viewModel.workspace.panes[id]?.environmentID
        let elsewhere = environments.filter { $0.id != home }.map { environment in
            TerminalMenuItem(title: environment.name) { viewModel.movePaneToNewTab(id, environmentID: environment.id) }
        }
        var children = [TerminalMenuItem(title: "New Tab", symbol: "plus.rectangle", isEnabled: isSplit) {
            viewModel.movePaneToNewTab(id)
        }]
        if !tabs.isEmpty {
            children.append(TerminalMenuItem(title: "Tab", startsGroup: true, children: tabs))
        }
        if !elsewhere.isEmpty {
            children.append(TerminalMenuItem(title: "New Tab in Environment", children: elsewhere))
        }
        return TerminalMenuItem(title: "Move To", symbol: "rectangle.portrait.and.arrow.right", children: children)
    }

    // MARK: Dragging panes

    /// Where a dragged pane would land: on another pane to swap, or against one of its edges to move beside it.
    struct PaneDrag: Equatable {
        enum Zone: String { case swap, left, right, up, down }

        let paneID: String
        var location: CGPoint
        var target: String?
        var zone: Zone = .swap
    }

    private func paneDragGesture(_ id: String, arrangement: PaneArrangement) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                var drag = paneDrag ?? PaneDrag(paneID: id, location: value.location)
                drag.location = value.location
                let landing = Self.landing(at: value.location, dragging: id, in: arrangement)
                if landing.target != drag.target || landing.zone != drag.zone {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                        drag.target = landing.target
                        drag.zone = landing.zone
                        paneDrag = drag
                    }
                } else {
                    paneDrag = drag
                }
            }
            .onEnded { _ in
                defer { withAnimation(spring) { paneDrag = nil } }
                guard let drag = paneDrag, let target = drag.target else { return }
                if drag.zone == .swap {
                    viewModel.swapPanes(id, with: target)
                } else {
                    viewModel.movePane(id, toTab: tab.id, nextTo: target, direction: drag.zone.rawValue)
                }
            }
    }

    private static func landing(at point: CGPoint, dragging: String, in arrangement: PaneArrangement) -> (target: String?, zone: PaneDrag.Zone) {
        guard let hit = arrangement.panes.first(where: { $0.key != dragging && $0.value.contains(point) }) else {
            return (nil, .swap)
        }
        let id = hit.key, rect = hit.value
        let x = (point.x - rect.minX) / max(rect.width, 1)
        let y = (point.y - rect.minY) / max(rect.height, 1)
        let edges: [(PaneDrag.Zone, CGFloat)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        // The outer quarter on each side moves the pane there; the middle swaps.
        if let nearest = edges.min(by: { $0.1 < $1.1 }), nearest.1 < 0.25 { return (id, nearest.0) }
        return (id, .swap)
    }

    @ViewBuilder
    private func dropPreview(_ drag: PaneDrag, in arrangement: PaneArrangement) -> some View {
        if let target = drag.target, let rect = arrangement.panes[target] {
            let area = Self.previewRect(rect, zone: drag.zone)
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            shape
                .fill(Color.hiveAmber.opacity(0.16))
                .overlay(shape.strokeBorder(Color.hiveAmber.opacity(0.7), lineWidth: 1.5))
                .overlay {
                    Label(drag.zone == .swap ? "Swap" : "Move here", systemImage: drag.zone == .swap ? "arrow.left.arrow.right" : "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                }
                .frame(width: area.width, height: area.height)
                .position(x: area.midX, y: area.midY)
                .allowsHitTesting(false)
                .zIndex(3)
                .transition(.opacity)
        }
        Text(paneTitle(drag.paneID))
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hiveAmber.opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .position(x: drag.location.x, y: drag.location.y - 14)
            .allowsHitTesting(false)
            .zIndex(4)
    }

    private static func previewRect(_ rect: CGRect, zone: PaneDrag.Zone) -> CGRect {
        let inset = rect.insetBy(dx: 4, dy: 4)
        switch zone {
        case .swap: return inset
        case .left: return CGRect(x: inset.minX, y: inset.minY, width: inset.width / 2, height: inset.height)
        case .right: return CGRect(x: inset.midX, y: inset.minY, width: inset.width / 2, height: inset.height)
        case .up: return CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height / 2)
        case .down: return CGRect(x: inset.minX, y: inset.midY, width: inset.width, height: inset.height / 2)
        }
    }

    // MARK: Popups

    /// Floating panes over the tab, with the layout dimmed behind them; the last one is on top.
    private func popupLayer(in area: CGRect) -> some View {
        ZStack {
            if !popups.isEmpty {
                Color.black.opacity(0.32)
                    .contentShape(Rectangle())
                    // Clicking beside a popup keeps the keyboard in it.
                    .onTapGesture { if let top = popups.last { viewModel.focusPane(top.pane) } }
                    .transition(.opacity)
            }
            ForEach(popups, id: \.pane) { popup in
                let width = area.width * CGFloat(min(max(popup.widthPercent, 20), 100)) / 100
                let height = area.height * CGFloat(min(max(popup.heightPercent, 20), 100)) / 100
                let focused = viewModel.focusedPaneID == popup.pane
                PopupCard(
                    title: viewModel.workspace.panes[popup.pane]?.name ?? "Popup",
                    isFocused: focused,
                    onClose: { viewModel.requestClosePane(popup.pane) }
                ) {
                    pane(popup.pane, focused: focused, acceptsClicks: true, isPopup: true)
                }
                .frame(width: width, height: height)
                .position(x: area.midX, y: area.midY)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .frame(width: area.width, height: area.height)
        .zIndex(10)
        .animation(spring, value: popups.map(\.pane))
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

// MARK: - Title strip

/// The slim bar above each pane of a split tab: its name, a handle to drag it somewhere else,
/// and its controls while the pointer is over it. Double-click the name to rename the pane.
private struct PaneTitleStrip: View {
    let title: String
    let isFocused: Bool
    let showsControls: Bool
    let controls: PaneControls
    let onFocus: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 11, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(isFocused ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if showsControls {
                controls
                    .scaleEffect(0.86, anchor: .trailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(Color.primary.opacity(isFocused ? 0.05 : 0.025))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onRename)
        .simultaneousGesture(TapGesture().onEnded(onFocus))
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .help("Drag to swap or move · double-click to rename")
    }
}

// MARK: - Popup

/// A floating pane: a rounded card with its name and a close button above the terminal.
private struct PopupCard<Content: View>: View {
    let title: String
    let isFocused: Bool
    let onClose: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.hiveAmber)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(PaneControlButtonStyle())
                    .help("Close popup  ⌘W")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(.bar)
            content
        }
        .background(TerminalSurface.background(colorScheme))
        .clipShape(shape)
        .overlay(shape.strokeBorder(isFocused ? Color.hiveAmber.opacity(0.55) : Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
    }
}

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
