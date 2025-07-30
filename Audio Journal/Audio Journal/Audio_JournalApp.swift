//
//  Audio_JournalApp.swift
//  Audio Journal
//
//  Created by Tim Champ on 7/26/25.
//

import SwiftUI

@main
struct Audio_JournalApp: App {
    let persistenceController = PersistenceController.shared
    
    init() {
        // Initialize performance optimization and logging
        PerformanceOptimizer.shared.optimizeStartupLogging()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
