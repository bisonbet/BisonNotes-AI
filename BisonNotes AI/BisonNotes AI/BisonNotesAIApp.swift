//
//  BisonNotesAIApp.swift
//  BisonNotes AI
//
//  Created by Tim Champ on 7/26/25.
//

import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications

@main
struct BisonNotesAIApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var appCoordinator = AppDataCoordinator()
    
    init() {
        setupBackgroundTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didFinishLaunchingNotification)) { _ in
                    requestBackgroundAppRefreshPermission()
                    setupWatchConnectivity()
                    // Note: Notification permission is now requested when first needed (in BackgroundProcessingManager)
                }
        }
    }
    
    private func setupBackgroundTasks() {
        // Register background task identifiers
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.bisonai.audio-processing", using: nil) { task in
            handleBackgroundProcessing(task: task as! BGProcessingTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.bisonai.app-refresh", using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    private func requestBackgroundAppRefreshPermission() {
        // Background app refresh is now handled via BGTaskScheduler in setupBackgroundTasks()
        // No need for the deprecated setMinimumBackgroundFetchInterval
        print("📱 Background app refresh configured via BGTaskScheduler")
    }
    
    private func requestNotificationPermission() {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    print("✅ Notification permission granted")
                } else if let error = error {
                    print("❌ Notification permission denied: \(error.localizedDescription)")
                } else {
                    print("❌ Notification permission denied by user")
                }
            }
        }
    }
    
    private func handleBackgroundProcessing(task: BGProcessingTask) {
        print("📱 Background processing task started: \(task.identifier)")
        
        // Set expiration handler
        task.expirationHandler = {
            print("⚠️ Background processing task expired")
            task.setTaskCompleted(success: false)
        }
        
        // Check for pending transcription/summarization jobs
        Task {
            let backgroundManager = BackgroundProcessingManager.shared
            
            // Process any queued jobs
            if !backgroundManager.activeJobs.filter({ $0.status == .queued }).isEmpty {
                print("🚀 Processing queued jobs in background")
                // The background manager will handle the actual processing
                await backgroundManager.processNextJob()
                task.setTaskCompleted(success: true)
            } else {
                print("📭 No queued jobs found for background processing")
                task.setTaskCompleted(success: true)
            }
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        print("📱 Background app refresh started")
        
        task.expirationHandler = {
            print("⚠️ Background app refresh expired")
            task.setTaskCompleted(success: false)
        }
        
        // Quick refresh of app state
        Task {
            // Clean up any stale jobs
            let backgroundManager = BackgroundProcessingManager.shared
            await backgroundManager.cleanupStaleJobs()
            
            print("✅ Background app refresh completed")
            task.setTaskCompleted(success: true)
        }
    }
    
    private func setupWatchConnectivity() {
        // Initialize watch connectivity for background sync
        let watchManager = WatchConnectivityManager.shared
        
        // The sync handler will be set up by AudioRecorderViewModel when it's ready
        // We just need to ensure the WatchConnectivityManager singleton is initialized
        
        watchManager.onWatchRecordingSyncCompleted = { recordingId, success in
            // Confirm sync completion back to watch
            watchManager.confirmSyncComplete(recordingId: recordingId, success: success)
        }
        
        print("📱 iPhone watch connectivity initialized for background sync")
    }
}
