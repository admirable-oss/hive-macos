import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import UserNotifications

/// Updates the app itself from its GitHub releases. An update installs only when:
/// the release's `checksums.txt` carries a valid SSH signature from the release key (as Hive's own
/// releases do), the download matches its checksum there, and the new app is signed by the same
/// Developer ID team as this one and passes Gatekeeper. The previous version is kept, and a
/// helper puts it back if the new one doesn't start. Agents never stop: they run in Hive's daemon.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let automaticChecksKey = "hive.updates.automatic"
    private static let lastCheckKey = "hive.updates.lastCheck"
    private static let notifiedVersionKey = "hive.updates.notifiedVersion"
    private static let releasesURL = URL(string: "https://api.github.com/repos/admirable-oss/hive-macos/releases/latest")!

    struct Release: Equatable {
        let version: String
        let tag: String
        let notes: String
        let pageURL: URL
        let archiveURL: URL?
        let checksumsURL: URL?
        let signatureURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)
        case verifying(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var currentBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    private var scheduleTask: Task<Void, Never>?

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: Checking

    /// Checks once a day while automatic checks are on, and tells the user once per new version.
    func startAutomaticChecks() {
        guard scheduleTask == nil else { return }
        scheduleTask = Task {
            while !Task.isCancelled {
                let enabled = UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
                let due = (lastChecked.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true)
                if enabled && due {
                    await check()
                    if case .available(let release) = state { notifyOnce(release) }
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check() async {
        switch state {
        case .downloading, .verifying, .installing: return
        default: break
        }
        state = .checking
        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                // No release published yet.
                return finishCheck(.upToDate)
            }
            let release = try Self.parseRelease(data)
            finishCheck(Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate)
        } catch {
            finishCheck(.failed("Couldn’t check for updates: \(error.localizedDescription)"))
        }
    }

    private func finishCheck(_ state: State) {
        self.state = state
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
    }

    static func parseRelease(_ data: Data) throws -> Release {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let url: URL
                enum CodingKeys: String, CodingKey { case name; case url = "browser_download_url" }
            }
            let tagName: String
            let body: String?
            let htmlURL: URL
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case body, assets
                case tagName = "tag_name"
                case htmlURL = "html_url"
            }
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        func asset(_ name: String) -> URL? { payload.assets.first(where: { $0.name == name })?.url }
        return Release(
            version: version,
            tag: payload.tagName,
            notes: payload.body ?? "",
            pageURL: payload.htmlURL,
            archiveURL: asset("Hive-\(version).zip"),
            checksumsURL: asset("checksums.txt"),
            signatureURL: asset("checksums.txt.sshsig")
        )
    }

    /// Semantic versions: numbers compared in order; a pre-release sorts before its release.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> (numbers: [Int], prerelease: String?) {
            let split = version.split(separator: "-", maxSplits: 1).map(String.init)
            return (split[0].split(separator: ".").map { Int($0) ?? 0 }, split.count > 1 ? split[1] : nil)
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, .some): return true
        case (.some(let x), .some(let y)): return x.compare(y, options: .numeric) == .orderedDescending
        default: return false
        }
    }

    private func notifyOnce(_ release: Release) {
        guard UserDefaults.standard.string(forKey: Self.notifiedVersionKey) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: Self.notifiedVersionKey)
        let content = UNMutableNotificationContent()
        content.title = "Hive Desktop \(release.version) is available"
        content.body = "Install it from Hive → Check for Updates. Your agents keep running."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "app-update", content: content, trigger: nil))
    }

    // MARK: Where the app lives

    /// Why this copy can't replace itself, if it can't.
    var installBlocker: String? {
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") {
            return "Move Hive to your Applications folder first; macOS runs it from a temporary copy until you do."
        }
        guard Self.teamIdentifier(of: Bundle.main.bundleURL) != nil else {
            return "This copy isn’t a signed release (it was built from source), so it can’t update itself. Download the release instead."
        }
        guard FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
            return "Hive can’t write to \(Bundle.main.bundleURL.deletingLastPathComponent().path). Download the release instead."
        }
        return nil
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hive Desktop", isDirectory: true)
    }

    static var previousVersionURL: URL { supportDirectory.appendingPathComponent("Previous/Hive.app") }

    var previousVersion: String? {
        Bundle(url: Self.previousVersionURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Written once the app has started, so an update helper knows the new version runs.
    static func markLaunched() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: supportDirectory.appendingPathComponent("launched-\(version)").path, contents: Data())
    }

    // MARK: Installing

    func install(_ release: Release) async {
        if let installBlocker { return state = .failed(installBlocker) }
        guard let archiveURL = release.archiveURL, let checksumsURL = release.checksumsURL else {
            return state = .failed("This release has no app archive or checksums; download it from its page instead.")
        }
        guard let signatureURL = release.signatureURL else {
            return state = .failed("This release isn’t signed, so Hive won’t install it.")
        }
        do {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("hive-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            state = .downloading(release, 0)
            let checksums = try await download(checksumsURL, to: work.appendingPathComponent("checksums.txt"))
            let signature = try await download(signatureURL, to: work.appendingPathComponent("checksums.txt.sshsig"))
            let archive = try await download(archiveURL, to: work.appendingPathComponent(archiveURL.lastPathComponent)) { fraction in
                self.state = .downloading(release, fraction)
            }

            state = .verifying(release)
            try await Self.verifySignature(checksums: checksums, signature: signature)
            try Self.verifyChecksum(of: archive, listedIn: checksums)
            let extracted = work.appendingPathComponent("extracted")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("The download has no app in it.")
            }
            try await Self.verifyApp(newApp, expectedVersion: release.version)

            state = .installing(release)
            try relaunch(into: newApp, expectedVersion: release.version)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Puts the version that was replaced back.
    func restorePreviousVersion() {
        guard let version = previousVersion else { return }
        do {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("hive-restore-\(UUID().uuidString)/Hive.app")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Self.previousVersionURL, to: copy)
            try relaunch(into: copy, expectedVersion: version)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Hands over to a helper that waits for this app to quit, keeps it as the previous version,
    /// moves the new one into place and opens it. If the new one hasn't marked itself launched
    /// within 30 seconds, the helper puts the previous one back and opens that instead.
    private func relaunch(into newApp: URL, expectedVersion: String) throws {
        let current = Bundle.main.bundleURL
        try FileManager.default.createDirectory(at: Self.previousVersionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Self.supportDirectory.appendingPathComponent("launched-\(expectedVersion)")
        try? FileManager.default.removeItem(at: marker)

        let script = Self.supportDirectory.appendingPathComponent("update.sh")
        try Self.helperScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), current.path, newApp.path,
                             Self.previousVersionURL.path, marker.path, Self.supportDirectory.appendingPathComponent("update.log").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    private static let helperScript = #"""
    #!/bin/bash
    # Hive Desktop's update helper: swap the app in, keep the old one, roll back if the new one doesn't start.
    pid="$1"; app="$2"; new="$3"; previous="$4"; marker="$5"; log="$6"
    exec >>"$log" 2>&1
    echo "$(date) updating $app from $new"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    rm -rf "$previous" && ditto "$app" "$previous" || { echo "couldn't keep the previous version"; open "$app"; exit 1; }
    staging="$app.updating"
    rm -rf "$staging"
    ditto "$new" "$staging" && rm -rf "$app" && mv "$staging" "$app" || { echo "couldn't move the new version in"; rm -rf "$staging"; [ -d "$app" ] || ditto "$previous" "$app"; open "$app"; exit 1; }
    xattr -dr com.apple.quarantine "$app" 2>/dev/null
    open "$app"
    for _ in $(seq 1 60); do [ -f "$marker" ] && { echo "updated"; exit 0; }; sleep 0.5; done
    echo "the new version didn't start; restoring the previous one"
    pkill -f "$app/Contents/MacOS/" 2>/dev/null; sleep 1
    rm -rf "$app" && ditto "$previous" "$app" && open "$app"
    """#

    // MARK: Verifying

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The release key from Info.plist (`HiveReleaseAllowedSigners`), as an allowed_signers line.
    nonisolated static var releaseAllowedSigners: String? {
        (Bundle.main.object(forInfoDictionaryKey: "HiveReleaseAllowedSigners") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `ssh-keygen -Y verify` of checksums.txt against the release key.
    static func verifySignature(checksums: URL, signature: URL, allowedSigners: String? = releaseAllowedSigners) async throws {
        guard let signers = allowedSigners else {
            throw UpdateError("This build has no release key to check updates against.")
        }
        let allowed = checksums.deletingLastPathComponent().appendingPathComponent("allowed_signers")
        try (signers + "\n").write(to: allowed, atomically: true, encoding: .utf8)
        do {
            try await run("/usr/bin/ssh-keygen", ["-Y", "verify", "-f", allowed.path, "-I", "hive-release", "-n", "hive-release", "-s", signature.path], input: checksums)
        } catch {
            throw UpdateError("The release’s signature doesn’t match the Hive release key; not installing it.")
        }
    }

    static func verifyChecksum(of file: URL, listedIn checksums: URL) throws {
        let listing = try String(contentsOf: checksums, encoding: .utf8)
        let name = file.lastPathComponent
        guard let expected = listing.split(whereSeparator: \.isNewline)
            .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
            .first(where: { $0.count >= 2 && $0.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) } == name })?
            .first else {
            throw UpdateError("checksums.txt doesn’t list \(name).")
        }
        guard try sha256(of: file) == expected.lowercased() else {
            throw UpdateError("The download doesn’t match its checksum; it may be damaged or tampered with.")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The new app's signature is intact, from this app's team, accepted by Gatekeeper, and the version promised.
    private static func verifyApp(_ app: URL, expectedVersion: String) async throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The new app can’t be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw UpdateError("The new app’s code signature isn’t valid.")
        }
        guard let team = teamIdentifier(of: app), team == teamIdentifier(of: Bundle.main.bundleURL) else {
            throw UpdateError("The new app isn’t signed by the same developer as this one.")
        }
        do { try await run("/usr/sbin/spctl", ["--assess", "--type", "exec", app.path]) }
        catch { throw UpdateError("Gatekeeper doesn’t accept the new app (is it notarized?).") }
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == expectedVersion else {
            throw UpdateError("The download is version \(version ?? "unknown"), not \(expectedVersion).")
        }
    }

    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: Helpers

    private func download(_ url: URL, to destination: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Couldn’t download \(url.lastPathComponent).") }
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress?(Double(received) / Double(expected)) }
            }
        }
        try handle.write(contentsOf: buffer)
        progress?(1)
        return destination
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String], input: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                process.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let text = String(decoding: data, as: UTF8.self)
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: UpdateError(text.isEmpty ? "\(executable) failed." : text))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
