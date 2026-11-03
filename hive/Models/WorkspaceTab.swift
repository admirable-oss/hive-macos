import Foundation

/// What a terminal tab runs.
enum WorkspaceDestination: Hashable, Codable {
    /// A login zsh in the environment's folder, or the home folder when there is none.
    case shell(environmentID: String?)
    /// `terminal.attach` to an agent the daemon runs.
    case agent(String)
}

struct WorkspaceTab: Identifiable, Hashable, Codable {
    var id = UUID()
    var destination: WorkspaceDestination
    /// Where a shell last was, so a relaunch reopens it there.
    var directory: String?
}
