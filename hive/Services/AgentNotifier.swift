import AppKit
import UserNotifications

struct HiveConfigDocument: Decodable {
    struct Notifications: Decodable {
        let on: [String]?
        let system: Bool?
        let agents: [String: [String]]?
    }

    let notify: Notifications?
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
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func apply(_ config: HiveConfigDocument.Notifications?) {
        notifyOn = Set(config?.on ?? ["blocked", "done"])
        notifyByAgent = (config?.agents ?? [:]).mapValues(Set.init)
        systemNotificationsEnabled = config?.system ?? false
        UserDefaults.standard.set(notifyOn.sorted().joined(separator: ", "), forKey: Self.effectiveStatesKey)
        UserDefaults.standard.set(systemNotificationsEnabled, forKey: Self.systemNotificationsKey)
    }

    func agentChanged(from previous: HiveAgent?, to agent: HiveAgent) {
        guard previous?.state != agent.state else { return }
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
