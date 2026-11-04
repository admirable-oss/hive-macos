import Combine
import Foundation

/// Personal command-center state: saved views, first-party recipes, helper delegations and
/// this app's own activity log. All of it is local declarative configuration persisted in
/// `UserDefaults` under `hive.desktop.*`, in the same style as the saved tabs.
@MainActor
final class CommandCenterStore: ObservableObject {
    @Published private(set) var views: [WorkspaceView] = []
    @Published var activeViewID: String? { didSet { defaults.set(activeViewID, forKey: Keys.activeView) } }
    @Published private(set) var recipes: [WorkspaceRecipe] = []
    @Published private(set) var delegations: [Delegation] = []
    @Published private(set) var activity: [ActivityEntry] = []

    /// The view currently applied to the workspace shell, if any.
    var activeView: WorkspaceView? { views.first { $0.id == activeViewID } }

    /// Views the user created, as opposed to the built-ins.
    var customViews: [WorkspaceView] { views.filter { !$0.builtIn } }

    private let defaults: UserDefaults
    private var activityLoaded = false
    /// Task states already logged, so polling doesn't duplicate entries.
    private var loggedTaskStates: Set<String> = []

    private enum Keys {
        static let views = "hive.desktop.views.v1"
        static let activeView = "hive.desktop.activeView.v1"
        static let recipes = "hive.desktop.recipes.v1"
        static let delegations = "hive.desktop.delegations.v1"
        static let activity = "hive.desktop.activity.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        views = Self.load([WorkspaceView].self, key: Keys.views, from: defaults) ?? Self.builtInViews
        activeViewID = defaults.string(forKey: Keys.activeView)
        recipes = Self.load([WorkspaceRecipe].self, key: Keys.recipes, from: defaults) ?? Self.builtInRecipes
        delegations = Self.load([Delegation].self, key: Keys.delegations, from: defaults) ?? []
        activity = Self.load([ActivityEntry].self, key: Keys.activity, from: defaults) ?? []
        activityLoaded = true
        // Views added in a newer build should still appear for someone who saved earlier.
        mergeBuiltIns()
        mergeBuiltInRecipes()
    }

    // MARK: Views

    func save(_ view: WorkspaceView) {
        var view = view
        view.updatedAt = Date()
        if let index = views.firstIndex(where: { $0.id == view.id }) {
            views[index] = view
        } else {
            views.append(view)
        }
        persistViews()
    }

    func duplicate(_ view: WorkspaceView, name: String) {
        var copy = view
        copy.id = UUID().uuidString
        copy.name = name
        copy.builtIn = false
        copy.updatedAt = Date()
        views.append(copy)
        persistViews()
    }

    /// Removes a saved view. Built-ins are kept, since there is always a default to fall back to.
    func delete(_ id: String) {
        guard let view = views.first(where: { $0.id == id }), !view.builtIn else { return }
        views.removeAll { $0.id == id }
        if activeViewID == id { activeViewID = nil }
        persistViews()
    }

    /// Applies a view to the workspace shell; the dashboard observes `activeView`.
    func apply(_ view: WorkspaceView) {
        activeViewID = view.id
    }

    func clearActiveView() { activeViewID = nil }

    /// Puts a built-in view back to the settings it ships with.
    func resetToDefault(_ id: String) {
        guard let index = views.firstIndex(where: { $0.id == id }), views[index].builtIn,
              let original = Self.builtInViews.first(where: { $0.id == id }) else { return }
        views[index] = original
        persistViews()
    }

    /// Restores every built-in and drops user-created views.
    func restoreDefaults() {
        views = Self.builtInViews
        activeViewID = nil
        persistViews()
    }

    private func persistViews() {
        Self.save(views, key: Keys.views, to: defaults)
    }

    private func mergeBuiltIns() {
        var changed = false
        for builtIn in Self.builtInViews where !views.contains(where: { $0.id == builtIn.id }) {
            views.append(builtIn)
            changed = true
        }
        if changed { persistViews() }
    }

    // MARK: Recipes

