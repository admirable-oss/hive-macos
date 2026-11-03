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

    /// Oldest daemon this app can drive: `api.snapshot` and agent operations arrived at level 5.
    static let minimumAPILevel = 5

    private let hiveURL: URL
    private var client: HiveSocketClient?
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var portScanTask: Task<Void, Never>?
    private var hasSnapshot = false
    private let decoder = JSONDecoder()

    init(hiveURL: URL) {
        self.hiveURL = hiveURL
    }

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
        let client = HiveSocketClient()
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
            case "pane.closed":
                let id = try decode(HiveIDPayload.self, from: data).id
                panes[id] = nil
                // The pane's agent goes with it; the snapshot below settles the rest.
                scheduleSnapshot()
            case "agent.state":
                let agent = try decode(HiveAgent.self, from: data)
                if agent.isCodingAgent { upsert(agent, into: &agents) }
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

    private func upsert<Item: Identifiable>(_ item: Item, into items: inout [Item]) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    // MARK: Lookups

    /// The terminal process behind an agent's pane, which `terminal.attach` needs.
    func processID(forAgent id: String) -> String? {
        guard let paneID = agents.first(where: { $0.id == id })?.paneID else { return nil }
        return panes[paneID]?.processID
    }

    // MARK: Operations

    @discardableResult
    func createEnvironment(id: String, root: String) async throws -> HiveEnvironment {
        let environment = try decode(HiveEnvironment.self, from: try await call("environment.create", ["id": id, "root": root]))
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
        // The new pane's process arrives with the snapshot; attach needs it.
        scheduleSnapshot()
        return started.agent
    }

    func stopAgent(_ id: String) async throws {
        _ = try await call("agent.stop", ["id": id])
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

    private func call(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let client else { throw HiveSocketError.disconnected }
        return try await client.call(method, params: try JSONSerialization.data(withJSONObject: params))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
