import Darwin
import Foundation

struct ListeningPort: Identifiable, Hashable {
    let pid: Int32
    let port: Int
    let command: String

    var id: String { "\(pid):\(port)" }
}

/// Finds TCP ports that processes running inside an environment's folder are listening on.
enum PortScanner {
    private static let lsof = HiveCLIService(executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"))

    /// Returns listening ports keyed by environment ID.
    static func listeningPorts(in environments: [HiveEnvironment]) async -> [String: [ListeningPort]] {
        guard !environments.isEmpty,
              // lsof exits non-zero when nothing is listening.
              let listening = try? await lsof.run(["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]) else { return [:] }

        let ports = parseListening(listening)
        guard !ports.isEmpty else { return [:] }

        let pids = Set(ports.map(\.pid)).map(String.init).joined(separator: ",")
        guard let cwdOutput = try? await lsof.run(["-a", "-d", "cwd", "-Fpn", "-p", pids]) else { return [:] }
        let workingDirectories = parseWorkingDirectories(cwdOutput)

        // Longest path first, so a process in a nested environment belongs to that one.
        let candidates = environments.sorted { $0.path.count > $1.path.count }
        var result: [String: [ListeningPort]] = [:]
        for port in ports {
            guard let cwd = workingDirectories[port.pid],
                  let environment = candidates.first(where: { cwd == $0.path || cwd.hasPrefix($0.path + "/") })
            else { continue }
            result[environment.id, default: []].append(port)
        }
        return result.mapValues { $0.sorted { $0.port < $1.port } }
    }

    /// Sends SIGTERM to every process holding one of the ports.
    static func kill(_ ports: [ListeningPort]) throws {
        for pid in Set(ports.map(\.pid)) where Darwin.kill(pid, SIGTERM) != 0 {
            throw PortScannerError.killFailed(pid: pid, code: errno)
        }
    }

    private static func parseListening(_ output: String) -> [ListeningPort] {
        var ports: Set<ListeningPort> = []
        var pid: Int32?
        var command = ""
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p": pid = Int32(value)
            case "c": command = String(value)
            case "n":
                guard let pid, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                ports.insert(ListeningPort(pid: pid, port: port, command: command))
            default: continue
            }
        }
        return Array(ports)
    }

    private static func parseWorkingDirectories(_ output: String) -> [Int32: String] {
        var directories: [Int32: String] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p": pid = Int32(value)
            case "n": if let pid { directories[pid] = String(value) }
            default: continue
            }
        }
        return directories
    }
}

private enum PortScannerError: LocalizedError {
    case killFailed(pid: Int32, code: Int32)

    var errorDescription: String? {
        switch self {
        case .killFailed(let pid, let code):
            "Couldn’t stop process \(pid): \(String(cString: strerror(code)))"
        }
    }
}
