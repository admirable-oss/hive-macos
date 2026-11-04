import Foundation

/// What a desktop tab shows.
enum WorkspaceDestination: Hashable, Codable {
    /// One of the daemon's tabs, with its panes; shared with the TUI and any other client.
    case hive(tabID: String)
    /// A remote agent's terminal, attached through `hive --machine … agent attach`.
    case remote(machine: String, agentID: String, title: String)
    /// An interactive SSH login to a saved machine.
    case remoteShell(machine: String, host: String)
    /// A local login shell outside any environment. Only this window knows about it.
    case scratch
}

struct WorkspaceTab: Identifiable, Hashable, Codable {
    var id = UUID()
    var destination: WorkspaceDestination
    /// Where a scratch shell last was, so a relaunch reopens it there.
    var directory: String?

    var hiveTabID: String? {
        if case .hive(let id) = destination { return id }
        return nil
    }
}