    @discardableResult
    func makeRecipe(name: String, views: [WorkspaceView], author: String? = nil) -> WorkspaceRecipe {
        let recipe = WorkspaceRecipe(name: name, views: views, author: author)
        recipes.append(recipe)
        persistRecipes()
        return recipe
    }

    /// Imports a recipe, skipping views that are incompatible or already present by name.
    func importRecipe(_ recipe: WorkspaceRecipe) -> RecipeImportResult {
        guard recipe.compatible else {
            return RecipeImportResult(added: 0, skipped: [], message: "This recipe needs a newer version of Hive Desktop.")
        }
        var added = 0
        var skipped: [String] = []
        for incoming in recipe.views {
            if views.contains(where: { $0.name.caseInsensitiveCompare(incoming.name) == .orderedSame }) {
                skipped.append(incoming.name)
                continue
            }
            var view = incoming
            view.id = UUID().uuidString
            view.builtIn = false
            view.updatedAt = Date()
            views.append(view)
            added += 1
        }
        persistViews()
        if !recipes.contains(where: { $0.id == recipe.id }) {
            recipes.append(recipe)
            persistRecipes()
        }
        let message = skipped.isEmpty
            ? "Added \(added) view\(added == 1 ? "" : "s")."
            : "Added \(added), skipped \(skipped.count) already present: \(skipped.joined(separator: ", "))."
        return RecipeImportResult(added: added, skipped: skipped, message: message)
    }

    func deleteRecipe(_ id: String) {
        guard let recipe = recipes.first(where: { $0.id == id }), !recipe.builtIn else { return }
        recipes.removeAll { $0.id == id }
        persistRecipes()
    }

    private func persistRecipes() {
        Self.save(recipes, key: Keys.recipes, to: defaults)
    }

    private func mergeBuiltInRecipes() {
        var changed = false
        for recipe in Self.builtInRecipes where !recipes.contains(where: { $0.id == recipe.id }) {
            recipes.append(recipe)
            changed = true
        }
        if changed { persistRecipes() }
    }

    // MARK: Delegations

    @discardableResult
    func addDelegation(_ delegation: Delegation) -> Delegation {
        delegations.insert(delegation, at: 0)
        persistDelegations()
        record(kind: .delegation, title: "Delegated “\(delegation.title)”", detail: "Helper \(delegation.helperKind) for \(delegation.parentName)", environmentID: delegation.environmentID)
        return delegation
    }

    /// Links a started helper agent to its delegation record.
    func attachHelper(_ agentID: String, to delegationID: String) {
        guard let index = delegations.firstIndex(where: { $0.id == delegationID }) else { return }
        delegations[index].helperAgentID = agentID
        persistDelegations()
    }

    func markReported(_ delegationID: String, report: String) {
        guard let index = delegations.firstIndex(where: { $0.id == delegationID }) else { return }
        delegations[index].state = .reported
        delegations[index].report = report
        delegations[index].reportedAt = Date()
        persistDelegations()
        record(kind: .delegation, title: "Report back: \(delegations[index].title)", detail: report, environmentID: delegations[index].environmentID)
    }

    func markStopped(_ delegationID: String) {
        guard let index = delegations.firstIndex(where: { $0.id == delegationID }) else { return }
        delegations[index].state = .stopped
        persistDelegations()
    }

    func removeDelegation(_ id: String) {
        delegations.removeAll { $0.id == id }
        persistDelegations()
    }

    /// Helpers currently working for a given parent agent.
    func delegations(forParent parentAgentID: String) -> [Delegation] {
        delegations.filter { $0.parentAgentID == parentAgentID }
    }

    private func persistDelegations() {
        Self.save(delegations, key: Keys.delegations, to: defaults)
    }

    // MARK: Activity

    func record(
        kind: ActivityEntry.Kind,
        title: String,
        detail: String? = nil,
        agentID: String? = nil,
        environmentID: String? = nil,
        machine: String? = nil
    ) {
        let entry = ActivityEntry(kind: kind, title: title, detail: detail, agentID: agentID, environmentID: environmentID, machine: machine)
        insert(entry)
    }

