import Foundation

/// What Shortcuts, Spotlight, Siri and Focus filters ask of Hive, done through the `hive` CLI
/// so it works whether or not a Hive window is open. Runs against the session the app shows.
@MainActor
enum HiveIntentBackend {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A finished `hive` command: its exit status and what it printed.
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static var sessionName: String { UserDefaults.standard.string(forKey: "hive.session.name") ?? "default" }

    // MARK: Reading

    static func agents() async throws -> [AgentEntity] {
        let list = try JSONDecoder().decode(HiveAgentList.self, from: Data(try await succeed(["--json", "agent", "list"]).utf8))
        return list.agents.map(AgentEntity.init)
    }

    static func environments() async throws -> [EnvironmentEntity] {
        let list = try JSONDecoder().decode([HiveEnvironment].self, from: Data(try await succeed(["--json", "environment", "list"]).utf8))
        return list.map(EnvironmentEntity.init)
    }

    static func agentKinds() async throws -> [String] {
        let manifests = try JSONDecoder().decode([HiveAgentManifest].self, from: Data(try await succeed(["--json", "agent", "manifests"]).utf8))
        return manifests.map(\.id)
    }

    // MARK: Acting

    static func startAgent(kind: String, environmentID: String, name: String?, prompt: String?) async throws -> AgentEntity {
        var args = ["--json", "agent", "start", "--kind", kind, "--env", environmentID]
        if let name, !name.isEmpty { args += ["--name", name] }
        let started = try JSONDecoder().decode(HiveAgentStarted.self, from: Data(try await succeed(args).utf8))
        if let prompt, !prompt.isEmpty {
            _ = try await succeed(["agent", "prompt", started.agent.id, prompt])
        }
        return AgentEntity(started.agent)
    }

    /// Sends a prompt; with `wait`, returns what the agent shows once it has finished its turn.
    static func prompt(agentID: String, text: String, wait: Bool, timeoutMinutes: Int) async throws -> (outcome: String, answer: String) {
        var args = ["--json", "agent", "prompt", agentID, text]
        if wait { args += ["--wait", "--read", "60", "--timeout", "\(timeoutMinutes)m"] }
        let result = try JSONDecoder().decode(HivePromptResult.self, from: Data(try await succeed(args).utf8))
        return (result.outcome, (result.output ?? []).joined(separator: "\n"))
    }

    /// Waits for the agent; ends early when it blocks or exits. Exit codes 4 and 5 are outcomes, not errors.
    static func wait(agentID: String, until: String, timeoutMinutes: Int) async throws -> (outcome: String, agent: AgentEntity?) {
        let output = try await run(["--json", "agent", "wait", agentID, "--until", until, "--timeout", "\(timeoutMinutes)m"])
        let result = try? JSONDecoder().decode(HiveAgentWaitResult.self, from: Data(output.stdout.utf8))
        switch output.status {
        case 0: return (result?.outcome ?? "reached", result.map { AgentEntity($0.agent) })
        case 4: return ("timed out", result.map { AgentEntity($0.agent) })
        case 5: return (result?.outcome ?? "blocked or exited", result.map { AgentEntity($0.agent) })
        default: throw Failure(message: output.stderr.isEmpty ? "Hive couldn’t wait for that agent." : output.stderr)
        }
    }

    // MARK: Running hive

    private static func succeed(_ arguments: [String]) async throws -> String {
        let output = try await run(arguments)
        guard output.status == 0 else {
            throw Failure(message: output.stderr.isEmpty ? "The hive command failed." : output.stderr)
        }
        return output.stdout
    }

    private static func run(_ arguments: [String]) async throws -> Output {
        guard let hive = await HiveInstallationService.locateInstalledHive() else {
            throw Failure(message: "Hive isn’t installed. Open Hive Desktop to install it.")
        }
        let args = ["--session", sessionName] + arguments
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = hive
                process.arguments = args
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    let out = stdout.fileHandleForReading.readDataToEndOfFile()
                    let err = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: Output(
                        status: process.terminationStatus,
                        stdout: String(decoding: out, as: UTF8.self),
                        stderr: String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Which agents can reach the user during a Focus, as the Hive Focus filter set it.
/// The filter writes it when a Focus starts and resets it when the Focus ends.
enum FocusFilterSettings {
    private static let quietKey = "hive.focus.quietEnvironments"
    private static let decisionsKey = "hive.focus.onlyDecisions"

    static func save(quietEnvironments: [String], onlyDecisions: Bool) {
        UserDefaults.standard.set(quietEnvironments, forKey: quietKey)
        UserDefaults.standard.set(onlyDecisions, forKey: decisionsKey)
    }

    /// Whether a notification about an agent in this state and environment may be shown now.
    static func allows(state: String, environmentID: String) -> Bool {
        let quiet = UserDefaults.standard.stringArray(forKey: quietKey) ?? []
        if quiet.contains(environmentID) { return false }
        if UserDefaults.standard.bool(forKey: decisionsKey) && state != "blocked" { return false }
        return true
    }
}
