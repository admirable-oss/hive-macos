import SwiftUI

extension Color {
    /// Hive's brand amber. Read from the asset directly so it stays amber even
    /// when the user has picked a different system accent color.
    static let hiveAmber = Color("AccentColor")
}

func agentStateColor(_ state: String) -> Color {
    switch state {
    case "working": .hiveAmber
    case "blocked": .red
    case "done": .blue
    case "idle": .secondary
    case "unknown": .secondary
    case "exited": .secondary
    default: .secondary
    }
}

func agentStateTitle(_ state: String) -> String {
    switch state {
    case "working": "Running"
    case "blocked": "Needs you"
    case "done": "Finished"
    case "idle": "Ready"
    case "unknown": "Checking"
    case "exited": "Closed"
    default: state.capitalized
    }
}

struct AgentProviderIcon: View {
    let kind: String
    var size: CGFloat = 12

    private var provider: String {
        kind.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private var symbol: String {
        if provider.contains("claude") { return "sparkles" }
        if provider.contains("codex") { return "cpu.fill" }
        if provider.contains("opencode") { return "chevron.left.forwardslash.chevron.right" }
        if provider.contains("gemini") { return "sparkle" }
        if provider.contains("copilot") { return "airplane" }
        if provider.contains("aider") { return "hammer.fill" }
        return "terminal.fill"
    }

    private var tint: Color {
        if provider.contains("claude") { return Color(red: 0.87, green: 0.42, blue: 0.22) }
        if provider.contains("codex") { return Color(red: 0.20, green: 0.66, blue: 0.48) }
        if provider.contains("opencode") { return Color(red: 0.48, green: 0.55, blue: 0.92) }
        if provider.contains("gemini") || provider.contains("copilot") { return Color(red: 0.34, green: 0.56, blue: 0.91) }
        if provider.contains("aider") { return Color(red: 0.72, green: 0.60, blue: 0.30) }
        return .secondary
    }

    var body: some View {
        ZStack {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 20, height: 20)
        .accessibilityLabel(kind)
        .help(kind.capitalized)
    }
}

// MARK: - M7 Sidebar Enhancements

struct EnvironmentAvatar: View {
    let name: String
    var size: CGFloat = 20

    private var initial: String {
        String(name.prefix(1)).uppercased()
    }

    private var backgroundColor: Color {
        let colors: [Color] = [
            .blue, .purple, .orange, .pink, .indigo, .mint, .teal, .cyan
        ]
        let index = abs(name.hashValue) % colors.count
        return colors[index]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor.gradient)
            Text(initial)
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

struct StatusIndicator: View {
    enum IndicatorState {
        case ready
        case processing
        case idle
        case needsAttention
    }

    let state: IndicatorState

    @State private var rotation: Double = 0

    var body: some View {
        Group {
            switch state {
            case .ready:
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            case .processing:
                Circle()
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1.5)
                    .overlay(
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(Color.blue, lineWidth: 1.5)
                            .rotationEffect(.degrees(rotation))
                    )
                    .frame(width: 9, height: 9)
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            case .idle:
                Circle()
                    .stroke(Color.secondary.opacity(0.6), lineWidth: 1.2)
                    .frame(width: 7, height: 7)
            case .needsAttention:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct NeedsYouBadge: View {
    var body: some View {
        Text("Needs you")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
            )
    }
}

func formatAgentTime(_ since: String?) -> String {
    guard let since, let date = ISO8601DateFormatter().date(from: since) else { return "" }
    let diff = Date().timeIntervalSince(date)
    if diff < 60 { return "<1m" }
    if diff < 3600 { return "\(Int(diff / 60))m" }
    if diff < 86400 { return "\(Int(diff / 3600))h" }
    return "\(Int(diff / 86400))d"
}

// MARK: - Design kit
//
// The pieces every Hive surface is built from, so sheets, panels and popovers read as one app:
// an amber badge, rounded headers, quiet glass cards, capsule buttons and soft fields.

/// The amber tile a header opens with.
struct HiveBadgeIcon: View {
    let symbol: String
    var size: CGFloat = 24
    var tint: Color = .hiveAmber

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(tint.gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.3), radius: 3, y: 1)
    }
}

/// A sheet's title row: badge, title and subtitle, its own controls, and a round close button
/// that also answers Escape.
struct HiveSheetHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var onClose: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            HiveBadgeIcon(symbol: symbol, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 12)
            trailing
            if let onClose {
                HiveCloseButton(action: onClose)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

extension HiveSheetHeader where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, onClose: onClose) { EmptyView() }
    }
}

/// The small round ✕ used to dismiss sheets, Overview and Inbox.
struct HiveCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .buttonStyle(HiveIconButtonStyle())
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

/// A section's label, in the sidebar's voice: small, semibold, a little tracked.
struct HiveSectionTitle: View {
    let title: String
    var symbol: String?
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.5)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A small capsule label: a state, a count, a machine name.
struct HiveChip: View {
    let text: String
    var tint: Color?
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.14)))
    }
}

/// An inline message: an error, a success, or a note.
struct HiveNotice: View {
    enum Kind { case error, success, info }

    let text: String
    var kind: Kind = .error

    private var tint: Color {
        switch kind {
        case .error: .red
        case .success: .green
        case .info: .secondary
        }
    }

