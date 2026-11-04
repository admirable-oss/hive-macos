import SwiftUI

struct WorkspaceTabBar: View {
    struct Item: Identifiable {
        let id: WorkspaceTab.ID
        let title: String
    }

    let items: [Item]
    @Binding var activeID: WorkspaceTab.ID?
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
                            isActive: item.id == activeID,
                            canClose: true,
                            select: { activeID = item.id },
                            close: { onClose(item.id) }
                        )
                        .id(item.id)
                        .contextMenu {
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
    let isActive: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Text(">_")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(isActive ? Color.hiveAmber : Color.secondary)
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)

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
