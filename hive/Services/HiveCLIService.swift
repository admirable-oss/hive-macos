import Foundation

struct HiveCLIService {
    let executableURL: URL

    func run(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = errors

                do {
                    try process.run()
                    let stdout = output.fileHandleForReading.readDataToEndOfFile()
                    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(data: stdout, encoding: .utf8) ?? ""
                    guard process.terminationStatus == 0 else {
                        let message = String(data: stderr, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw HiveCLIError.commandFailed(message?.isEmpty == false ? message! : "Hive command failed.")
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum HiveCLIError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        }
    }
}
