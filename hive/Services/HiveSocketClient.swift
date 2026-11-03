import Darwin
import Foundation

/// An error the daemon returned, with its machine-readable code
/// (`not_found`, `invalid_params`, `unavailable`, …).
nonisolated struct HiveAPIError: LocalizedError, Equatable, Sendable {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

nonisolated enum HiveSocketError: LocalizedError, Sendable {
    case connectFailed(path: String, reason: String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .connectFailed(let path, let reason): "Couldn’t connect to the Hive runtime at \(path): \(reason)"
        case .disconnected: "The connection to the Hive runtime closed."
        }
    }
}

/// What the daemon said in answer to our hello.
nonisolated struct HiveWelcome: Sendable {
    let serverVersion: String
    let capabilities: [String]
}

/// One byte stream on the connection (`events.subscribe`, `terminal.attach`).
/// Bytes from the daemon arrive on `incoming`, which finishes when either side closes.
nonisolated final class HivePipe: @unchecked Sendable {
    let id: String
    let incoming: AsyncStream<Data>

    private let continuation: AsyncStream<Data>.Continuation
    private weak var client: HiveSocketClient?
    private let lock = NSLock()
    private var isClosed = false
    private var _closeError: HiveAPIError?

    /// Why the daemon closed the pipe, when it closed it with an error.
    var closeError: HiveAPIError? { lock.withLock { _closeError } }

    fileprivate init(id: String, client: HiveSocketClient) {
        self.id = id
        self.client = client
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
    }

    func send(_ data: Data) {
        guard !lock.withLock({ isClosed }) else { return }
        client?.sendData(data, on: id)
    }

    /// Ends the pipe from our side.
    func close() {
        guard lock.withLock({ () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }) else { return }
        client?.sendClose(id)
        continuation.finish()
    }

    fileprivate func receive(_ data: Data) {
        continuation.yield(data)
    }

    fileprivate func finish(with error: HiveAPIError?) {
        lock.withLock {
            isClosed = true
            _closeError = error
        }
        continuation.finish()
    }
}

