import AppIntents
import AppKit
import Foundation

// Hive's actions for Shortcuts, Spotlight and Siri, and its Focus filter. The types are
// `nonisolated`, as the AppIntents protocols expect; the work runs on the main actor in
// `HiveIntentBackend`.

// MARK: - Entities

nonisolated struct AgentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let defaultQuery = AgentQuery()

    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: String
    @Property(title: "State") var state: String
    @Property(title: "Environment") var environment: String

    init(id: String, name: String, kind: String, state: String, environment: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.state = state
        self.environment = environment
    }

    @MainActor init(_ agent: HiveAgent) {
        self.init(id: agent.id, name: agent.name.isEmpty ? agent.kind : agent.name, kind: agent.kind, state: agent.state, environment: agent.environmentID)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(state) · \(environment)")
    }
}

nonisolated struct AgentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AgentEntity] {
        try await HiveIntentBackend.agents().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AgentEntity] {
        try await HiveIntentBackend.agents().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.environment.localizedCaseInsensitiveContains(string) || $0.kind.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [AgentEntity] {
        try await HiveIntentBackend.agents().filter { $0.state != "exited" }
    }
}

nonisolated struct EnvironmentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Environment"
    static let defaultQuery = EnvironmentQuery()

    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Folder") var path: String

    init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    @MainActor init(_ environment: HiveEnvironment) {
        self.init(id: environment.id, name: environment.name.isEmpty ? environment.id : environment.name, path: environment.path)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(path)")
    }
}

nonisolated struct EnvironmentQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EnvironmentEntity] {
        try await HiveIntentBackend.environments().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [EnvironmentEntity] {
        try await HiveIntentBackend.environments().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [EnvironmentEntity] {
        try await HiveIntentBackend.environments()
    }
}

nonisolated struct AgentKindOptions: DynamicOptionsProvider {
    func results() async throws -> [String] {
        try await HiveIntentBackend.agentKinds()
    }
}

nonisolated enum AgentWaitCondition: String, AppEnum {
    case done, idle, blocked, exited

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Condition"
    static let caseDisplayRepresentations: [AgentWaitCondition: DisplayRepresentation] = [
        .done: "Finishes its turn",
        .idle: "Is ready for a prompt",
        .blocked: "Needs a decision",
        .exited: "Exits",
    ]
}

// MARK: - Actions

nonisolated struct StartAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Agent"
    static let description = IntentDescription("Starts a coding agent in a Hive environment, optionally with a first prompt.")

    @Parameter(title: "Agent", optionsProvider: AgentKindOptions())
    var kind: String

    @Parameter(title: "Environment")
    var environment: EnvironmentEntity

    @Parameter(title: "Name")
    var name: String?

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true))
    var prompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$kind) in \(\.$environment)") {
            \.$name
            \.$prompt
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<AgentEntity> & ProvidesDialog {
        let agent = try await HiveIntentBackend.startAgent(kind: kind, environmentID: environment.id, name: name, prompt: prompt)
        return .result(value: agent, dialog: "Started \(agent.name) in \(environment.name).")
    }
}

nonisolated struct PromptAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Prompt Agent"
    static let description = IntentDescription("Sends a prompt to an agent and, if you like, waits for its answer.")

    @Parameter(title: "Agent")
    var agent: AgentEntity

    @Parameter(title: "Prompt", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Parameter(title: "Wait for the Answer", default: true)
    var wait: Bool

    @Parameter(title: "Give Up After (Minutes)", default: 30, inclusiveRange: (1, 600))
    var timeoutMinutes: Int

    static var parameterSummary: some ParameterSummary {
        When(\.$wait, .equalTo, true) {
            Summary("Send \(\.$text) to \(\.$agent)") {
                \.$wait
                \.$timeoutMinutes
            }
        } otherwise: {
            Summary("Send \(\.$text) to \(\.$agent)") {
                \.$wait
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await HiveIntentBackend.prompt(agentID: agent.id, text: text, wait: wait, timeoutMinutes: timeoutMinutes)
        guard wait else { return .result(value: "", dialog: "Sent to \(agent.name).") }
        return .result(value: result.answer, dialog: "\(agent.name): \(result.outcome).")
    }
}

nonisolated struct WaitForAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Wait for Agent"
    static let description = IntentDescription("Waits until an agent finishes, is ready, needs a decision or exits. It also stops waiting if the agent blocks or exits first.")

    @Parameter(title: "Agent")
    var agent: AgentEntity

    @Parameter(title: "Until It", default: .done)
    var until: AgentWaitCondition

    @Parameter(title: "Give Up After (Minutes)", default: 60, inclusiveRange: (1, 1440))
    var timeoutMinutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Wait until \(\.$agent) \(\.$until)") {
            \.$timeoutMinutes
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let result = try await HiveIntentBackend.wait(agentID: agent.id, until: until.rawValue, timeoutMinutes: timeoutMinutes)
        return .result(value: result.outcome, dialog: "\(agent.name): \(result.outcome).")
    }
}

