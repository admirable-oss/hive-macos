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
    var size: CGFloat = 11

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
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
            .accessibilityLabel(kind)
            .help(kind.capitalized)
    }
}
