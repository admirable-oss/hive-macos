import Foundation

struct HiveCLIService {
    let executableURL: URL
    var sessionName: String?

    /// Runs the executable and returns its standard output. `input`, when given,
    /// is written to the process's standard input and then closed.
    func run(_ arguments: [String], input: String? = nil) async throws -> String {
        let commandArguments = (sessionName.map { ["--session", $0] } ?? []) + arguments
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = executableURL
                process.arguments = commandArguments
                process.standardOutput = output
                process.standardError = errors
                let inputPipe = input == nil ? nil : Pipe()
                if let inputPipe { process.standardInput = inputPipe }

                do {
                    try process.run()
                    if let inputPipe, let input {
                        inputPipe.fileHandleForWriting.write(Data(input.utf8))
                        try? inputPipe.fileHandleForWriting.close()
                    }
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
