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
                .padding(.horizontal, 2)
            }
            .onChange(of: activeID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .frame(minWidth: 120, idealWidth: 560, maxWidth: .infinity)
        .frame(height: 32)
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Text(">_")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isActive ? Color.hiveAmber : Color.secondary)
                    Text("\(number)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel("Tab \(number), \(title)")
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isActive || isHovering ? 1 : 0)
                .help("Close tab")
                .accessibilityLabel("Close tab \(number)")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background {
            shape.fill(Color.primary.opacity(isActive ? 0.07 : (isHovering ? 0.04 : 0)))
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isActive ? 0.12 : 0), lineWidth: 1)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// Flat toolbar control: secondary until hovered, filled while active.
struct ToolbarPillButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarPill(configuration: configuration, isActive: isActive)
    }

    private struct ToolbarPill: View {
        let configuration: ButtonStyleConfiguration
        let isActive: Bool
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive || isHovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(minWidth: 28, minHeight: 28)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isActive ? 0.09 : (configuration.isPressed ? 0.07 : (isHovering ? 0.04 : 0))))
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
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
