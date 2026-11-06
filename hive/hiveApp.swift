//
//  hiveApp.swift
//  hive
//
//  Created by Admir Saheta on 3. 11. 2026..
//

import SwiftUI

@main
struct HiveApp: App {
    @StateObject private var menuBarStore = MenuBarAgentStore.shared

    init() {
        // Finder's Services menu: "Open in Hive" and "New Hive Environment Here".
        NSApplication.shared.servicesProvider = HiveServicesProvider.shared
        NSUpdateDynamicServices()
        // An update helper waits for this before it trusts the new version; then check daily.
        AppUpdater.markLaunched()
        Task { @MainActor in AppUpdater.shared.startAutomaticChecks() }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(menuBarStore: menuBarStore)
                .navigationTitle("Hive")
                .onOpenURL { DeepLinkRouter.shared.handle($0) }
                // A link goes to the open window rather than opening another.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand()
            }
            HiveCommands()
            CommandMenu("Terminal") {
                SecureKeyboardEntryCommand()
            }
        }

        Settings {
            AppSettingsView()
        }

        Window("Software Update", id: "updates") {
            UpdatesView()
                .frame(width: 520)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarAgentPanel(store: menuBarStore)
        } label: {
            Image(systemName: menuBarStore.needsAttention ? "bell.badge.fill" : "h.square.fill")
                .foregroundStyle(menuBarStore.needsAttention ? Color.hiveAmber : Color.primary)
                .accessibilityLabel(menuBarStore.needsAttention ? "Hive: agents need attention" : "Hive agents")
        }
        .menuBarExtraStyle(.window)
    }
}
