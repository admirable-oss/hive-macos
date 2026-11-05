import Darwin
import Foundation

// The web observer (`hive web …`): a read-only browser view of agents. It runs as its own
// process, outside the daemon, so the app drives it through the CLI.

struct WebObserverStatus: Decodable, Hashable {
    struct Runtime: Decodable, Hashable {
        let name: String
        let `where`: String?
        let state: String?
    }

    let version: String?
    let listen: String
    let publicURL: String
    let startedAt: String?
    let viewers: Int
    let runtimes: [Runtime]

    enum CodingKeys: String, CodingKey {
        case version, listen, viewers, runtimes
        case publicURL = "public_url"
        case startedAt = "started_at"
    }
}

/// A Hive runtime (a session on a machine) the web observer may show.
struct WebObserverRuntime: Decodable, Hashable, Identifiable {
    struct Scope: Decodable, Hashable {
        let all: Bool?
        let environments: [String]?
        let panes: [String]?
    }

    let name: String
    let session: String?
    let scope: Scope?
    let screens: Bool?
    let expiresAt: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, session, scope, screens
        case expiresAt = "expires_at"
    }
}

/// Access a share link gives, and how much of it is left.
struct WebObserverGrant: Decodable, Hashable, Identifiable {
    let id: String
    let label: String?
    let runtimes: [String]?
    let scope: WebObserverRuntime.Scope?
    let screens: Bool?
    let history: Bool?
    let createdAt: String?
    let expiresAt: String?
    let linkExpiresAt: String?
    let maxUses: Int?
    let uses: Int?
    let state: String

    enum CodingKeys: String, CodingKey {
        case id, label, runtimes, scope, screens, history, uses, state
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case linkExpiresAt = "link_expires_at"
        case maxUses = "max_uses"
    }
}

/// A browser signed in with a grant.
struct WebObserverSession: Decodable, Hashable, Identifiable {
    let id: String
    let grant: String?
    let userAgent: String?
    let createdAt: String?
    let lastSeenAt: String?

    enum CodingKeys: String, CodingKey {
        case id, grant
        case userAgent = "user_agent"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

struct WebObserverAuditEntry: Decodable, Hashable, Identifiable {
    let time: String
    let action: String
    let credential: String?
    let name: String?
    let detail: String?

    var id: String { time + action + (credential ?? "") }
}

struct WebObserverPushStatus: Decodable, Hashable {
    struct Device: Decodable, Hashable {
        let id: String?
        let grant: String?
        let session: String?
        let userAgent: String?
        let lastDelivery: String?

        enum CodingKeys: String, CodingKey {
            case id, grant, session
            case userAgent = "user_agent"
            case lastDelivery = "last_delivery"
        }
    }

    let enabled: Bool
    let devices: [Device]
}

/// What a share link may show.
struct WebShareRequest {
    var label = ""
    var runtimes: [String] = []
    /// Empty shows everything the runtimes show.
    var environments: [String] = []
    var screens = true
    var history = false
    var uses = 1
    var expiresHours = 8
    var linkMinutes = 15
}

struct WebObserverService {
    let cli: HiveCLIService

    /// Nil when the web observer isn't running.
    func status() async throws -> WebObserverStatus? {
        do {
            return try decode(WebObserverStatus.self, try await cli.run(["--json", "web", "status"]))
        } catch where Self.isNotRunning(error) {
            return nil
        }
    }

    func runtimes() async throws -> [WebObserverRuntime] {
        try decode([WebObserverRuntime].self, try await cli.run(["--json", "web", "runtime", "list"]))
    }

    /// Lets the web observer show this session: everything, or only some environments.
    func addRuntime(name: String, environments: [String], screens: Bool) async throws {
        var args = ["--json", "web", "runtime", "add", name]
        if environments.isEmpty { args.append("--all") } else { environments.forEach { args += ["--env", $0] } }
        if screens { args.append("--screens") }
        _ = try await cli.run(args)
    }

    func removeRuntime(_ name: String) async throws {
        _ = try await cli.run(["web", "runtime", "remove", name])
    }

    /// A one-time sign-in link, and the grant it uses.
    func share(_ request: WebShareRequest) async throws -> (grant: WebObserverGrant, link: String) {
        struct Shared: Decodable { let grant: WebObserverGrant; let link: String }
        var args = ["--json", "web", "share", "--uses", String(request.uses),
                    "--expires", "\(request.expiresHours)h", "--link-expires", "\(request.linkMinutes)m"]
        if !request.label.isEmpty { args += ["--label", request.label] }
        request.runtimes.forEach { args += ["--runtime", $0] }
        if request.environments.isEmpty { args.append("--all") } else { request.environments.forEach { args += ["--env", $0] } }
        if request.history { args.append("--history") } else if request.screens { args.append("--screens") }
        let shared = try decode(Shared.self, try await cli.run(args))
        return (shared.grant, shared.link)
    }

    func grants() async throws -> (grants: [WebObserverGrant], sessions: [WebObserverSession]) {
        struct Grants: Decodable { let grants: [WebObserverGrant]; let sessions: [WebObserverSession]? }
        let result = try decode(Grants.self, try await cli.run(["--json", "web", "grants"]))
        return (result.grants, result.sessions ?? [])
    }

    /// Ends a grant and its browsers, or one browser session, at once.
    func revoke(_ id: String) async throws {
        _ = try await cli.run(["web", "revoke", id])
    }

    func audit(limit: Int = 100) async throws -> [WebObserverAuditEntry] {
        try decode([WebObserverAuditEntry].self, try await cli.run(["--json", "web", "audit", "--limit", String(limit)]))
    }

    func pushStatus() async throws -> WebObserverPushStatus {
        try decode(WebObserverPushStatus.self, try await cli.run(["--json", "web", "push", "status"]))
    }

    func testPush(_ grantOrSession: String) async throws {
        _ = try await cli.run(["web", "push", "test", grantOrSession])
    }

    // MARK: Running it

    /// Starts `hive web serve` in the background. It keeps running after the app quits, as agents do.
    func start() throws {
        let process = Process()
        process.executableURL = cli.executableURL
        process.arguments = (cli.sessionName.map { ["--session", $0] } ?? []) + ["web", "serve"]
        let log = Self.logURL
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    /// Stops every `hive web serve` running as this user, wherever it was started.
    func stop() async {
        let pgrep = HiveCLIService(executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"))
        guard let output = try? await pgrep.run(["-f", "hive web serve"]) else { return }
        for pid in output.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) where pid != getpid() {
            kill(pid, SIGTERM)
        }
    }

    /// Where a web observer started by the app writes its output.
    static var logURL: URL {
        let home = ProcessInfo.processInfo.environment["HIVE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hive")
        return URL(fileURLWithPath: home).appendingPathComponent("web/serve.log")
    }

    // MARK: Helpers

    private static func isNotRunning(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("not running")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ output: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(output.utf8))
    }
}
