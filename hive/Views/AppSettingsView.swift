import SwiftUI

struct AppSettingsView: View {
    @AppStorage("hive.appearance") private var appearance = "system"
    @AppStorage(AgentNotifier.effectiveStatesKey) private var notifyStates = "blocked, done"
    @AppStorage(AgentNotifier.systemNotificationsKey) private var systemNotifications = false

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
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
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(preferredColorScheme)
    }
}
