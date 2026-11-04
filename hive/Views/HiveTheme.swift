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
