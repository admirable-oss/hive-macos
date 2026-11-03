import Foundation

// The daemon's workspace as `api.snapshot` and the event stream describe it.
// Only the fields the app uses are decoded; unknown fields are ignored so newer
// daemons keep working.

struct HiveTab: Decodable, Identifiable, Hashable {
    let id: String
    let environmentID: String
    let name: String
    let active: Bool?
    let focused: String?
    let zoomed: String?

    enum CodingKeys: String, CodingKey {
        case id, name, active, focused, zoomed
        case environmentID = "environment_id"
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
}

/// `environment.git` carries only the environment's ID and its new git status.
struct HiveEnvironmentGitUpdate: Decodable {
    let id: String
    let git: HiveGitStatus?
}

struct HiveIDPayload: Decodable {
    let id: String
}
