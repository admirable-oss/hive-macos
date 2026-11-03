import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var page = 0
    @Published var machineName = ""
    @Published var machineHost = ""
    @Published var keepHerdrKeys = false
    @Published private(set) var machines: [SavedHiveMachine] = []
    @Published private(set) var isLoadingMachines = false
    @Published private(set) var isAddingMachine = false
    @Published private(set) var legacyConfigAvailable = false
    @Published private(set) var migrationPreview: HerdrImportPreview?
    @Published private(set) var isLoadingMigrationPreview = false
    @Published private(set) var checkingMachine: String?
    @Published private(set) var migrationMessage: String?
    @Published private(set) var machineMessage: String?
    @Published private(set) var errorMessage: String?

    private let cli: HiveCLIService

    init(hiveURL: URL) {
        cli = HiveCLIService(executableURL: hiveURL)
        legacyConfigAvailable = Self.findHerdrConfig() != nil
    }

    func loadMachines() async {
        isLoadingMachines = true
        defer { isLoadingMachines = false }
        do {
            let data = Data(try await cli.run(["--json", "machine", "list"]).utf8)
            machines = try JSONDecoder().decode([SavedHiveMachine].self, from: data)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMigrationPreview() async {
        guard legacyConfigAvailable, migrationPreview == nil, !isLoadingMigrationPreview else { return }
        isLoadingMigrationPreview = true
        defer { isLoadingMigrationPreview = false }
        do {
            let data = Data(try await cli.run(["--json", "config", "import-herdr"]).utf8)
            migrationPreview = try JSONDecoder().decode(HerdrImportPreview.self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addMachine() async {
        let name = machineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = machineHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, !isAddingMachine else { return }

        isAddingMachine = true
        defer { isAddingMachine = false }
        do {
            // Add without connecting: SSH destinations can be checked after the
            // user has reviewed the saved host and its identity.
            _ = try await cli.run(["machine", "add", name, host, "--no-check"])
            machineName = ""
            machineHost = ""
            errorMessage = nil
            await loadMachines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importHerdrSettings() async {
        guard legacyConfigAvailable else { return }
        var arguments = ["--json", "config", "import-herdr", "--write"]
        if keepHerdrKeys { arguments.append("--herdr-keys") }

        do {
            let data = Data(try await cli.run(arguments).utf8)
            let report = try JSONDecoder().decode(HerdrImportPreview.self, from: data)
            let backup = report.backup.map { " Backup: \($0)." } ?? ""
            migrationMessage = "Imported \(report.mapped?.count ?? 0) setting(s); \(report.skipped?.count ?? 0) need manual review.\(backup)"
            legacyConfigAvailable = false
            migrationPreview = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkMachine(_ machine: SavedHiveMachine) async {
        guard checkingMachine == nil else { return }
        checkingMachine = machine.name
        defer { checkingMachine = nil }
        do {
            let data = Data(try await cli.run(["--json", "machine", "status", machine.name]).utf8)
            let states = try JSONDecoder().decode([HiveMachineStatus].self, from: data)
            guard let status = states.first else {
                errorMessage = "Hive returned no status for \(machine.name)."
                return
            }
            guard status.reachable else {
                errorMessage = status.error ?? "Could not connect to \(machine.name). Check the SSH destination and try again."
                return
            }
            machineMessage = "Connected to \(machine.name)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func findHerdrConfig() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["XDG_CONFIG_HOME"] ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config", isDirectory: true).path
        let path = environment["HERDR_CONFIG_PATH"] ?? URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("herdr/config.toml").path
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
