//
//  hiveApp.swift
//  hive
//
//  Created by Admir Saheta on 3. 11. 2026..
//

import SwiftUI

@main
struct HiveApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .navigationTitle("Hive")
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            AppSettingsView()
        }
    }
}
