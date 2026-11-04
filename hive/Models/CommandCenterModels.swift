import Foundation

// M7 · Personal Command Center.
//
// Everything here is *declarative local configuration*: saved workspace views, shareable
// recipes, helper-agent delegations and this app's own activity log. Nothing in this file
// is executable — a view is data, and the app is what reads it.

/// Which built-in surface a saved view opens onto.
enum WorkspaceViewKind: String, Codable, CaseIterable, Hashable {
    case terminal
    case overview
    case statusBoard

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .overview: "Overview"
        case .statusBoard: "Status board"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .overview: "rectangle.grid.2x2"
        case .statusBoard: "tray.full"
        }
    }
}

/// How tightly lists pack their rows.
enum WorkspaceDensity: String, Codable, CaseIterable, Hashable {
    case comfortable
    case compact

    var title: String {
        switch self {
        case .comfortable: "Comfortable"
        case .compact: "Compact"
        }
    }

    /// The sidebar's minimum row height.
    var rowHeight: Double {
        switch self {
        case .comfortable: 22
        case .compact: 17
        }
    }
}

/// The declarative knobs a workspace view stores. Deliberately tiny and versionable.
struct WorkspaceViewSettings: Codable, Hashable {
    var kind: WorkspaceViewKind = .terminal
    var showsEnvironments = true
    var showsAgents = true
    var showsMachines = true
    var groupsWorktrees = true
    var density: WorkspaceDensity = .comfortable
    /// Raw value of `InspectorPanel`, so the model doesn't depend on a view type.
    var inspector: String? = "files"
    var showsInspector = true
}

/// A named, saved workspace view — a saved set of choices, not a script.
struct WorkspaceView: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var settings: WorkspaceViewSettings
    /// Built-in views can be reset to, but not deleted.
    var builtIn = false
    var updatedAt: Date = Date()

    static let recipeFormatVersion = 1
}

/// A versioned bundle of views that can be moved between installs as a file.
struct WorkspaceRecipe: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var version = WorkspaceView.recipeFormatVersion
    /// The `WorkspaceView.recipeFormatVersion` this file was written for.
    var formatVersion = WorkspaceView.recipeFormatVersion
    var views: [WorkspaceView]
    var author: String?
    /// Whether this shipped with the app.
    var builtIn = false

    var compatible: Bool { formatVersion <= WorkspaceView.recipeFormatVersion }
}

/// A helper agent started from a parent and tracked locally until it reports back.
struct Delegation: Codable, Identifiable, Hashable {
    enum State: String, Codable, Hashable {
        case running
        case reported
        case stopped
    }

    var id: String = UUID().uuidString
    /// The agent this helper works for.
    var parentAgentID: String
    var parentName: String
    var taskID: String?
    var title: String
    /// The helper agent's own ID once it starts.
    var helperAgentID: String?
    var helperKind: String
    var environmentID: String
    var instruction: String?
    var state: State = .running
    var createdAt: Date = Date()
    var report: String?
    var reportedAt: Date?
}

/// One line in this app's own activity log.
struct ActivityEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case agent
        case task
        case delegation
        case session

        var title: String {
            switch self {
            case .agent: "Agent"
            case .task: "Task"
            case .delegation: "Delegation"
            case .session: "Session"
            }
        }

        var symbol: String {
            switch self {
            case .agent: "sparkles"
            case .task: "checklist"
            case .delegation: "arrow.triangle.branch"
            case .session: "square.stack.3d.up"
            }
        }
    }

    var id: String = UUID().uuidString
    var date: Date = Date()
    var kind: Kind
    var title: String
    var detail: String?
    var agentID: String?
    var environmentID: String?
    /// Set for activity that happened on a saved machine rather than locally.
    var machine: String?
}
