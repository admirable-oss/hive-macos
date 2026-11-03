//
//  hiveApp.swift
//  hive
//
//  Created by Admir Saheta on 3. 11. 2026..
//

import SwiftUI
import CoreData

@main
struct hiveApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