nonisolated struct ListBlockedAgentsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Agents That Need You"
    static let description = IntentDescription("Lists the agents waiting for a decision, such as a permission prompt.")

    func perform() async throws -> some IntentResult & ReturnsValue<[AgentEntity]> & ProvidesDialog {
        let blocked = try await HiveIntentBackend.agents().filter { $0.state == "blocked" }
        let dialog: IntentDialog = blocked.isEmpty
            ? "No agent needs you right now."
            : "\(blocked.count) need\(blocked.count == 1 ? "s" : "") you: \(blocked.map(\.name).joined(separator: ", "))."
        return .result(value: blocked, dialog: dialog)
    }
}

nonisolated struct OpenEnvironmentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Environment"
    static let description = IntentDescription("Shows an environment's tab in Hive.")
    static let openAppWhenRun = true

    @Parameter(title: "Environment")
    var environment: EnvironmentEntity

    func perform() async throws -> some IntentResult {
        await DeepLinkRouter.shared.open(.environment(environment.id))
        return .result()
    }
}

nonisolated struct OpenAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Agent"
    static let description = IntentDescription("Shows an agent's pane in Hive.")
    static let openAppWhenRun = true

    @Parameter(title: "Agent")
    var agent: AgentEntity

    func perform() async throws -> some IntentResult {
        await DeepLinkRouter.shared.open(.agent(agent.id))
        return .result()
    }
}

// MARK: - Focus filter

/// Chooses which agents can reach you during a Focus: quiet some environments entirely, or let
/// through only agents waiting for a decision. Hive's own notifications follow it; the defaults
/// (nothing quiet) are what apply once the Focus ends.
nonisolated struct HiveFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Hive Notifications"
    static let description = IntentDescription("Choose which agents can reach you during this Focus.")

    @Parameter(title: "Quiet Environments")
    var quietEnvironments: [EnvironmentEntity]?

    @Parameter(title: "Only Agents That Need a Decision", default: false)
    var onlyDecisions: Bool

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let quiet = quietEnvironments, !quiet.isEmpty { parts.append("Quiet: \(quiet.map(\.name).joined(separator: ", "))") }
        if onlyDecisions { parts.append("Only decisions") }
        return DisplayRepresentation(title: "Hive", subtitle: "\(parts.isEmpty ? "Everything" : parts.joined(separator: " · "))")
    }

    func perform() async throws -> some IntentResult {
        let quiet = (quietEnvironments ?? []).map(\.id)
        let decisions = onlyDecisions
        await MainActor.run { FocusFilterSettings.save(quietEnvironments: quiet, onlyDecisions: decisions) }
        return .result()
    }
}

// MARK: - Shortcuts and Spotlight

nonisolated struct HiveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ListBlockedAgentsIntent(),
            phrases: ["Which \(.applicationName) agents need me", "Show blocked agents in \(.applicationName)"],
            shortTitle: "Agents That Need You",
            systemImageName: "hand.raised"
        )
        AppShortcut(
            intent: StartAgentIntent(),
            phrases: ["Start an agent in \(.applicationName)", "Start a \(.applicationName) agent"],
            shortTitle: "Start Agent",
            systemImageName: "play"
        )
        AppShortcut(
            intent: PromptAgentIntent(),
            phrases: ["Prompt an agent in \(.applicationName)", "Ask a \(.applicationName) agent"],
            shortTitle: "Prompt Agent",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: WaitForAgentIntent(),
            phrases: ["Wait for a \(.applicationName) agent"],
            shortTitle: "Wait for Agent",
            systemImageName: "hourglass"
        )
        AppShortcut(
            intent: OpenEnvironmentIntent(),
            phrases: ["Open \(\.$environment) in \(.applicationName)", "Open an environment in \(.applicationName)"],
            shortTitle: "Open Environment",
            systemImageName: "folder"
        )
    }
}
