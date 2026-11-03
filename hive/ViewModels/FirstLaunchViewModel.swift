import Combine
import Foundation

@MainActor
final class FirstLaunchViewModel: ObservableObject {
    enum State: Equatable {
        case checking
        case needsInstall
        case installing
        case installed(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .checking

    func checkInstallation() async {
        state = .checking
        if let hive = await HiveInstallationService.locateInstalledHive() {
            HiveInstallationService.remember(hive)
            state = .installed(hive)
        } else {
            state = .needsInstall
        }
    }

    func installHive() {
        guard state != .installing else { return }
        state = .installing

        Task {
            do {
                let hive = try await HiveInstallationService.installHive()
                HiveInstallationService.remember(hive)
                state = .installed(hive)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func useHive(at url: URL) {
        guard state != .installing else { return }
        state = .checking

        Task {
            guard await HiveInstallationService.verifyHive(at: url) else {
                state = .failed("That file did not respond as a working Hive command. Choose the Hive executable and try again.")
                return
            }
            HiveInstallationService.remember(url)
            state = .installed(url)
        }
    }
}
