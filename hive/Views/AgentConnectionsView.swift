import AppKit
import SwiftUI

/// Connects coding agents to Hive so they can drive other agents: Hive's MCP server
/// (`hive mcp`) registered with each agent CLI, and Hive's skill (`hive --skill`) where
/// each agent reads skills. Registration goes through the agents' own CLIs where they have one.
struct AgentConnectionsView: View {
    let hiveURL: URL

    private struct Agent: Identifiable {
        let id: String
        let name: String
        /// The CLI's executable name, when it can register MCP servers itself.
        let cli: String?
        let skillsDirectory: String
        /// Where to add the server by hand when there's no CLI for it.
        var configPath: String?
    }

    private static let agents = [
        Agent(id: "claude", name: "Claude Code", cli: "claude", skillsDirectory: "~/.claude/skills"),
        Agent(id: "codex", name: "Codex", cli: "codex", skillsDirectory: "~/.codex/skills"),
        Agent(id: "opencode", name: "OpenCode", cli: nil, skillsDirectory: "~/.config/opencode/skills", configPath: "~/.config/opencode/opencode.json"),
    ]

    private enum State: Equatable { case unknown, missing, off, on }

    @SwiftUI.State private var executables: [String: URL] = [:]
    @SwiftUI.State private var mcp: [String: State] = [:]
    @SwiftUI.State private var skill: [String: State] = [:]
    @SwiftUI.State private var skillText: String?
    @SwiftUI.State private var busy: String?
    @SwiftUI.State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Let your agents start, prompt and wait for other agents through Hive: its MCP server gives them the tools, and its skill teaches them how to use them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.agents) { agent in
                row(agent)
            }

            if let error { HiveNotice(text: error) }
        }
        .task { await refresh() }
    }

    private func row(_ agent: Agent) -> some View {
        let mcpState = mcp[agent.id] ?? .unknown
        let skillState = skill[agent.id] ?? .unknown
        return HStack(alignment: .center, spacing: 12) {
            AgentProviderIcon(kind: agent.id, size: 16)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    chip("MCP", mcpState)
                    chip("Skill", skillState)
                }
            }
            Spacer()
            if busy == agent.id {
                ProgressView().controlSize(.small)
            } else {
                mcpButton(agent, mcpState)
                skillButton(agent, skillState)
            }
        }
        .padding(.vertical, 4)
    }

    private func chip(_ title: String, _ state: State) -> some View {
        switch state {
        case .on: HiveChip(text: "\(title) on", tint: .green, symbol: "checkmark")
        case .off: HiveChip(text: "\(title) off")
        case .missing: HiveChip(text: "not installed")
        case .unknown: HiveChip(text: "\(title) …")
        }
    }

    @ViewBuilder
    private func mcpButton(_ agent: Agent, _ state: State) -> some View {
        if agent.cli == nil {
            Button("MCP Setup…") { copyOpenCodeSnippet(agent) }
                .help("Copies the server entry for \(agent.configPath ?? "its config") and opens it")
        } else if state == .on {
            Button("Remove MCP") { Task { await setMCP(agent, on: false) } }
        } else {
            Button("Add MCP") { Task { await setMCP(agent, on: true) } }
                .disabled(state == .missing || state == .unknown)
                .help(state == .missing ? "\(agent.name) isn’t installed" : "Runs `\(agent.cli ?? "") mcp add hive -- hive mcp`")
        }
    }

    @ViewBuilder
    private func skillButton(_ agent: Agent, _ state: State) -> some View {
        if state == .on {
            Button("Remove Skill") { setSkill(agent, on: false) }
        } else {
            Button(skill[agent.id] == .off && FileManager.default.fileExists(atPath: skillPath(agent)) ? "Update Skill" : "Install Skill") { setSkill(agent, on: true) }
                .disabled(skillText == nil)
                .help("Writes \(skillPath(agent))")
        }
    }

    // MARK: Checking

    private func refresh() async {
        if skillText == nil {
            skillText = try? await HiveCLIService(executableURL: hiveURL).run(["--skill"])
        }
        for agent in Self.agents {
            skill[agent.id] = skillState(agent)
            guard let cli = agent.cli else { mcp[agent.id] = .unknown; continue }
            guard let url = await locate(cli) else { mcp[agent.id] = .missing; continue }
            executables[agent.id] = url
            let registered = (try? await HiveCLIService(executableURL: url).run(["mcp", "get", "hive"])) != nil
            mcp[agent.id] = registered ? .on : .off
        }
    }

    private func skillState(_ agent: Agent) -> State {
        guard let installed = try? String(contentsOfFile: skillPath(agent), encoding: .utf8) else { return .off }
        return installed == skillText ? .on : .off
    }

    private func skillPath(_ agent: Agent) -> String {
        ((agent.skillsDirectory as NSString).expandingTildeInPath as NSString).appendingPathComponent("hive/SKILL.md")
    }

    /// Finds a CLI the way the user's login shell would, since apps don't get the shell's PATH.
    private func locate(_ command: String) async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard let output = try? await HiveCLIService(executableURL: URL(fileURLWithPath: shell)).run(["-lc", "command -v \(command)"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
    }

    // MARK: Changing

    private func setMCP(_ agent: Agent, on: Bool) async {
        guard let url = executables[agent.id] else { return }
        busy = agent.id
        defer { busy = nil }
        let cli = HiveCLIService(executableURL: url)
        do {
            if on {
                // Claude Code adds to the current project unless told otherwise; Hive is for every project.
                let scope = agent.id == "claude" ? ["--scope", "user"] : []
                _ = try await cli.run(["mcp", "add"] + scope + ["hive", "--", hiveURL.path, "mcp"])
            } else {
                let scope = agent.id == "claude" ? ["--scope", "user"] : []
                _ = try await cli.run(["mcp", "remove"] + scope + ["hive"])
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func setSkill(_ agent: Agent, on: Bool) {
        let path = skillPath(agent)
        do {
            if on, let skillText {
                try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try skillText.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(atPath: path)
                // The folder goes too, unless something else of the user's is in it.
                let folder = (path as NSString).deletingLastPathComponent
                if (try? FileManager.default.contentsOfDirectory(atPath: folder))?.isEmpty == true {
                    try? FileManager.default.removeItem(atPath: folder)
                }
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        skill[agent.id] = skillState(agent)
    }

    private func copyOpenCodeSnippet(_ agent: Agent) {
        let snippet = """
        "mcp": {
          "hive": { "type": "local", "command": ["\(hiveURL.path)", "mcp"], "enabled": true }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        if let path = agent.configPath.map({ ($0 as NSString).expandingTildeInPath }), FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        error = nil
    }
}
