import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var menuBarStore: MenuBarAgentStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var setupViewModel = FirstLaunchViewModel()
    @AppStorage("hive.onboarding.complete") private var onboardingComplete = false
    @AppStorage("hive.appearance") private var appearance = "system"
    @AppStorage("hive.session.name") private var sessionName = "default"

    var body: some View {
        Group {
            switch setupViewModel.state {
            case .checking:
                StartupCheckView()
            case .needsInstall, .installing, .failed:
                FirstLaunchView(viewModel: setupViewModel)
            case .installed(let hiveURL):
                if onboardingComplete {
                    HiveDashboardView(hiveURL: hiveURL, sessionName: sessionName)
                        .id(sessionName)
                        .onChange(of: sessionName) { _, value in menuBarStore.selectSession(value) }
                        .task {
                            menuBarStore.openAgentWindow = { agentID in
                                UserDefaults.standard.set(agentID, forKey: "hive.menu.pending-agent")
                                openWindow(id: "main")
                                NSApp.activate(ignoringOtherApps: true)
                            }
                            menuBarStore.start(sessionName: sessionName)
                        }
                } else {
                    HiveOnboardingView(hiveURL: hiveURL) {
                        onboardingComplete = true
                    }
                }
            }
        }
        .task { await setupViewModel.checkInstallation() }
        .preferredColorScheme(preferredColorScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

private struct StartupCheckView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("HiveMark")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
            ProgressView()
                .controlSize(.small)
                .tint(Color(red: 0.961, green: 0.725, blue: 0.259))
            Text("Checking for Hive…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 500)
    }
}
