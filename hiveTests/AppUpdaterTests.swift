import Foundation
import Testing
@testable import hive

@MainActor
struct AppUpdaterTests {
    @Test func comparesVersions() {
        #expect(AppUpdater.isNewer("1.0.1", than: "1.0"))
        #expect(AppUpdater.isNewer("1.10.0", than: "1.9.9"))
        #expect(AppUpdater.isNewer("2.0", than: "1.99.99"))
        #expect(AppUpdater.isNewer("1.0.0", than: "1.0.0-rc.2"))
        #expect(AppUpdater.isNewer("1.0.0-rc.10", than: "1.0.0-rc.2"))
        #expect(!AppUpdater.isNewer("1.0", than: "1.0.0"))
        #expect(!AppUpdater.isNewer("1.0.0-rc.1", than: "1.0.0"))
        #expect(!AppUpdater.isNewer("0.9", than: "1.0"))
    }

    @Test func readsAGitHubRelease() throws {
        let json = """
        {"tag_name": "v1.2.0", "body": "Fixes", "html_url": "https://github.com/admirable-oss/hive-macos/releases/tag/v1.2.0",
         "assets": [
           {"name": "Hive-1.2.0.dmg", "browser_download_url": "https://example.com/Hive-1.2.0.dmg"},
           {"name": "Hive-1.2.0.zip", "browser_download_url": "https://example.com/Hive-1.2.0.zip"},
           {"name": "checksums.txt", "browser_download_url": "https://example.com/checksums.txt"},
           {"name": "checksums.txt.sshsig", "browser_download_url": "https://example.com/checksums.txt.sshsig"}]}
        """
        let release = try AppUpdater.parseRelease(Data(json.utf8))
        #expect(release.version == "1.2.0")
        #expect(release.archiveURL?.lastPathComponent == "Hive-1.2.0.zip")
        #expect(release.signatureURL?.lastPathComponent == "checksums.txt.sshsig")
    }

    @Test func checksumsMustMatch() throws {
        let directory = try temporaryDirectory()
        let archive = directory.appendingPathComponent("Hive-1.2.0.zip")
        try Data("the app".utf8).write(to: archive)
        let digest = try AppUpdater.sha256(of: archive)

        let good = directory.appendingPathComponent("good.txt")
        try "\(digest)  Hive-1.2.0.zip\n0000  Hive-1.2.0.dmg\n".write(to: good, atomically: true, encoding: .utf8)
        try AppUpdater.verifyChecksum(of: archive, listedIn: good)

        let bad = directory.appendingPathComponent("bad.txt")
        try "\(String(repeating: "0", count: 64))  Hive-1.2.0.zip\n".write(to: bad, atomically: true, encoding: .utf8)
        #expect(throws: AppUpdater.UpdateError.self) { try AppUpdater.verifyChecksum(of: archive, listedIn: bad) }

        let missing = directory.appendingPathComponent("missing.txt")
        try "\(digest)  Hive-9.9.9.zip\n".write(to: missing, atomically: true, encoding: .utf8)
        #expect(throws: AppUpdater.UpdateError.self) { try AppUpdater.verifyChecksum(of: archive, listedIn: missing) }
    }

    /// The same check Hive's install.sh makes: a good SSH signature passes, any change to the file fails.
    @Test func signaturesMustVerify() async throws {
        let directory = try temporaryDirectory()
        let key = directory.appendingPathComponent("key")
        try shell("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", key.path])
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        let signers = "hive-release namespaces=\"hive-release\" \(publicKey)"

        let checksums = directory.appendingPathComponent("checksums.txt")
        try "abc  Hive-1.2.0.zip\n".write(to: checksums, atomically: true, encoding: .utf8)
        try shell("/usr/bin/ssh-keygen", ["-Y", "sign", "-f", key.path, "-n", "hive-release", checksums.path])
        let signature = directory.appendingPathComponent("checksums.txt.sig")

        try await AppUpdater.verifySignature(checksums: checksums, signature: signature, allowedSigners: signers)

        try "def  Hive-1.2.0.zip\n".write(to: checksums, atomically: true, encoding: .utf8)
        await #expect(throws: AppUpdater.UpdateError.self) {
            try await AppUpdater.verifySignature(checksums: checksums, signature: signature, allowedSigners: signers)
        }
    }

    @Test func shipsWithTheReleaseKey() {
        #expect(AppUpdater.releaseAllowedSigners?.hasPrefix("hive-release namespaces=\"hive-release\" ssh-ed25519 ") == true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hive-updater-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shell(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
