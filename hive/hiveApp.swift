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

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(menuBarStore: menuBarStore)
                .navigationTitle("Hive")
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            HiveCommands()
            CommandMenu("Terminal") {
                SecureKeyboardEntryCommand()
            }
        }

        Settings {
            AppSettingsView()
        }

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
