import Foundation

struct SavedHiveMachine: Decodable, Identifiable {
    let name: String
    let host: String
    let session: String?
    let disabled: Bool?
    let identityID: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, host, session, disabled
        case identityID = "id"
    }
}

struct HiveNearbyMachine: Decodable, Identifiable, Hashable {
    let name: String
    let id: String
    let host: String
    let port: Int
    let capabilities: [String]?
    let state: String
    let machine: String?
    let note: String?
}

struct HiveNearbyResponse: Decodable {
    let runtimes: [HiveNearbyMachine]
}

struct HivePairProof: Decodable {
    let id: String
    let name: String
    let hostname: String?
    let platform: String
    let version: String
}

struct HivePairIdentity: Decodable {
    let proof: HivePairProof
    let fingerprint: String
    let trust: String
}

struct HerdrImportPreview: Decodable {
    let mapped: [String]?
    let skipped: [String]?
    let config: String?
    let backup: String?
}

struct HiveMachineStatus: Decodable {
    let name: String
    let reachable: Bool
    let error: String?
    let disabled: Bool?
    let agents: Int?
    let state: String?
    let identity: String?
    let version: String?
}

struct HiveEnvironment: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let managed: Bool
    let status: String
    var git: HiveGitStatus?
    var worktree: HiveWorktree?
}

struct HiveWorktree: Decodable, Hashable {
    let repo: String
    let branch: String
}

struct HiveGitStatus: Decodable, Hashable {
    let branch: String?
    let staged: Int?
    let modified: Int?
    let untracked: Int?
    let conflicts: Int?
}

struct HiveAgent: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String
    let name: String
    let environmentID: String
    let paneID: String?
    let tabID: String?
    let state: String
    let reason: String?
    let since: String?
    let sessionID: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, state, reason, since, source
        case environmentID = "environment_id"
        case paneID = "pane_id"
        case tabID = "tab_id"
        case sessionID = "session_id"
    }
}

extension HiveAgent {
    /// A detected coding agent, as opposed to a plain process the runtime also tracks.
    var isCodingAgent: Bool { !kind.isEmpty }

    /// Sort order for lists: agents that need attention first, closed ones last.
    var stateRank: Int {
        switch state {
        case "blocked": 0
        case "working": 1
        case "done": 2
        case "idle": 3
        case "unknown": 4
        case "exited": 5
        default: 6
        }
    }
}

struct HiveAgentManifest: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}
