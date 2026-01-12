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
import AppIntents
import WidgetKit
#if DEBUG
import Darwin
#endif

@main
struct BisonNotesAIApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var appCoordinator = AppDataCoordinator()

    /// Performs one-time migration of AWS Bedrock settings from legacy model identifiers
    /// This ensures UserDefaults is updated rather than migrating on every access
    private func migrateAWSBedrockSettings() {
        let key = "awsBedrockModel"
        let migrationKey = "awsBedrockModelMigrated_v1.3"

        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        if let storedModel = UserDefaults.standard.string(forKey: key) {
            let migratedModel = AWSBedrockModel.migrate(rawValue: storedModel)
            if migratedModel != storedModel {
                UserDefaults.standard.set(migratedModel, forKey: key)
                NSLog("✅ AWS Bedrock model migrated from \(storedModel) to \(migratedModel)")
            }
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Migrates legacy "None" and "Not Configured" AI engine selections to intelligent defaults
    /// Defaults to Apple Intelligence on supported devices, OpenAI with dummy key on older devices
    private func migrateAIEngineSelection() {
        let aiEngineKey = "SelectedAIEngine"
        let transcriptionEngineKey = "SelectedTranscriptionEngine"
        let migrationKey = "aiEngineSelectionMigrated_v1.3"

        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        let currentAIEngine = UserDefaults.standard.string(forKey: aiEngineKey)
        let currentTranscriptionEngine = UserDefaults.standard.string(forKey: transcriptionEngineKey)

        // Determine the appropriate default based on device capabilities
        let isAppleIntelligenceSupported = DeviceCompatibility.isAppleIntelligenceSupported

        // Migrate AI engine if not configured
        if currentAIEngine == "None" || currentAIEngine == "Not Configured" || currentAIEngine == nil {
            if isAppleIntelligenceSupported {
                UserDefaults.standard.set("Apple Intelligence", forKey: aiEngineKey)
                NSLog("✅ AI engine migrated from '\(currentAIEngine ?? "nil")' to 'Apple Intelligence' (device supported)")
            } else {
                // Set OpenAI as default for older devices
                UserDefaults.standard.set("OpenAI", forKey: aiEngineKey)
                // Set dummy API key if none exists
                if UserDefaults.standard.string(forKey: "openAIAPIKey") == nil {
                    UserDefaults.standard.set("sk-000000000000", forKey: "openAIAPIKey")
                    NSLog("✅ Set dummy OpenAI API key for older device")
                }
                UserDefaults.standard.set(true, forKey: "enableOpenAI")
                NSLog("✅ AI engine migrated from '\(currentAIEngine ?? "nil")' to 'OpenAI' (device not supported for Apple Intelligence)")
            }
        }

        // Migrate transcription engine if not configured
        if currentTranscriptionEngine == "Not Configured" || currentTranscriptionEngine == nil {
            let isTranscriptionSupported = DeviceCompatibility.isAppleIntelligenceTranscriptionSupported
            if isTranscriptionSupported {
                UserDefaults.standard.set("Apple Transcription", forKey: transcriptionEngineKey)
                NSLog("✅ Transcription engine migrated from '\(currentTranscriptionEngine ?? "nil")' to 'Apple Transcription' (device supported)")
            } else {
                // Set OpenAI as default for older devices
                UserDefaults.standard.set("OpenAI", forKey: transcriptionEngineKey)
                // Set dummy API key if none exists
                if UserDefaults.standard.string(forKey: "openAIAPIKey") == nil {
                    UserDefaults.standard.set("sk-000000000000", forKey: "openAIAPIKey")
                    NSLog("✅ Set dummy OpenAI API key for older device")
                }
                UserDefaults.standard.set(true, forKey: "enableOpenAI")
                NSLog("✅ Transcription engine migrated from '\(currentTranscriptionEngine ?? "nil")' to 'OpenAI' (device not supported for Apple Intelligence)")
            }
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
    
    /// Migrates users from Apple Transcription to WhisperKit (On-Device)
    /// Sets a flag to show WhisperKit settings for model download
    private func migrateAppleTranscriptionToWhisperKit() {
        let transcriptionEngineKey = "selectedTranscriptionEngine"
        let migrationKey = "appleTranscriptionToWhisperKitMigrated_v1.4"

        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        let currentTranscription = UserDefaults.standard.string(forKey: transcriptionEngineKey)

        // Check if user was using Apple Transcription
        if currentTranscription == "Apple Transcription" {
            // Migrate to WhisperKit
            UserDefaults.standard.set(TranscriptionEngine.whisperKit.rawValue, forKey: transcriptionEngineKey)
            UserDefaults.standard.set(true, forKey: WhisperKitModelInfo.SettingsKeys.enableWhisperKit)

            // Set flag to show WhisperKit settings on first launch
            UserDefaults.standard.set(true, forKey: "showWhisperKitMigrationSettings")

            NSLog("✅ Migrated transcription from Apple Transcription to WhisperKit (On-Device)")
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
    
    /// Ensures users with old WhisperKit values still work if the enum rawValue changes
    /// This handles backward compatibility for any future renames of the WhisperKit engine
    private func migrateWhisperKitNameIfNeeded() {
        let transcriptionEngineKey = "selectedTranscriptionEngine"
        let migrationKey = "whisperKitNameMigration_v1.5"
        
        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }
        
        let currentTranscription = UserDefaults.standard.string(forKey: transcriptionEngineKey)
        let currentWhisperKitRawValue = TranscriptionEngine.whisperKit.rawValue
        
        // If the stored value is an old WhisperKit name but doesn't match current rawValue, update it
        // This handles cases where "On Device" might be renamed to something else (e.g., "WhisperKit")
        if let storedValue = currentTranscription,
           storedValue != currentWhisperKitRawValue {
            // Check if it's an old WhisperKit value that needs updating
            let oldWhisperKitNames = ["On Device", "WhisperKit", "On-Device"]
            if oldWhisperKitNames.contains(storedValue) {
                // Update to current WhisperKit rawValue
                UserDefaults.standard.set(currentWhisperKitRawValue, forKey: transcriptionEngineKey)
                NSLog("✅ Migrated transcription engine from '\(storedValue)' to '\(currentWhisperKitRawValue)'")
            }
        }
        
        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Migrates users from Apple Intelligence to On-Device AI
    /// Shows an alert and opens the On-Device AI settings page
    private func migrateAppleIntelligenceToOnDeviceLLM() {
        let aiEngineKey = "SelectedAIEngine"
        let migrationKey = "appleIntelligenceToOnDeviceLLMMigrated_v1.4"
        
        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }
        
        let currentAIEngine = UserDefaults.standard.string(forKey: aiEngineKey)
        
        // Check if user was using Apple Intelligence (check all possible variations)
        let appleIntelligenceVariants = [
            "Apple Intelligence",
            "Enhanced Apple Intelligence",
            "enhancedAppleIntelligence"
        ]
        
        if let engine = currentAIEngine, appleIntelligenceVariants.contains(engine) {
            // Mark that we need to show the migration alert
            UserDefaults.standard.set(true, forKey: "showAppleIntelligenceMigrationAlert")
            
            // Migrate to On-Device AI
            UserDefaults.standard.set("On-Device AI", forKey: aiEngineKey)
            UserDefaults.standard.set(true, forKey: "enableOnDeviceLLM")
            
            // Also update transcription if it was using Apple Intelligence
            let transcriptionEngineKey = "selectedTranscriptionEngine"
            let currentTranscription = UserDefaults.standard.string(forKey: transcriptionEngineKey)
            if let transcription = currentTranscription, appleIntelligenceVariants.contains(transcription) {
                UserDefaults.standard.set(TranscriptionEngine.whisperKit.rawValue, forKey: transcriptionEngineKey)
                UserDefaults.standard.set(true, forKey: WhisperKitModelInfo.SettingsKeys.enableWhisperKit)
                UserDefaults.standard.set(true, forKey: "showWhisperKitMigrationSettings")
            }
            
            NSLog("✅ Migrated from Apple Intelligence (\(engine)) to On-Device AI")
        }
        
        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
    
    /// Migrates users from old "On-Device LLM" name to "On-Device AI"
    /// Handles backward compatibility for users who have the old name saved
    private func migrateOnDeviceLLMNameToOnDeviceAI() {
        let aiEngineKey = "SelectedAIEngine"
        let migrationKey = "onDeviceLLMNameMigration_v1.5"
        
        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }
        
        let currentAIEngine = UserDefaults.standard.string(forKey: aiEngineKey)
        
        // If the stored value is the old name, update it to the new name
        if currentAIEngine == "On-Device LLM" {
            UserDefaults.standard.set("On-Device AI", forKey: aiEngineKey)
            NSLog("✅ Migrated AI engine name from 'On-Device LLM' to 'On-Device AI'")
        }
        
        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    init() {
#if DEBUG
        Self.configureCoverageOutputIfNeeded()
#endif
        // Log device capabilities on startup
        logDeviceCapabilities()

        setupBackgroundTasks()
        setupAppShortcuts()
        migrateAWSBedrockSettings()
        migrateAIEngineSelection()
        migrateAppleIntelligenceToOnDeviceLLM()
        migrateAppleTranscriptionToWhisperKit()
        migrateWhisperKitNameIfNeeded()
        migrateOnDeviceLLMNameToOnDeviceAI()
    }

    /// Logs device capabilities on app startup
    private func logDeviceCapabilities() {
        print(String(repeating: "=", count: 50))
        print(DeviceCapabilities.getCapabilityReport())
        print(String(repeating: "=", count: 50))
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
        print("🚀 setupWatchConnectivity() called in BisonNotesAIApp")
        
        // Initialize watch connectivity for background sync
        let watchManager = WatchConnectivityManager.shared
        print("📱 Got WatchConnectivityManager.shared instance")
        
        // The sync handler will be set up by AudioRecorderViewModel when it's ready
        // We just need to ensure the WatchConnectivityManager singleton is initialized
        
        // Note: onWatchSyncRecordingReceived is set up by AudioRecorderViewModel
        // Don't override it here - let the proper Core Data integration handle it
        
        print("📱 Setting up onWatchRecordingSyncCompleted callback in BisonNotesAIApp")
        watchManager.onWatchRecordingSyncCompleted = { recordingId, success in
            print("📱 onWatchRecordingSyncCompleted called for: \(recordingId), success: \(success)")
            
            // Confirm sync completion back to watch with Core Data ID if successful
            if success {
                // In a real implementation, we'd get the actual Core Data object ID
                // For now, we'll use a placeholder to indicate successful Core Data creation
                let coreDataId = "core_data_\(recordingId.uuidString)"
                print("📱 About to call confirmSyncComplete with success=true")
                watchManager.confirmSyncComplete(recordingId: recordingId, success: true, coreDataId: coreDataId)
                print("✅ Confirmed reliable watch transfer in Core Data: \(recordingId)")
            } else {
                print("📱 About to call confirmSyncComplete with success=false")
                watchManager.confirmSyncComplete(recordingId: recordingId, success: false)
                print("❌ Failed to confirm watch transfer: \(recordingId)")
            }
        }
        
        print("📱 onWatchRecordingSyncCompleted callback has been set: \(watchManager.onWatchRecordingSyncCompleted != nil)")
        
        print("📱 iPhone watch connectivity initialized for background sync")
    }
    
    private func setupAppShortcuts() {
        // Update app shortcuts to include our recording intent
        Task {
            AppShortcuts.updateAppShortcutParameters()
        }

        if #available(iOS 18.0, *) {
            if let plugInsURL = Bundle.main.builtInPlugInsURL,
               let _ = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            } else {
                print("⚠️ Unable to enumerate built-in PlugIns")
            }
            ControlCenter.shared.reloadAllControls()
            ControlCenter.shared.reloadControls(ofKind: "com.bisonnotesai.controls.recording")

            Task {
                do {
                    let controls = try await ControlCenter.shared.currentControls()
                    let _ = controls.map { $0.kind }
                } catch {
                    print("❌ Failed to fetch current controls: \(error)")
                }
            }
        }
    }
    
#if DEBUG
    private static func configureCoverageOutputIfNeeded() {
        guard ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"] == nil else { return }
        let tempDirectory = NSTemporaryDirectory()
        let uniqueName = "BisonNotesAI-\(ProcessInfo.processInfo.globallyUniqueString).profraw"
        let destination = (tempDirectory as NSString).appendingPathComponent(uniqueName)
        setenv("LLVM_PROFILE_FILE", destination, 1)
        print("🧪 Code coverage output redirected to \(destination)")
    }
#endif
}