/// A protocol-2 connection to the Hive daemon's Unix socket: newline-delimited JSON,
/// concurrent requests matched by ID, and any number of byte pipes on one socket.
///
/// The client only moves bytes. Callers encode params and decode results themselves,
/// so model types never have to leave the main actor.
nonisolated final class HiveSocketClient: @unchecked Sendable {
    let socketPath: String

    /// Called once, from the reader thread, when the connection ends.
    var onDisconnect: (@Sendable () -> Void)?

    private struct Reply: Sendable {
        let result: Data
        let pipe: HivePipe?
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var nextID = 0
    private var pending: [String: CheckedContinuation<Reply, Error>] = [:]
    private var pipes: [String: HivePipe] = [:]
    private var isOpen = false
    private let writeQueue = DispatchQueue(label: "hive.socket.write")

    /// The largest pipe payload the daemon accepts in one data message.
    private static let pipeChunk = 32 << 10

    init(socketPath: String = HiveSocketClient.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    /// `$HIVE_SOCKET_PATH`, else `$HIVE_HOME/hive.sock`, else `~/.hive/hive.sock`.
    static func defaultSocketPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HIVE_SOCKET_PATH"], !path.isEmpty { return path }
        let home = environment["HIVE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".hive")
        return (home as NSString).appendingPathComponent("hive.sock")
    }

    // MARK: Connection

    func connect(clientVersion: String) async throws -> HiveWelcome {
        let socket = try openSocket()
        lock.withLock {
            fd = socket
            isOpen = true
        }
        let reader = Thread { [self] in readLoop(socket) }
        reader.name = "hive.socket.read"
        reader.start()

        let hello: [String: Any] = [
            "version": "2",
            "type": "hello",
            "id": "hello",
            "params": ["client": "hive-desktop", "client_version": clientVersion],
        ]
        let reply = try await send(JSONSerialization.data(withJSONObject: hello), id: "hello")
        let welcome = (try? JSONSerialization.jsonObject(with: reply.result)) as? [String: Any] ?? [:]
        return HiveWelcome(
            serverVersion: welcome["server_version"] as? String ?? "",
            capabilities: welcome["capabilities"] as? [String] ?? []
        )
    }

    func close() {
        let socket = lock.withLock { isOpen ? fd : -1 }
        if socket >= 0 { shutdown(socket, SHUT_RDWR) }
    }

    // MARK: Requests

    /// Calls `method` with JSON-encoded `params` and returns the raw JSON result.
    func call(_ method: String, params: Data = Data("{}".utf8)) async throws -> Data {
        try await request(method, params: params).result
    }

    /// Calls a pipe method. Returns its result and the pipe it opened.
    func openPipe(_ method: String, params: Data = Data("{}".utf8)) async throws -> (result: Data, pipe: HivePipe) {
        let reply = try await request(method, params: params)
        guard let pipe = reply.pipe else {
            throw HiveAPIError(code: "invalid_response", message: "\(method) didn’t open a stream.")
        }
        return (reply.result, pipe)
    }

    private func request(_ method: String, params: Data) async throws -> Reply {
        let id = lock.withLock { () -> String in
            nextID += 1
            return String(nextID)
        }
        var line = Data(#"{"type":"request","id":"\#(id)","method":"\#(method)","params":"#.utf8)
        line.append(params)
        line.append(Data("}".utf8))
        return try await send(line, id: id)
    }

    private func send(_ message: Data, id: String) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            let accepted = lock.withLock { () -> Bool in
                guard isOpen else { return false }
                pending[id] = continuation
                return true
            }
            guard accepted else {
                continuation.resume(throwing: HiveSocketError.disconnected)
                return
            }
            write(message)
        }
    }

    fileprivate func sendData(_ data: Data, on stream: String) {
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(in: offset..<min(offset + Self.pipeChunk, data.count))
            offset += chunk.count
            write(Data(#"{"type":"data","stream":"\#(stream)","data":"\#(chunk.base64EncodedString())"}"#.utf8))
        }
    }

    fileprivate func sendClose(_ stream: String) {
        write(Data(#"{"type":"close","stream":"\#(stream)"}"#.utf8))
    }

    private func write(_ message: Data) {
        var line = message
        line.append(0x0A)
        writeQueue.async { [self] in
            let socket = lock.withLock { isOpen ? fd : -1 }
            guard socket >= 0 else { return }
            line.withUnsafeBytes { buffer in
                var sent = 0
                while sent < buffer.count {
                    let written = Darwin.write(socket, buffer.baseAddress! + sent, buffer.count - sent)
                    if written > 0 {
                        sent += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        shutdown(socket, SHUT_RDWR)
                        return
                    }
                }
            }
        }
    }

    // MARK: Reading

    private func readLoop(_ socket: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(socket, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(chunk, count: count)

            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                handle(buffer[lineStart..<newline])
                lineStart = buffer.index(after: newline)
            }
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        tearDown(socket)
    }

    private func handle(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = message["type"] as? String else { return }

        switch type {
        case "response", "welcome":
            guard let id = message["id"] as? String,
                  let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
            if let error = Self.apiError(message["error"]) {
                continuation.resume(throwing: error)
                return
            }
            let result = message["result"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) }
                ?? Data("{}".utf8)
            var pipe: HivePipe?
            if let stream = message["stream"] as? String {
                // Register before resuming: the pipe's first data may be in the very next line.
                let opened = HivePipe(id: stream, client: self)
                lock.withLock { pipes[stream] = opened }
                pipe = opened
            }
            continuation.resume(returning: Reply(result: result, pipe: pipe))

        case "data":
            guard let stream = message["stream"] as? String,
                  let encoded = message["data"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let pipe = lock.withLock({ pipes[stream] }) else { return }
            pipe.receive(data)

        case "close":
            guard let stream = message["stream"] as? String,
                  let pipe = lock.withLock({ pipes.removeValue(forKey: stream) }) else { return }
            pipe.finish(with: Self.apiError(message["error"]))

        default:
            break
        }
    }

    private static func apiError(_ value: Any?) -> HiveAPIError? {
        guard let error = value as? [String: Any] else { return nil }
        return HiveAPIError(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "Hive returned an error.")
    }

    private func tearDown(_ socket: Int32) {
        let (waiting, open) = lock.withLock { () -> ([CheckedContinuation<Reply, Error>], [HivePipe]) in
            isOpen = false
            fd = -1
            defer {
                pending.removeAll()
                pipes.removeAll()
            }
            return (Array(pending.values), Array(pipes.values))
        }
        Darwin.close(socket)
        waiting.forEach { $0.resume(throwing: HiveSocketError.disconnected) }
        open.forEach { $0.finish(with: nil) }
        onDisconnect?()
    }

    private func openSocket() throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw HiveSocketError.connectFailed(path: socketPath, reason: String(cString: strerror(errno))) }

        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socket)
            throw HiveSocketError.connectFailed(path: socketPath, reason: "The socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(socket)
            throw HiveSocketError.connectFailed(path: socketPath, reason: reason)
        }
        return socket
    }
}
