import Foundation

enum HiveInstallationService {
    private static let installerURL = URL(string: "https://hive.admir-saheta.com/install.sh")!
    private static let selectedBinaryKey = "hive.binaryPath"

    static func locateInstalledHive() async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: locateInstalledHiveSynchronously())
            }
        }
    }

    static func verifyHive(at url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: verifyHiveSynchronously(at: url))
            }
        }
    }

    static func installHive() async throws -> URL {
        let (scriptData, response) = try await URLSession.shared.data(from: installerURL)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              scriptData.count <= 1_048_576 else {
            throw HiveInstallationError.downloadFailed
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-installer-\(UUID().uuidString).sh")
        try scriptData.write(to: scriptURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-installer-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw HiveInstallationError.couldNotStart
        }
        defer { try? FileManager.default.removeItem(at: logURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log

        do {
            try process.run()
        } catch {
            try? log.close()
            throw HiveInstallationError.couldNotStart
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        try? log.close()

        guard exitCode == 0 else {
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw HiveInstallationError.installFailed(output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let hive = await locateInstalledHive() else {
            throw HiveInstallationError.installSucceededButNotFound
        }
        return hive
    }

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: selectedBinaryKey)
    }

    private static func locateInstalledHiveSynchronously() -> URL? {
        var candidates: [URL] = []
        let environment = ProcessInfo.processInfo.environment

        if let remembered = UserDefaults.standard.string(forKey: selectedBinaryKey) {
            candidates.append(URL(fileURLWithPath: remembered))
        }
        if let configured = environment["HIVE_BIN"], !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("hive"))
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("hive")
            }
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/hive"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/hive"))
        candidates.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/hive"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/hive"))
        candidates.append(URL(fileURLWithPath: "/bin/hive"))

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            if verifyHiveSynchronously(at: candidate) { return candidate.standardizedFileURL }
        }
        return nil
    }

    private static func verifyHiveSynchronously(at url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-version-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { return false }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = url
        process.arguments = ["version"]
        process.standardOutput = output
        process.standardError = output

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            try? output.close()
            return false
        }

        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            try? output.close()
            return false
        }
        try? output.close()

        let versionOutput = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return process.terminationStatus == 0 && versionOutput.localizedCaseInsensitiveContains("hive")
    }
}

private enum HiveInstallationError: LocalizedError {
    case downloadFailed
    case couldNotStart
    case installFailed(output: String)
    case installSucceededButNotFound

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            "The Hive installer could not be downloaded. Check your internet connection and try again."
        case .couldNotStart:
            "The Hive installer could not be started."
        case .installFailed(let output):
            output.isEmpty ? "The Hive installer stopped with an error." : output
        case .installSucceededButNotFound:
            "The installer finished, but Hive could not be found. Open the install instructions to check the install location."
        }
    }
}
