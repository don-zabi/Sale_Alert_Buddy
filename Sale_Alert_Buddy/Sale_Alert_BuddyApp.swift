//
//  Sale_Alert_BuddyApp.swift
//  Sale_Alert_Buddy
//
//  Created by Don on 2026-03-27.
//

import SwiftUI
import CoreData

@main
struct Sale_Alert_BuddyApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