    /// Logs a change in an agent's state, as Hive's event stream reports it.
    func recordAgentChange(previous: HiveAgent?, agent: HiveAgent, machine: String? = nil) {
        guard previous?.state != agent.state else { return }
        let name = agent.name.isEmpty ? agent.kind : agent.name
        let title = previous == nil ? "\(name) appeared" : "\(name) → \(agentStateTitle(agent.state))"
        insert(ActivityEntry(kind: .agent, title: title, detail: agent.reason, agentID: agent.id, environmentID: agent.environmentID, machine: machine))
    }

    /// Logs a task the first time it reaches a settled state, so polling doesn't duplicate.
    func recordTaskOutcome(task: HiveTask, plan: HiveTaskPlan) {
        let settled = ["succeeded", "failed", "cancelled", "skipped"]
        guard settled.contains(task.state) else { return }
        let key = "\(plan.id)/\(task.id)/\(task.state)"
        guard !loggedTaskStates.contains(key) else { return }
        loggedTaskStates.insert(key)
        insert(ActivityEntry(
            kind: .task,
            title: "\(task.spec.title ?? task.spec.id) — \(task.state)",
            detail: task.result?.summary ?? task.reason,
            environmentID: task.environmentID ?? task.spec.environmentID
        ))
    }

    func recordSession(_ title: String, detail: String?) {
        insert(ActivityEntry(kind: .session, title: title, detail: detail))
    }

    func clearActivity() {
        activity = []
        loggedTaskStates = []
        persistActivity()
    }

    private func insert(_ entry: ActivityEntry) {
        activity.insert(entry, at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        persistActivity()
    }

    private func persistActivity() {
        guard activityLoaded else { return }
        Self.save(activity, key: Keys.activity, to: defaults)
    }

    // MARK: Storage

    private static func save<T: Encodable>(_ value: T, key: String, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: First-party defaults

    static let builtInViews: [WorkspaceView] = [
        WorkspaceView(
            id: "builtin.terminal",
            name: "Terminal focus",
            settings: WorkspaceViewSettings(kind: .terminal),
            builtIn: true
        ),
        WorkspaceView(
            id: "builtin.overview",
            name: "Overview",
            settings: WorkspaceViewSettings(kind: .overview, density: .comfortable, inspector: nil, showsInspector: false),
            builtIn: true
        ),
        WorkspaceView(
            id: "builtin.statusBoard",
            name: "Status board",
            settings: WorkspaceViewSettings(kind: .statusBoard, showsMachines: true, density: .compact, inspector: nil, showsInspector: false),
            builtIn: true
        ),
    ]

    static let builtInRecipes: [WorkspaceRecipe] = [
        WorkspaceRecipe(
            id: "recipe.focus",
            name: "Focus set",
            views: [
                WorkspaceView(id: "recipe.focus.terminal", name: "Deep work", settings: WorkspaceViewSettings(kind: .terminal, showsMachines: false, density: .compact), builtIn: false),
                WorkspaceView(id: "recipe.focus.board", name: "Attention board", settings: WorkspaceViewSettings(kind: .statusBoard, density: .compact, inspector: nil, showsInspector: false), builtIn: false),
            ],
            author: "Hive",
            builtIn: true
        ),
        WorkspaceRecipe(
            id: "recipe.triage",
            name: "Triage set",
            views: [
                WorkspaceView(id: "recipe.triage.board", name: "Triage board", settings: WorkspaceViewSettings(kind: .statusBoard, showsEnvironments: true, showsAgents: true, showsMachines: true, density: .compact, inspector: "changes"), builtIn: false),
                WorkspaceView(id: "recipe.triage.review", name: "Review desk", settings: WorkspaceViewSettings(kind: .overview, density: .comfortable, inspector: "changes"), builtIn: false),
            ],
            author: "Hive",
            builtIn: true
        ),
    ]
}

struct RecipeImportResult {
    let added: Int
    let skipped: [String]
    let message: String
}