    private var symbol: String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(kind == .info ? Color.secondary : tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(kind == .info ? 0.06 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(kind == .info ? 0.08 : 0.2), lineWidth: 0.5))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: Cards

extension View {
    /// A quiet rounded card. `interactive` lifts it a little on hover; `tint` colours it.
    func hiveCard(padding: CGFloat = 12, tint: Color? = nil, interactive: Bool = false, isSelected: Bool = false) -> some View {
        modifier(HiveCardModifier(padding: padding, tint: tint, interactive: interactive, isSelected: isSelected))
    }
}

private struct HiveCardModifier: ViewModifier {
    let padding: CGFloat
    let tint: Color?
    let interactive: Bool
    let isSelected: Bool

    @State private var isHovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var fill: Color {
        if isSelected { return Color.hiveAmber.opacity(0.14) }
        if let tint { return tint.opacity(isHovering ? 0.12 : 0.08) }
        return Color.primary.opacity(isHovering ? 0.06 : 0.035)
    }

    private var stroke: Color {
        if isSelected { return Color.hiveAmber.opacity(0.35) }
        if let tint { return tint.opacity(0.22) }
        return Color.primary.opacity(isHovering ? 0.1 : 0.06)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 0.5))
            .contentShape(shape)
            .onHover { if interactive { isHovering = $0 } }
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isHovering)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSelected)
    }
}

// MARK: Buttons

/// Capsule buttons. `.primary` is the amber call to action; `.secondary` is everything else and
/// turns red by itself for a destructive role.
struct HiveButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }

    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        HiveButton(configuration: configuration, kind: kind, compact: compact)
    }

    private struct HiveButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var isDestructive: Bool { configuration.role == .destructive }

        var body: some View {
            configuration.label
                .labelStyle(HiveButtonLabelStyle())
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 4 : 6.5)
                .background {
                    switch kind {
                    case .primary:
                        Capsule()
                            .fill((isDestructive ? Color.red : Color.hiveAmber).gradient)
                            .brightness(isHovering ? 0.04 : 0)
                            .shadow(color: (isDestructive ? Color.red : Color.hiveAmber).opacity(isEnabled ? 0.28 : 0), radius: 3, y: 1)
                    case .secondary:
                        Capsule()
                            .fill((isDestructive ? Color.red : Color.primary).opacity(isHovering ? 0.12 : 0.065))
                    }
                }
                .overlay {
                    if kind == .secondary {
                        Capsule().strokeBorder((isDestructive ? Color.red : Color.primary).opacity(0.06), lineWidth: 0.5)
                    }
                }
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { isHovering = $0 && isEnabled }
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isHovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .white
            case .secondary: isDestructive ? .red : (isHovering ? .primary : Color.primary.opacity(0.82))
            }
        }
    }
}

/// Icon and title close together, the icon a touch smaller.
private struct HiveButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == HiveButtonStyle {
    static var hive: HiveButtonStyle { HiveButtonStyle() }
    static var hivePrimary: HiveButtonStyle { HiveButtonStyle(kind: .primary) }
    static var hiveCompact: HiveButtonStyle { HiveButtonStyle(compact: true) }
    static var hivePrimaryCompact: HiveButtonStyle { HiveButtonStyle(kind: .primary, compact: true) }
}

/// A small round glass button for icons: reload, close, open, stage.
struct HiveIconButtonStyle: ButtonStyle {
    var size: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        HiveIconButton(configuration: configuration, size: size)
    }

    private struct HiveIconButton: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.12 : 0.06)))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { isHovering = $0 && isEnabled }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }
}

// MARK: Fields

/// A soft rounded field whose outline turns amber while you type in it.
struct HiveTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        HiveFieldBox(field: configuration)
    }
}

private struct HiveFieldBox<Field: View>: View {
    let field: Field
    @FocusState private var isFocused: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        field
            .font(.system(size: 12.5))
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(shape.fill(Color.primary.opacity(isFocused ? 0.07 : 0.045)))
            .overlay(shape.strokeBorder(isFocused ? Color.hiveAmber.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: isFocused ? 1 : 0.5))
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

extension TextFieldStyle where Self == HiveTextFieldStyle {
    static var hive: HiveTextFieldStyle { HiveTextFieldStyle() }
}

// MARK: Segmented control

/// A capsule segmented control whose selection slides between options, as Inbox's filter does.
struct HiveSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var symbol: ((Value) -> String)?

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol { Image(systemName: symbol(option)).imageScale(.small) }
                        Text(title(option))
                    }
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                                .matchedGeometryEffect(id: "segment", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5))
    }
}

// MARK: Form sheets

/// A small form sheet: header, fields, and a footer with Cancel and one amber action.
/// Return submits and Escape cancels.
struct HiveFormSheet<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let actionTitle: String
    var actionSymbol = "checkmark"
    var canSubmit = true
    var width: CGFloat = 460
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HiveSheetHeader(symbol: symbol, title: title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .font(.system(size: 12.5))
            .padding(20)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.hive)
                    .keyboardShortcut(.cancelAction)
                Button(action: onSubmit) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .buttonStyle(.hivePrimary)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.025))
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: width)
    }
}

/// A label above a field, for form sheets.
struct HiveFieldLabel<Field: View>: View {
    let title: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            field
        }
    }
}
