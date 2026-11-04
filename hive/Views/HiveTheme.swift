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
