import Foundation

// The daemon's workspace as `api.snapshot` and the event stream describe it.
// Only the fields the app uses are decoded; unknown fields are ignored so newer
// daemons keep working.

struct HiveTab: Decodable, Identifiable, Hashable {
    let id: String
    let environmentID: String
    let name: String
    let active: Bool?
    /// The focused pane's ID. The desktop moves it ahead of Hive's answer so a click lands at once.
    var focused: String?
    /// The zoomed pane's ID, when one fills the tab.
    let zoomed: String?
    let layout: HiveLayoutNode?
    /// Floating panes over the tab, outside its layout; the last is on top.
    let popups: [HivePopup]?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, active, focused, zoomed, layout, popups, width, height
        case environmentID = "environment_id"
    }

    var paneIDs: [String] { layout?.paneIDs ?? [] }
    var popupPaneIDs: [String] { popups?.map(\.pane) ?? [] }
}

/// A floating pane over a tab, sized in percent of it (`pane.popup`).
struct HivePopup: Decodable, Hashable {
    let pane: String
    let widthPercent: Int
    let heightPercent: Int

    enum CodingKeys: String, CodingKey {
        case pane
        case widthPercent = "width_pct"
        case heightPercent = "height_pct"
    }
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
    let popup: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, focused, zoomed, popup
        case tabID = "tab_id"
        case environmentID = "environment_id"
        case processID = "process_id"
    }
}

struct HiveProcess: Decodable, Identifiable, Hashable {
    let id: String
    let environmentID: String
    let command: String
    let args: [String]?
    let workingDirectory: String
    let pid: Int
    let status: String
    let terminal: Bool
    let exitCode: Int?
    let startedAt: String?
    let endedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, command, args, pid, status, terminal
        case environmentID = "environment_id"
        case workingDirectory = "working_dir"
        case exitCode = "exit_code"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    var isRunning: Bool { status == "running" }

    /// The command as typed: an `env K=V… sh -lc "…"` wrapper shows just what it runs.
    var commandLine: String {
        let args = args ?? []
        if let flag = args.firstIndex(where: { $0 == "-lc" || $0 == "-c" }), flag + 1 < args.count {
            return args[flag + 1]
        }
        return ([command] + args).joined(separator: " ")
    }
}

/// Titles and tokens a pane or environment reports (`hive pane report-metadata`), shown beside it.
struct HiveMetadataEntry: Decodable, Hashable {
    struct Token: Decodable, Hashable {
        let key: String
        let text: String
        let until: String?
    }

    let environment: String?
    let pane: String?
    let title: String?
    let titleUntil: String?
    let tokens: [Token]

    enum CodingKeys: String, CodingKey {
        case environment, pane, title, tokens
        case titleUntil = "title_until"
    }

    /// `pane:<id>` or `environment:<id>`.
    var key: String {
        if let pane { return "pane:\(pane)" }
        return "environment:\(environment ?? "")"
    }
}

/// One checkout of a repository (`hive worktree list`).
struct HiveWorktreeInfo: Decodable, Hashable, Identifiable {
    let path: String
    let branch: String?
    let head: String?
    let main: Bool?
    let bare: Bool?
    let detached: Bool?
    let locked: Bool?
    /// The environments rooted in it.
    let environments: [String]?

    var id: String { path }
}

struct HiveObserverActivity: Decodable {
    struct Observer: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let connections: Int
    }

    let observers: [Observer]
    /// Watchers per watched thing.
    let watched: [String: Int]
}

struct HiveObserverValidation: Decodable {
    struct Credential: Decodable {
        let id: String
        let name: String
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case expiresAt = "expires_at"
        }
    }

    let valid: Bool
    let state: String
    let credential: Credential?
}

/// The daemon itself (`runtime.status`).
struct HiveRuntimeStatus: Decodable, Hashable {
    let status: String
    let socket: String
    let startedAt: String
    let pid: Int
    let version: String
    let protocolVersion: String
    let apiLevel: Int
    let agentsSurviveRestart: Bool
    let session: String?

    enum CodingKeys: String, CodingKey {
        case status, socket, pid, version, session
        case startedAt = "started_at"
        case protocolVersion = "protocol_version"
        case apiLevel = "api_level"
        case agentsSurviveRestart = "agents_survive_restart"
    }
}

/// The daemon's resource use (`debug.stats`).
struct HiveDebugStats: Decodable, Hashable {
    let goroutines: Int
    let openFiles: Int
    let heapAlloc: Int
    let heapSys: Int
    let numGC: Int
    let uptimeSeconds: Double

    enum CodingKeys: String, CodingKey {
        case goroutines
        case openFiles = "open_fds"
        case heapAlloc = "heap_alloc"
        case heapSys = "heap_sys"
        case numGC = "num_gc"
        case uptimeSeconds = "uptime_seconds"
    }
}

/// A terminal's screen as text, with what scrolled off it (`terminal.snapshot`); oldest first.
struct HiveTerminalSnapshot: Decodable {
    let width: Int
    let height: Int
    let lines: [String]
    let scrollback: [String]?
}

/// How an `agent.wait` ended: reached, timeout, blocked, stalled or exited.
struct HiveAgentWaitResult: Decodable {
    let outcome: String
    let agent: HiveAgent
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

struct HiveAgentList: Decodable {
    let agents: [HiveAgent]
}

struct HiveTaskSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let state: String
    let rev: UInt64
    let total: Int
}

struct HiveTaskPlan: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let state: String
    let rev: UInt64
    let tasks: [HiveTask]
    let reason: String?
}

struct HiveTask: Decodable, Identifiable, Hashable {
    let spec: HiveTaskSpec
    let state: String
    let attempt: Int?
    let agentID: String?
    let paneID: String?
    let environmentID: String?
    let path: String?
    let reason: String?
    let result: HiveTaskResult?

    var id: String { spec.id }

    enum CodingKeys: String, CodingKey {
        case spec, state, attempt, reason, path, result
        case agentID = "agent_id"
        case paneID = "pane_id"
        case environmentID = "environment_id"
    }
}

struct HiveTaskSpec: Decodable, Hashable {
    let id: String
    let title: String?
    let prompt: String?
    let needs: [String]?
    let environmentID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, prompt, needs
        case environmentID = "environment_id"
    }
}

struct HiveTaskResult: Decodable, Hashable {
    let outcome: String
    let summary: String?
    let changed: [String]?
    let screen: [String]?
}

struct HiveObserverCredential: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let screens: Bool
    let expiresAt: String
    let lastUsedAt: String?
    let connections: Int?
    let scope: HiveObserverScope

    enum CodingKeys: String, CodingKey {
        case id, name, state, screens, scope, connections
        case expiresAt = "expires_at"
        case lastUsedAt = "last_used_at"
    }
}

struct HiveObserverScope: Decodable, Hashable {
    let all: Bool?
    let environments: [String]?
    let panes: [String]?
}

struct HiveObserverList: Decodable {
    let socket: String
    let enabled: Bool
    let credentials: [HiveObserverCredential]
}

struct HiveObserverCreated: Decodable {
    let credential: HiveObserverCredential
    let token: String
    let socket: String
}

struct HiveObserverAuditEntry: Decodable, Identifiable {
    let time: String
    let action: String
    let credential: String?
    let name: String?
    let detail: String?
    let client: String?

    var id: String { "\(time)-\(action)-\(credential ?? "")" }
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
