import SwiftUI

struct WorkspaceTabBar: View {
    struct Item: Identifiable {
        let id: WorkspaceTab.ID
        let title: String
        /// The tab's name, shown next to its number when it has one.
        var label: String?
    }

    let items: [Item]
    @Binding var activeID: WorkspaceTab.ID?
    /// The tab whose name is being edited in place.
    @Binding var renamingID: WorkspaceTab.ID?
    let onRename: (WorkspaceTab.ID, String) -> Void
    let onClose: (WorkspaceTab.ID) -> Void
    let onCloseOthers: (WorkspaceTab.ID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        WorkspaceTabButton(
                            number: index + 1,
                            title: item.title,
                            label: item.label,
                            isActive: item.id == activeID,
                            isRenaming: renamingID == item.id,
                            canClose: true,
                            select: { activeID = item.id },
                            startRename: { activeID = item.id; renamingID = item.id },
                            finishRename: { name in
                                if let name { onRename(item.id, name) }
                                renamingID = nil
                            },
                            close: { onClose(item.id) }
                        )
                        .id(item.id)
                        .contextMenu {
                            Button("Rename Tab…") { activeID = item.id; renamingID = item.id }
                            Divider()
                            Button("Close Tab") { onClose(item.id) }
                            Button("Close Other Tabs") { onCloseOthers(item.id) }
                                .disabled(items.count < 2)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .frame(minWidth: 80, idealWidth: 240, maxWidth: .infinity)
        .frame(height: 32)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .opacity(0.4)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        }
    }
}

private struct WorkspaceTabButton: View {
    let number: Int
    let title: String
    let label: String?
    let isActive: Bool
    let isRenaming: Bool
    let canClose: Bool
    let select: () -> Void
    let startRename: () -> Void
    /// The new name, or nil when the edit was cancelled.
    let finishRename: (String?) -> Void
    let close: () -> Void

    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(">_")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.hiveAmber : Color.secondary)
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
                if isRenaming {
                    TextField("Tab name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 120)
                        .focused($fieldFocused)
                        .onSubmit { finishRename(draft) }
                        .onExitCommand { finishRename(nil) }
                        .onChange(of: fieldFocused) { _, focused in
                            // Clicking elsewhere keeps what was typed, as Finder does.
                            if !focused && isRenaming { finishRename(draft) }
                        }
                        .onAppear {
                            draft = label ?? ""
                            DispatchQueue.main.async { fieldFocused = true }
                        }
                } else if let label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 12, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 110, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: startRename)
            .simultaneousGesture(TapGesture().onEnded { if !isRenaming { select() } })
            .help("\(title) — double-click to rename")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel("Tab \(number)\(label.map { ", \($0)" } ?? "")")
            .accessibilityAction(.default, select)
            .accessibilityAction(named: "Rename", startRename)

            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .opacity(isActive || isHovering ? 0.6 : 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            ZStack {
                if isActive {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
            }
        }
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.spring(duration: 0.2), value: isActive)
        .animation(.spring(duration: 0.2), value: isHovering)
    }
}

/// Glassmorphic toolbar control: ultra-thin material while active, subtle hover.
struct ToolbarPillButtonStyle: ButtonStyle {
    var isActive = false
    var color: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        ToolbarPill(configuration: configuration, isActive: isActive, color: color)
    }

    private struct ToolbarPill: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        let color: Color
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? color : (isHovering ? color : color.opacity(0.7)))
                .padding(.horizontal, 8)
                .frame(minHeight: 24)
                .background {
                    ZStack {
                        if isActive {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.05), radius: 1, y: 0.5)
                        } else if isHovering {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        }
                    }
                }
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.spring(duration: 0.2), value: isActive)
                .animation(.spring(duration: 0.2), value: isHovering)
        }
    }
}

extension ToolbarContent {
    /// Drops the Liquid Glass capsule macOS 26 draws behind toolbar items, so custom-styled controls sit flat.
    @ToolbarContentBuilder
    func flatToolbarBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
