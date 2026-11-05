import AppKit
@preconcurrency import UserNotifications

struct HiveConfigDocument: Decodable {
    struct Notifications: Decodable {
        let on: [String]?
        let system: Bool?
        let agents: [String: [String]]?
    }

    struct Keys: Decodable {
        let command: [HiveKeyCommand]?
    }

    let notify: Notifications?
    let keys: Keys?
}

/// One `[[keys.command]]` entry: a command the TUI runs on a key.
struct HiveKeyCommand: Decodable, Hashable, Identifiable {
    let keys: [String]?
    /// popup, pane, shell or plugin_action.
    let type: String
    let command: String?
    let mode: String?

    var id: String { "\(type):\(keys?.joined(separator: ",") ?? ""):\(command ?? "")" }

    /// Plugin actions wait for plugin support; the rest run from the Commands menu.
    var isSupported: Bool {
        ["popup", "pane", "shell"].contains(type) && !(command ?? "").isEmpty
    }

    var title: String { command ?? type }

    /// A single-character TUI key becomes ⌃⌥ plus that key in the app.
    var shortcutKey: Character? {
        guard let key = keys?.first, key.count == 1, let character = key.first,
              character.isLetter || character.isNumber else { return nil }
        return Character(character.lowercased())
    }
}

/// Tells the user when an agent needs them or has finished, with Approve and Deny
/// right on the notification, and keeps the Dock badge at the number of blocked agents.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AgentNotifier()

    static let effectiveStatesKey = "hive.notify.effective.states"
    static let systemNotificationsKey = "hive.notify.effective.system"

    /// Whether the agent is on screen right now; Hive never notifies about the pane you're in.
    var isShowing: (HiveAgent) -> Bool = { _ in false }
    var onOpen: (String) -> Void = { _ in }
    var onKeys: (String, [String]) -> Void = { _, _ in }

    private let center = UNUserNotificationCenter.current()
    private var isConfigured = false
    private var notifyOn: Set<String> = ["blocked", "done"]
    private var notifyByAgent: [String: Set<String>] = [:]
    private var systemNotificationsEnabled = false
    private var lastStateByAgent: [String: String] = [:]
    private var authorizationCheckInFlight = false

    private enum Identifier {
        static let blockedCategory = "agent.blocked"
        static let doneCategory = "agent.done"
        static let approve = "approve"
        static let deny = "deny"
        static let open = "open"
        static let agentKey = "agent"
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        let approve = UNNotificationAction(identifier: Identifier.approve, title: "Approve")
        let deny = UNNotificationAction(identifier: Identifier.deny, title: "Deny", options: [.destructive])
        let open = UNNotificationAction(identifier: Identifier.open, title: "Open")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Identifier.blockedCategory, actions: [approve, deny, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Identifier.doneCategory, actions: [open], intentIdentifiers: []),
        ])
    }

    func apply(_ config: HiveConfigDocument.Notifications?) {
        notifyOn = Set(config?.on ?? ["blocked", "done"])
        notifyByAgent = (config?.agents ?? [:]).mapValues(Set.init)
        systemNotificationsEnabled = config?.system ?? false
        UserDefaults.standard.set(notifyOn.sorted().joined(separator: ", "), forKey: Self.effectiveStatesKey)
        UserDefaults.standard.set(systemNotificationsEnabled, forKey: Self.systemNotificationsKey)
        guard !systemNotificationsEnabled, !authorizationCheckInFlight else { return }
        authorizationCheckInFlight = true
        let notificationCenter = center
        notificationCenter.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else {
                Task { @MainActor [weak self] in self?.authorizationCheckInFlight = false }
                return
            }
            notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                Task { @MainActor [weak self] in self?.authorizationCheckInFlight = false }
            }
        }
    }

    func agentChanged(from previous: HiveAgent?, to agent: HiveAgent) {
        let oldState = lastStateByAgent[agent.id] ?? previous?.state
        lastStateByAgent[agent.id] = agent.state
        guard oldState != agent.state else { return }
        let identifier = "agent-\(agent.id)"
        // Whatever it said before is out of date now.
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        let enabledStates = notifyByAgent[agent.kind] ?? notifyOn
        let wantsState = enabledStates.contains(agent.state)
        guard !systemNotificationsEnabled else { return }
        let wantsBlocked = agent.state == "blocked" && wantsState
        let wantsDone = agent.state == "done" && wantsState
        guard wantsBlocked || wantsDone, !isShowing(agent) else { return }

        let content = UNMutableNotificationContent()
        content.title = agent.name.isEmpty ? agent.kind : agent.name
        content.subtitle = agent.environmentID
        if wantsBlocked {
            content.body = agent.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting for your decision."
            content.categoryIdentifier = Identifier.blockedCategory
            content.interruptionLevel = .timeSensitive
            NSApp.requestUserAttention(.informationalRequest)
        } else {
            content.body = "Finished. Have a look when you’re ready."
            content.categoryIdentifier = Identifier.doneCategory
        }
        content.sound = .default
        content.threadIdentifier = agent.environmentID
        content.userInfo = [Identifier.agentKey: agent.id]
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Tells the user an agent watch they set ("notify me when…") has ended, however it ended.
    func notifyWatchEnded(agent: HiveAgent, condition: String, outcome: String) {
        let content = UNMutableNotificationContent()
        content.title = agent.name.isEmpty ? agent.kind : agent.name
        content.subtitle = agent.environmentID
        content.body = switch outcome {
        case "reached": "Now \(condition), as you asked to hear."
        case "stalled": "Hasn’t changed its screen for a while — it may be stuck."
        case "blocked": "Stopped to wait for your decision."
        case "exited": "Exited."
        default: "Stopped waiting: \(outcome)."
        }
        content.categoryIdentifier = agent.state == "blocked" ? Identifier.blockedCategory : Identifier.doneCategory
        content.sound = .default
        content.threadIdentifier = agent.environmentID
        content.userInfo = [Identifier.agentKey: agent.id]
        center.add(UNNotificationRequest(identifier: "watch-\(agent.id)", content: content, trigger: nil))
    }

    func resetStateTracking() {
        lastStateByAgent.removeAll()
    }

    func updateBadge(for agents: [HiveAgent]) {
        let blocked = agents.filter { $0.state == "blocked" }.count
        NSApp.dockTile.badgeLabel = blocked == 0 ? nil : String(blocked)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show it even while Hive is in front: the agent is in another tab.
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let agentID = response.notification.request.content.userInfo["agent"] as? String
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let agentID else { return }
            switch action {
            // Permission dialogs default to "yes": Enter accepts, Escape declines.
            case Identifier.approve: onKeys(agentID, ["Enter"])
            case Identifier.deny: onKeys(agentID, ["Escape"])
            case Identifier.open: onOpen(agentID)
            default: onOpen(agentID)
            }
        }
    }
}
