import Foundation

// The daemon's workspace as `api.snapshot` and the event stream describe it.
// Only the fields the app uses are decoded; unknown fields are ignored so newer
// daemons keep working.

struct HiveTab: Decodable, Identifiable, Hashable {
    let id: String
    let environmentID: String
    let name: String
    let active: Bool?
    /// The focused pane's ID.
    let focused: String?
    /// The zoomed pane's ID, when one fills the tab.
    let zoomed: String?
    let layout: HiveLayoutNode?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, active, focused, zoomed, layout, width, height
        case environmentID = "environment_id"
    }

    var paneIDs: [String] { layout?.paneIDs ?? [] }
}

/// How a tab's panes are arranged: a binary tree of splits whose leaves are panes.
indirect enum HiveLayoutNode: Decodable, Hashable {
    enum Axis: Hashable {
        /// Side by side; the first child is on the left.
        case horizontal
        /// Stacked; the first child is on top.
        case vertical
    }

    case pane(String)
    /// `ratio` is the first child's share of the space.
    case split(Axis, ratio: Double, first: HiveLayoutNode, second: HiveLayoutNode)

    private enum CodingKeys: String, CodingKey {
        case pane, split, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let pane = try container.decodeIfPresent(String.self, forKey: .pane) {
            self = .pane(pane)
            return
        }
        let split = try container.decode(String.self, forKey: .split)
        self = .split(
            split == "vertical" ? .vertical : .horizontal,
            ratio: try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5,
            first: try container.decode(HiveLayoutNode.self, forKey: .first),
            second: try container.decode(HiveLayoutNode.self, forKey: .second)
        )
    }

    var paneIDs: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    /// The pane in this subtree whose border lies on its trailing edge along `axis`:
    /// the one `pane.resize` should move to drag the divider after this subtree.
    func paneOnTrailingEdge(_ axis: Axis) -> String {
        switch self {
        case .pane(let id): id
        case .split(let splitAxis, _, let first, let second):
            splitAxis == axis ? second.paneOnTrailingEdge(axis) : first.paneOnTrailingEdge(axis)
        }
    }
}

struct HivePane: Decodable, Identifiable, Hashable {
    let id: String
    let tabID: String
    let environmentID: String
    let processID: String
    let name: String?
    let focused: Bool?
    let zoomed: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, focused, zoomed
        case tabID = "tab_id"
        case environmentID = "environment_id"
        case processID = "process_id"
    }
}

struct HiveProcess: Decodable, Identifiable, Hashable {
    let id: String
    let environmentID: String
    let command: String
    let workingDirectory: String
    let pid: Int
    let status: String
    let terminal: Bool
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case id, command, pid, status, terminal
        case environmentID = "environment_id"
        case workingDirectory = "working_dir"
        case exitCode = "exit_code"
    }
}

struct HiveDaemonInfo: Decodable, Hashable {
    let status: String
    let version: String
    let protocolVersion: String
    let apiLevel: Int
    let session: String

    enum CodingKeys: String, CodingKey {
        case status, version, session
        case protocolVersion = "protocol_version"
        case apiLevel = "api_level"
    }
}

struct HiveAPISnapshot: Decodable {
    let daemon: HiveDaemonInfo
    let environments: [HiveEnvironment]
    let tabs: [HiveTab]
    let panes: [HivePane]
    let processes: [HiveProcess]
    let agents: [HiveAgent]
}

struct HiveTerminalView: Decodable {
    let viewID: String
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case width, height
        case viewID = "view_id"
    }
}

struct HiveAgentStarted: Decodable {
    let agent: HiveAgent
    let tab: HiveTab
    let pane: HivePane
}

struct HiveTabCreated: Decodable {
    let tab: HiveTab
    let pane: HivePane
}

/// `agent.explain`: why the agent is in its state.
struct HiveAgentExplanation: Decodable {
    struct Verdict: Decodable {
        let state: String
        /// Index of the manifest rule that matched.
        let rule: Int
        let description: String?
        /// The screen text the rule matched.
        let text: String?
    }

    let agent: HiveAgent
    let detected: String?
    let manifest: String?
    let screen: [String]?
    let verdict: Verdict?
}

struct HivePromptResult: Decodable {
    let outcome: String
    let agent: HiveAgent
    let output: [String]?
}

struct HiveImageReceipt: Decodable {
    let delivery: String
    let path: String?
    let done: Bool?
}

/// `environment.git` carries only the environment's ID and its new git status.
struct HiveEnvironmentGitUpdate: Decodable {
    let id: String
    let git: HiveGitStatus?
}

struct HiveIDPayload: Decodable {
    let id: String
}
