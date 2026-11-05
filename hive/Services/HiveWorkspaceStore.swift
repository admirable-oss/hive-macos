import Combine
import Foundation

/// The daemon's workspace, kept live over one socket connection: a snapshot on
/// connect, then the event stream. Every view reads Hive state from here.
@MainActor
final class HiveWorkspaceStore: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case connected(version: String, apiLevel: Int)
        case unavailable(String)
    }

    @Published private(set) var connection: Connection = .connecting
    @Published private(set) var environments: [HiveEnvironment] = []
    @Published private(set) var agents: [HiveAgent] = []
    @Published private(set) var tabs: [HiveTab] = []
    @Published private(set) var panes: [String: HivePane] = [:]
    @Published private(set) var processes: [String: HiveProcess] = [:]
    @Published private(set) var agentKinds: [HiveAgentManifest] = []
    @Published private(set) var listeningPorts: [String: [ListeningPort]] = [:]

    /// Called after every snapshot is applied, with whether it was the first one.
    var onSnapshot: ((_ isFirst: Bool) -> Void)?
    /// Called when an `agent.state` event changes an agent, with its previous record.
    var onAgentChange: ((_ previous: HiveAgent?, _ agent: HiveAgent) -> Void)?

    /// Whether at least one snapshot has been applied since launch.
    private(set) var hasSnapshot = false

    /// Oldest daemon this app can drive: `api.snapshot` and agent operations arrived at level 5.
    static let minimumAPILevel = 5

    private let hiveURL: URL
    private var client: HiveSocketClient?
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var portScanTask: Task<Void, Never>?
    private let decoder = JSONDecoder()

    init(hiveURL: URL, sessionName: String = "default") {
        self.hiveURL = hiveURL
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HIVE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hive")
        let root = sessionName == "default" ? home : (home as NSString).appendingPathComponent("sessions/\(sessionName)")
        socketPath = sessionName == "default"
            ? (environment["HIVE_SOCKET_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? (root as NSString).appendingPathComponent("hive.sock"))
            : (root as NSString).appendingPathComponent("hive.sock")
    }

    private let socketPath: String

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    // MARK: Lifecycle

    func start() {
        guard connectionTask == nil else { return }
        connectionTask = Task { await connectionLoop() }
        portScanTask = Task {
            while !Task.isCancelled {
                await refreshPorts()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Ports aren't Hive state, so they're scanned rather than streamed.
    func refreshPorts() async {
        listeningPorts = await PortScanner.listeningPorts(in: environments)
    }

    func stop() {
        connectionTask?.cancel()
        portScanTask?.cancel()
        refreshTask?.cancel()
        client?.close()
        connectionTask = nil
        portScanTask = nil
    }

    /// Stays connected: on any drop, reconnects with backoff. Starts the daemon if it isn't running.
    private func connectionLoop() async {
        var delay: Duration = .milliseconds(500)
        var startedDaemon = false
        while !Task.isCancelled {
            if !isConnected { connection = .connecting }
            do {
                try await connectAndRun()
                delay = .milliseconds(500)
            } catch {
                if !startedDaemon, case HiveSocketError.connectFailed = error {
                    // The CLI starts the daemon on demand; the socket doesn't.
                    startedDaemon = true
                    _ = try? await HiveCLIService(executableURL: hiveURL).run(["--json", "env", "list"])
                    continue
                }
                connection = .unavailable(error.localizedDescription)
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }
    }

    /// One connection's life: hello, subscribe, snapshot, then apply events until it drops.
    private func connectAndRun() async throws {
        let client = HiveSocketClient(socketPath: socketPath)
        defer {
            client.close()
            if self.client === client { self.client = nil }
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        _ = try await client.connect(clientVersion: version)
        self.client = client

        // Subscribe before the snapshot so nothing that happens in between is missed;
        // applying an event the snapshot already reflects is harmless.
        let events = try await client.openPipe("events.subscribe")
        try await loadSnapshot(from: client)
        agentKinds = (try? await decode([HiveAgentManifest].self, from: client.call("agent.manifests"))) ?? agentKinds

        var pending = Data()
        for await chunk in events.pipe.incoming {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                apply(eventLine: pending[lineStart..<newline])
                lineStart = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
        throw events.pipe.closeError ?? HiveSocketError.disconnected
    }

    private func loadSnapshot(from client: HiveSocketClient) async throws {
        let snapshot = try decode(HiveAPISnapshot.self, from: try await client.call("api.snapshot"))
        guard snapshot.daemon.apiLevel >= Self.minimumAPILevel else {
            throw HiveAPIError(
                code: "unsupported",
                message: "Hive \(snapshot.daemon.version) is too old for this app. Run `hive update`, then `hive stop`."
            )
        }
        environments = snapshot.environments
        // The snapshot also tracks plain shells as kindless "agents"; `agent list` leaves them out too.
        agents = snapshot.agents.filter(\.isCodingAgent)
        tabs = snapshot.tabs
        panes = Dictionary(snapshot.panes.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        processes = Dictionary(snapshot.processes.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        connection = .connected(version: snapshot.daemon.version, apiLevel: snapshot.daemon.apiLevel)

        let isFirst = !hasSnapshot
        hasSnapshot = true
        onSnapshot?(isFirst)
    }

    /// Re-reads the whole workspace shortly after, coalescing bursts of events.
    private func scheduleSnapshot() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let client else { return }
            try? await loadSnapshot(from: client)
        }
    }

    // MARK: Events

    private func apply(eventLine line: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = event["type"] as? String else { return }
        let data = event["data"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) } ?? Data()

        do {
            switch type {
            case "environment.created", "environment.updated":
                upsert(try decode(HiveEnvironment.self, from: data), into: &environments)
            case "environment.removed":
                let id = try decode(HiveIDPayload.self, from: data).id
                environments.removeAll { $0.id == id }
            case "environment.git":
                let update = try decode(HiveEnvironmentGitUpdate.self, from: data)
                if let index = environments.firstIndex(where: { $0.id == update.id }) {
                    environments[index].git = update.git
                }
            case "process.started", "process.exited", "process.recovered":
                let process = try decode(HiveProcess.self, from: data)
                processes[process.id] = process
            case "tab.created", "tab.updated":
                upsert(try decode(HiveTab.self, from: data), into: &tabs)
            case "tab.closed":
                let id = try decode(HiveIDPayload.self, from: data).id
                tabs.removeAll { $0.id == id }
            case "pane.created", "pane.updated", "pane.moved", "pane.focused":
                let pane = try decode(HivePane.self, from: data)
                panes[pane.id] = pane
                // Pane events carry focus on the pane; the tab only learns it on its next update.
                if pane.focused == true { noteFocus(pane.id, inTab: pane.tabID) }
            case "pane.closed":
                let id = try decode(HiveIDPayload.self, from: data).id
                panes[id] = nil
                // The pane's agent goes with it; the snapshot below settles the rest.
                scheduleSnapshot()
            case "agent.state":
                let agent = try decode(HiveAgent.self, from: data)
                if agent.isCodingAgent {
                    let previous = agents.first(where: { $0.id == agent.id })
                    upsert(agent, into: &agents)
                    if previous != agent { onAgentChange?(previous, agent) }
                }
            case "process.output":
                break
            default:
                // events_lost, or something this build doesn't model yet.
                scheduleSnapshot()
            }
        } catch {
            scheduleSnapshot()
        }
    }

    private func noteFocus(_ paneID: String, inTab tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].focused != paneID else { return }
        tabs[index].focused = paneID
    }

    private func upsert<Item: Identifiable>(_ item: Item, into items: inout [Item]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    // MARK: Lookups

    func tab(_ id: String) -> HiveTab? {
        tabs.first(where: { $0.id == id })
    }

    /// The agent running in a pane, if any.
    func agent(inPane paneID: String) -> HiveAgent? {
        agents.first(where: { $0.paneID == paneID })
    }

    func process(forPane paneID: String) -> HiveProcess? {
        panes[paneID].flatMap { processes[$0.processID] }
    }

    // MARK: Operations

    @discardableResult
    func createEnvironment(id: String, root: String) async throws -> HiveEnvironment {
        let environment = try decode(HiveEnvironment.self, from: try await call("environment.create", ["id": id, "root": root]))
        upsert(environment, into: &environments)
        return environment
    }

    @discardableResult
    func createWorktree(repo: String, branch: String, base: String? = nil) async throws -> HiveEnvironment {
        var params: [String: Any] = ["repo": repo, "branch": branch]
        if let base, !base.isEmpty { params["base"] = base }
        let environment = try decode(HiveEnvironment.self, from: try await call("worktree.create", params))
        upsert(environment, into: &environments)
        return environment
    }

    func removeEnvironment(_ id: String) async throws {
        _ = try await call("environment.remove", ["id": id])
        environments.removeAll { $0.id == id }
    }

    func startAgent(kind: String, environmentID: String) async throws -> HiveAgent {
        let started = try decode(HiveAgentStarted.self, from: try await call("agent.start", ["kind": kind, "environment_id": environmentID]))
        upsert(started.agent, into: &agents)
        upsert(started.tab, into: &tabs)
        panes[started.pane.id] = started.pane
        // The new pane's process arrives with the snapshot; attach needs it.
        scheduleSnapshot()
        return started.agent
    }

    func stopAgent(_ id: String) async throws {
        _ = try await call("agent.stop", ["id": id])
    }

    func taskSummaries() async throws -> [HiveTaskSummary] {
        try decode([HiveTaskSummary].self, from: try await call("task.list", [:]))
    }

    func taskPlan(_ id: String) async throws -> HiveTaskPlan {
        try decode(HiveTaskPlan.self, from: try await call("task.get", ["id": id]))
    }

    func runTaskPlan(toml: String, source: String) async throws -> HiveTaskPlan {
        let params = try JSONSerialization.data(withJSONObject: ["toml": toml, "source": source])
        return try decode(HiveTaskPlan.self, from: try await callRaw("task.run", params))
    }

    func updateTask(_ method: String, planID: String, taskID: String, deny: Bool? = nil) async throws -> HiveTaskPlan {
        var params: [String: Any] = ["id": planID, "task": taskID]
        if let deny { params["deny"] = deny }
        return try decode(HiveTaskPlan.self, from: try await call(method, params))
    }

    func exportLayout() async throws -> Data {
        try await call("layout.export", ["environments": [String]()])
    }

    func applyLayout(_ data: Data) async throws {
        _ = try await callRaw("layout.apply", data)
        scheduleSnapshot()
    }

    func observerList() async throws -> HiveObserverList {
        try decode(HiveObserverList.self, from: try await call("observer.list", [:]))
    }

    func createObserver(name: String, all: Bool, environments: [String], screens: Bool, ttlSeconds: Int) async throws -> HiveObserverCreated {
        let scope: [String: Any] = all ? ["all": true] : ["environments": environments]
        return try decode(HiveObserverCreated.self, from: try await call("observer.create", [
            "name": name, "scope": scope, "screens": screens, "ttl_seconds": ttlSeconds,
        ]))
    }

    func revokeObserver(_ id: String) async throws {
        _ = try await call("observer.revoke", ["id": id])
    }

    func observerAudit(limit: Int = 100) async throws -> [HiveObserverAuditEntry] {
        try decode([HiveObserverAuditEntry].self, from: try await call("observer.audit", ["limit": limit]))
    }

    func resumeAgent(_ id: String) async throws -> HiveAgent {
        let started = try decode(HiveAgentStarted.self, from: try await call("agent.resume", ["id": id]))
        upsert(started.agent, into: &agents)
        upsert(started.tab, into: &tabs)
        panes[started.pane.id] = started.pane
        scheduleSnapshot()
        return started.agent
    }

    func closePane(_ id: String) async throws {
        _ = try await call("pane.close", ["id": id])
    }

    /// Opens a view of a terminal. The pipe carries painted ANSI out and keystrokes in.
    func attach(processID: String, width: Int, height: Int) async throws -> (view: HiveTerminalView, pipe: HivePipe) {
        guard let client else { throw HiveSocketError.disconnected }
        let params = try JSONSerialization.data(withJSONObject: ["process_id": processID, "width": width, "height": height])
        let opened = try await client.openPipe("terminal.attach", params: params)
        return (try decode(HiveTerminalView.self, from: opened.result), opened.pipe)
    }

    func resize(processID: String, viewID: String, width: Int, height: Int) async throws {
        _ = try await call("terminal.resize", ["process_id": processID, "view_id": viewID, "width": width, "height": height])
    }

    // MARK: Tabs and panes

    @discardableResult
    func createTab(environmentID: String) async throws -> HiveTab {
        let created = try decode(HiveTabCreated.self, from: try await call("tab.create", ["environment_id": environmentID]))
        upsert(created.tab, into: &tabs)
        panes[created.pane.id] = created.pane
        scheduleSnapshot()
        return created.tab
    }

    func closeTab(_ id: String) async throws {
        _ = try await call("tab.close", ["id": id])
        tabs.removeAll { $0.id == id }
    }

    func renameTab(_ id: String, to name: String) async throws {
        upsert(try decode(HiveTab.self, from: try await call("tab.rename", ["id": id, "name": name])), into: &tabs)
    }

    /// Tells Hive how many cells the desktop shows the tab in, so it lays the panes out for it.
    func resizeTab(_ id: String, width: Int, height: Int) async throws {
        guard width > 0, height > 0 else { return }
        upsert(try decode(HiveTab.self, from: try await call("tab.resize", ["id": id, "width": width, "height": height])), into: &tabs)
    }

    /// Splits a pane: `direction` is where the new pane goes (right, left, down, up).
    func splitPane(_ id: String, direction: String) async throws {
        let pane = try decode(HivePane.self, from: try await call("pane.split", ["pane": id, "direction": direction]))
        panes[pane.id] = pane
        // The tab's new layout and the new process arrive as events; settle anything missed.
        scheduleSnapshot()
    }

    /// Focuses a pane, or with a direction its neighbour that way.
    func focusPane(_ id: String, direction: String? = nil) async throws {
        if direction == nil, let tabID = panes[id]?.tabID ?? tabs.first(where: { $0.paneIDs.contains(id) })?.id {
            noteFocus(id, inTab: tabID)
        }
        var params: [String: Any] = ["id": id]
        if let direction { params["direction"] = direction }
        _ = try await call("pane.focus", params)
    }

    func zoomPane(_ id: String, on: Bool) async throws {
        _ = try await call("pane.zoom", ["id": id, "on": on])
    }

    /// Moves a pane's border by `cells` in `direction`; negative shrinks it.
    func resizePane(_ id: String, direction: String, cells: Int) async throws {
        guard cells != 0 else { return }
        _ = try await call("pane.resize", ["id": id, "direction": direction, "cells": cells])
    }

    func renamePane(_ id: String, to name: String) async throws {
        _ = try await call("pane.rename", ["id": id, "name": name])
    }

    // MARK: Agents

    /// Presses named keys in an agent: Enter, Escape, Up, C-c, y, …
    func sendKeys(toAgent id: String, _ keys: [String]) async throws {
        _ = try await call("agent.send_keys", ["id": id, "keys": keys])
    }

    func prompt(agent id: String, text: String, wait: Bool) async throws -> HivePromptResult {
        var params: [String: Any] = ["id": id, "text": text, "wait": wait]
        if wait { params["read"] = 40 }
        return try decode(HivePromptResult.self, from: try await call("agent.prompt", params))
    }

    func explain(agent id: String) async throws -> HiveAgentExplanation {
        try decode(HiveAgentExplanation.self, from: try await call("agent.explain", ["id": id]))
    }

    /// Marks a finished agent as looked at, so it stops asking for attention.
    func markSeen(agent id: String) async {
        _ = try? await call("agent.seen", ["id": id])
    }

    /// The last lines a pane shows, as plain text.
    func readPane(_ id: String, lines: Int) async throws -> [String] {
        try decode([String].self, from: try await call("pane.read", ["id": id, "lines": lines]))
    }

    /// Hands a PNG to a terminal's program (`terminal.image`): Hive delivers it as an
    /// inline image where the program supports that, or saves it and pastes the path.
    @discardableResult
    func sendImage(png: Data, toProcess processID: String, viewID: String?) async throws -> HiveImageReceipt {
        guard let client else { throw HiveSocketError.disconnected }
        var params: [String: Any] = [
            "process_id": processID,
            "transfer_id": UUID().uuidString.lowercased(),
            "format": "png",
            "size": png.count,
            "sha256": SHA256Hex.digest(png),
        ]
        if let viewID { params["view_id"] = viewID }
        let opened = try await client.openPipe("terminal.image", params: try JSONSerialization.data(withJSONObject: params))
        defer { opened.pipe.close() }
        let early = try decode(HiveImageReceipt.self, from: opened.result)
        if early.done == true { return early }

        opened.pipe.send(png)
        var buffer = Data()
        for await chunk in opened.pipe.incoming {
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                return try decode(HiveImageReceipt.self, from: buffer[buffer.startIndex..<newline])
            }
        }
        throw opened.pipe.closeError ?? HiveAPIError(code: "unavailable", message: "Hive closed the image transfer without a receipt.")
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let client else { throw HiveSocketError.disconnected }
        return try await client.call(method, params: try JSONSerialization.data(withJSONObject: params))
    }

    private func callRaw(_ method: String, _ params: Data) async throws -> Data {
        guard let client else { throw HiveSocketError.disconnected }
        return try await client.call(method, params: params)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
