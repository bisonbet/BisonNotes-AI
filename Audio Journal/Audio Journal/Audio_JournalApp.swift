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
    @StateObject private var appCoordinator = AppDataCoordinator()
    
    init() {
        // Initialize performance optimization and logging
        PerformanceOptimizer.shared.optimizeStartupLogging()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
