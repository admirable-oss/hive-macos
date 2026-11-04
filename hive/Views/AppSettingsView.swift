import SwiftUI

struct AppSettingsView: View {
    @State private var hiveURL: URL?
    @AppStorage("hive.appearance") private var appearance = "system"
    @AppStorage(AgentNotifier.effectiveStatesKey) private var notifyStates = "blocked, done"
    @AppStorage(AgentNotifier.systemNotificationsKey) private var systemNotifications = false
    @AppStorage("hive.session.name") private var sessionName = "default"

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        TabView {
          Form {
            Section("Appearance") {
                Picker("Mode", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Text("Applies to the app and its terminals. The multiplexer’s own theme stays in Hive’s config.toml.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                LabeledContent("Notify on", value: notifyStates.isEmpty ? "Never" : notifyStates)
                LabeledContent("System notifications", value: systemNotifications ? "On in Hive" : "Handled by the app")
                Text("These values follow Hive’s effective [notify] settings in config.toml. Per-agent overrides can be set in [notify.agents]. The Dock badge always shows the blocked agent count.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

          }
          .tabItem { Label("General", systemImage: "gearshape") }

          Group {
              if let hiveURL {
                  ConfigSettingsView(cli: HiveCLIService(executableURL: hiveURL, sessionName: sessionName))
              } else { ProgressView("Finding Hive CLI…") }
          }
          .tabItem { Label("Configuration", systemImage: "slider.horizontal.3") }

          Group {
              if let hiveURL { SessionSettingsView(hiveURL: hiveURL, sessionName: $sessionName) }
              else { ProgressView("Finding Hive CLI…") }
          }
          .tabItem { Label("Sessions", systemImage: "square.stack.3d.up") }

          Group {
              if let hiveURL { UpkeepSettingsView(hiveURL: hiveURL, sessionName: sessionName) }
              else { ProgressView("Finding Hive CLI…") }
          }
          .tabItem { Label("Upkeep", systemImage: "wrench.and.screwdriver") }

          Form {
            Section("Agent integrations") {
                if let hiveURL {
                    IntegrationHooksView(hiveURL: hiveURL)
                } else {
                    ProgressView("Finding Hive CLI…")
                }
            }
          }
          .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
        }
        .formStyle(.grouped)
        .frame(width: 720, height: 600)
        .preferredColorScheme(preferredColorScheme)
        .task { if hiveURL == nil { hiveURL = await HiveInstallationService.locateInstalledHive() } }
    }
}
