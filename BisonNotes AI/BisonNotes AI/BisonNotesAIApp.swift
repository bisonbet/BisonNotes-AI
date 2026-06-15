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
    @StateObject private var fileImportManager = FileImportManager()
    @StateObject private var transcriptImportManager = TranscriptImportManager()

    // Phase 6: Register AppDelegate for notification handling
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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

    /// Migrates legacy "None" and "Not Configured" AI engine selections to intelligent defaults.
    /// MLX is the on-device default for any device with 4GB+ RAM; the 1.7B model is used
    /// on 4-6GB devices and the 4B model on 6GB+ devices. Below 4GB falls back to Mistral AI.
    private func migrateAIEngineSelection() {
        let aiEngineKey = "SelectedAIEngine"
        let transcriptionEngineKey = "selectedTranscriptionEngine"
        let migrationKey = "aiEngineSelectionMigrated_v1.3"

        // Check if migration has already been performed
        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        let currentAIEngine = UserDefaults.standard.string(forKey: aiEngineKey)
        let currentTranscriptionEngine = UserDefaults.standard.string(forKey: transcriptionEngineKey)
        let hasOnDeviceAISupport = DeviceCapabilities.supportsMLX
        let deviceRAM = DeviceCapabilities.totalRAMInGB

        // Migrate AI engine if not configured
        if currentAIEngine == "None" || currentAIEngine == "Not Configured" || currentAIEngine == nil {
            if hasOnDeviceAISupport {
                // 4-6GB devices get the small 1.7B model; 6GB+ get the 4B default.
                let defaultModelId = deviceRAM < 6.0
                    ? MLXModelOption.smallModelId
                    : MLXSwiftSettingsKeys.defaultModelId
                UserDefaults.standard.set(AIEngineType.mlxSwift.rawValue, forKey: aiEngineKey)
                UserDefaults.standard.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                UserDefaults.standard.set(defaultModelId, forKey: MLXSwiftSettingsKeys.modelId)
                NSLog("✅ AI engine migrated from '\(currentAIEngine ?? "nil")' to 'MLX Swift' (model: \(defaultModelId), RAM: \(deviceRAM)GB)")
            } else {
                // Mistral AI is the recommended cloud default for devices below the MLX threshold (4GB)
                UserDefaults.standard.set(AIEngineType.mistralAI.rawValue, forKey: aiEngineKey)
                NSLog("✅ AI engine migrated from '\(currentAIEngine ?? "nil")' to 'Mistral AI' (device has <4GB RAM)")
            }
        }

        // Migrate transcription engine if not configured
        if currentTranscriptionEngine == "Not Configured" || currentTranscriptionEngine == nil {
            if hasOnDeviceAISupport {
                UserDefaults.standard.set(TranscriptionEngine.fluidAudio.rawValue, forKey: transcriptionEngineKey)
                UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
                NSLog("✅ Transcription engine migrated from '\(currentTranscriptionEngine ?? "nil")' to '\(TranscriptionEngine.fluidAudio.rawValue)'")
            } else {
                // Mistral AI is the recommended cloud transcription on devices below 4GB
                // (matches the AI summarization default).
                UserDefaults.standard.set(TranscriptionEngine.mistralAI.rawValue, forKey: transcriptionEngineKey)
                NSLog("✅ Transcription engine migrated from '\(currentTranscriptionEngine ?? "nil")' to 'Mistral AI' (device has <4GB RAM)")
            }
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
    
    /// Migrates users off WhisperKit, which has been removed in v1.8.
    /// Deletes downloaded Whisper model files, clears settings, switches the engine to
    /// Parakeet (FluidAudio), sets the default Parakeet model to v2 (English), and
    /// queues a one-time alert informing the user of the change.
    private func migrateWhisperKitToParakeet() {
        let migrationKey = "whisperKitRemovedMigration_v1.8"

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        let transcriptionEngineKey = "selectedTranscriptionEngine"
        let currentEngine = UserDefaults.standard.string(forKey: transcriptionEngineKey)
        let wasUsingWhisperKit = currentEngine == "On Device (WhisperKit)"

        // Delete WhisperKit model files from the HuggingFace cache
        let fileManager = FileManager.default
        let docDirs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        if let hfCacheURL = docDirs.first?.appendingPathComponent("huggingface") {
            try? fileManager.removeItem(at: hfCacheURL)
            NSLog("✅ Deleted WhisperKit HuggingFace model cache at \(hfCacheURL.path)")
        }
        let appSupportDirs = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let whisperKitDir = appSupportDirs.first?.appendingPathComponent("WhisperKitModels") {
            try? fileManager.removeItem(at: whisperKitDir)
            NSLog("✅ Deleted WhisperKit models directory at \(whisperKitDir.path)")
        }

        // Clear WhisperKit UserDefaults keys
        for key in ["enableWhisperKit", "whisperKitSelectedModel", "whisperKitModelDownloaded", "whisperKitModelPath"] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // If the user was on WhisperKit or any legacy on-device value, switch to Parakeet
        let legacyOnDeviceValues = ["On Device (WhisperKit)", "On Device", "WhisperKit", "On-Device", "Apple Transcription"]
        if let engine = currentEngine, legacyOnDeviceValues.contains(engine) {
            UserDefaults.standard.set(TranscriptionEngine.fluidAudio.rawValue, forKey: transcriptionEngineKey)
            UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
            NSLog("✅ Switched transcription engine from '\(engine)' to Parakeet (On Device)")
        }

        // Default Parakeet model to v2 (English) for all users who haven't explicitly chosen
        let modelKey = FluidAudioModelInfo.SettingsKeys.selectedModelVersion
        if UserDefaults.standard.string(forKey: modelKey) == nil
            || UserDefaults.standard.string(forKey: modelKey) == FluidAudioModelInfo.ModelVersion.v3.rawValue {
            UserDefaults.standard.set(FluidAudioModelInfo.ModelVersion.v2.rawValue, forKey: modelKey)
            NSLog("✅ Set Parakeet default model to v2 (English)")
        }

        // Only alert users whose active engine was WhisperKit
        if wasUsingWhisperKit {
            let parakeetAlreadyDownloaded = UserDefaults.standard.bool(forKey: FluidAudioModelInfo.SettingsKeys.modelDownloaded)
            if parakeetAlreadyDownloaded {
                // Parakeet is ready — just inform them the switch was made automatically
                UserDefaults.standard.set(true, forKey: "showWhisperKitSwitchedToParakeet")
                NSLog("✅ Queued WhisperKit→Parakeet silent-switch alert (model already downloaded)")
            } else {
                // Parakeet needs to be downloaded
                UserDefaults.standard.set(true, forKey: "showWhisperKitRemovedAlert")
                NSLog("✅ Queued WhisperKit removal alert (Parakeet model not yet downloaded)")
            }
        }

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
                UserDefaults.standard.set(TranscriptionEngine.fluidAudio.rawValue, forKey: transcriptionEngineKey)
                UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
                UserDefaults.standard.set(true, forKey: "showParakeetMigrationSettings")
            }
            
            NSLog("✅ Migrated from Apple Intelligence (\(engine)) to On-Device AI")
        }
        
        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
    
    /// Migrates removed OpenAI summarization and Google AI Studio models to current defaults
    /// Handles users who had gpt-4.1, gpt-4.1-nano, gemini-2.5-flash, gemini-2.5-flash-lite,
    /// or gemini-3-pro-preview saved and would now get a nil/broken model selection
    private func migrateRemovedModels() {
        let migrationKey = "removedModelsMigrated_v1.8"

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        // OpenAI summarization: gpt-4.1 and gpt-4.1-nano were removed; default to gpt-4.1-mini
        let openAIKey = "openAISummarizationModel"
        if let storedModel = UserDefaults.standard.string(forKey: openAIKey) {
            let removedOpenAIModels = ["gpt-4.1", "gpt-4.1-nano"]
            if removedOpenAIModels.contains(storedModel) {
                let newDefault = OpenAISummarizationModel.gpt41Mini.rawValue
                UserDefaults.standard.set(newDefault, forKey: openAIKey)
                NSLog("✅ OpenAI summarization model migrated from '\(storedModel)' to '\(newDefault)'")
            }
        }

        // Google AI Studio: gemini-2.5-flash, gemini-2.5-flash-lite, gemini-3-pro-preview removed
        let googleKey = "googleAIStudioModel"
        if let storedModel = UserDefaults.standard.string(forKey: googleKey) {
            let removedGoogleModels = ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3-pro-preview"]
            if removedGoogleModels.contains(storedModel) {
                let newDefault = "gemini-3-flash-preview"
                UserDefaults.standard.set(newDefault, forKey: googleKey)
                NSLog("✅ Google AI Studio model migrated from '\(storedModel)' to '\(newDefault)'")
            }
        }

        // On-Device LLM: qwen3-1.7b was removed; migrate to granite-4.0-micro
        let onDeviceKey = OnDeviceLLMModelInfo.SettingsKeys.selectedModelId
        if let storedModel = UserDefaults.standard.string(forKey: onDeviceKey),
           storedModel == "qwen3-1.7b" {
            let newDefault = OnDeviceLLMModelInfo.granite4Micro.id
            UserDefaults.standard.set(newDefault, forKey: onDeviceKey)
            NSLog("✅ On-Device LLM model migrated from 'qwen3-1.7b' to '\(newDefault)'")
        }

        // On-Device LLM: granite-4.0-h-tiny moved from standard to experimental
        // Enable experimental models so it continues to appear in the picker for existing users
        if let storedModel = UserDefaults.standard.string(forKey: onDeviceKey),
           storedModel == OnDeviceLLMModelInfo.granite4H.id {
            UserDefaults.standard.set(true, forKey: OnDeviceLLMModelInfo.SettingsKeys.enableExperimentalModels)
            NSLog("✅ Enabled experimental models because user had '\(OnDeviceLLMModelInfo.granite4H.id)' selected (now experimental)")
        }

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

    /// On v2.0, the legacy On-Device AI (llama) engine became 6GB+ only and
    /// the LFM 2.5 1.2B model was removed entirely. This one-shot migration:
    ///   1. Deletes any downloaded LFM model file from disk to reclaim ~731MB.
    ///   2. Moves anyone who had LFM selected (any device) to MLX 1.7B.
    ///   3. Moves anyone on legacy llama on a <6GB device to MLX 1.7B
    ///      (since legacy llama no longer supports their device).
    ///   4. If the device is <4GB (MLX unavailable), falls through to Mistral
    ///      AI — our recommended cloud engine.
    private func migrateLegacyOnDeviceUsersOffSubSixGB() {
        let migrationKey = "legacyOnDeviceSubSixGBMigration_v2.0"

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        // (1) Reclaim disk space — unconditional regardless of selection state.
        deleteLFMModelFileIfPresent()

        let aiEngineKey = "SelectedAIEngine"
        let onDeviceModelKey = OnDeviceLLMModelInfo.SettingsKeys.selectedModelId
        let currentAIEngine = UserDefaults.standard.string(forKey: aiEngineKey)
        let currentModelId = UserDefaults.standard.string(forKey: onDeviceModelKey)
        let deviceRAM = DeviceCapabilities.totalRAMInGB

        let isOnLegacy = currentAIEngine == AIEngineType.onDeviceLLM.rawValue
        let wasUsingLFM = isOnLegacy && currentModelId == "lfm-2.5-1.2b"
        let isOnLegacyBelowSixGB = isOnLegacy && deviceRAM < 6.0

        // Only migrate if the user is impacted by either change.
        guard wasUsingLFM || isOnLegacyBelowSixGB else { return }

        // Clear the now-removed LFM model id so the legacy engine doesn't try
        // to resolve it later.
        if currentModelId == "lfm-2.5-1.2b" {
            UserDefaults.standard.removeObject(forKey: onDeviceModelKey)
        }

        if deviceRAM >= 4.0 {
            UserDefaults.standard.set(AIEngineType.mlxSwift.rawValue, forKey: aiEngineKey)
            UserDefaults.standard.set(true, forKey: MLXSwiftSettingsKeys.enabled)
            UserDefaults.standard.set(MLXModelOption.smallModelId, forKey: MLXSwiftSettingsKeys.modelId)
            NSLog("✅ Migrated legacy On-Device AI user to MLX 1.7B (RAM: \(deviceRAM)GB, was LFM: \(wasUsingLFM))")
        } else {
            UserDefaults.standard.set(AIEngineType.mistralAI.rawValue, forKey: aiEngineKey)
            NSLog("✅ Migrated <4GB legacy On-Device AI user to Mistral AI (MLX requires 4GB+)")
        }
    }

    /// Removes the LFM 2.5 model file from disk if present. The model was
    /// removed in v2.0 and any cached weights are pure dead space (~731MB).
    private func deleteLFMModelFileIfPresent() {
        let lfmFileURL = URL.onDeviceLLMModelsDirectory
            .appendingPathComponent("LFM2.5-1.2B-Thinking-Q4_K_M")
            .appendingPathExtension("gguf")

        guard FileManager.default.fileExists(atPath: lfmFileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: lfmFileURL)
            NSLog("✅ Deleted legacy LFM 2.5 model file at \(lfmFileURL.path)")
        } catch {
            NSLog("⚠️ Failed to delete LFM 2.5 model file at \(lfmFileURL.path): \(error.localizedDescription)")
        }
    }

    private func migrateiCloudSensitiveBackupDefault() {
        let migrationKey = "iCloudSensitiveBackupDefaultMigrated_v1.4"

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        UserDefaults.standard.set(false, forKey: "iCloudBackupIncludeSensitiveSettings")
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Downgrades the file-protection class on existing files from .complete to
    /// .completeUntilFirstUserAuthentication. v1.11 (initial release) created
    /// recordings, transcripts, logs, and Core Data files with .complete, which
    /// makes them unreadable while the device is locked — breaking background
    /// recording and post-lock loads. Runs once after the user brings the app to
    /// the foreground (so protected data is available).
    private func migrateFileProtectionForExistingFiles() {
        let migrationKey = "fileProtectionDowngradeMigration_v1.11.1"

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
        }

        guard UIApplication.shared.isProtectedDataAvailable else {
            return
        }

        let fileManager = FileManager.default
        let directories: [URL] = [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ].compactMap { $0 }

        for directory in directories {
            AppFileProtection.applyRecursively(to: directory)
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        AppLog.shared.general("Downgraded existing file protection class to completeUntilFirstUserAuthentication (1.11 → 1.11.1)")
    }

    init() {
#if DEBUG
        Self.configureCoverageOutputIfNeeded()
#endif
        KeychainSecretStore.shared.migrateLegacySecretsFromUserDefaults()

        // Log device capabilities on startup
        logDeviceCapabilities()

        setupBackgroundTasks()
        setupAppShortcuts()
        migrateAWSBedrockSettings()
        migrateAIEngineSelection()
        migrateAppleIntelligenceToOnDeviceLLM()
        migrateWhisperKitToParakeet()
        migrateOnDeviceLLMNameToOnDeviceAI()
        migrateRemovedModels()
        migrateLegacyOnDeviceUsersOffSubSixGB()
        migrateiCloudSensitiveBackupDefault()
        setupDarwinNotificationObserver()
    }

    /// Registers a Darwin notification observer so the Share Extension can signal
    /// the main app to scan the shared container immediately (works when the app
    /// is suspended or backgrounded).
    private func setupDarwinNotificationObserver() {
        let name = "com.bisonnotesai.shareExtensionDidSaveFile" as CFString
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("ShareExtensionDidSaveFile"),
                        object: nil
                    )
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    /// Logs device capabilities on app startup
    private func logDeviceCapabilities() {
        AppLog.shared.general(String(repeating: "=", count: 50))
        AppLog.shared.general(DeviceCapabilities.getCapabilityReport())
        AppLog.shared.general(String(repeating: "=", count: 50))
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .environmentObject(fileImportManager)
                .environmentObject(transcriptImportManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didFinishLaunchingNotification)) { _ in
                    requestBackgroundAppRefreshPermission()
                    #if !targetEnvironment(macCatalyst)
                    setupWatchConnectivity()
                    #endif
                    // Note: Notification permission is now requested when first needed (in BackgroundProcessingManager)
                    // Initialize download monitor for on-device AI models
                    _ = OnDeviceAIDownloadMonitor.shared
                }
                .onOpenURL(perform: handleOpenURL)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    AppLog.shared.markCleanShutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    AppLog.shared.markCleanShutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    AppLog.shared.markSessionActive()
                    // Clear badge when the user actively opens the app. Using the
                    // scene-phase notification here (rather than AppDelegate
                    // applicationDidBecomeActive) ensures this fires reliably in
                    // scene-based SwiftUI apps where the UIApplicationDelegate method
                    // may be skipped.
                    appDelegate.clearAppBadge(reason: "activation")
                    // Repair any files left at .complete protection by v1.11.0.
                    migrateFileProtectionForExistingFiles()
                    // Scan for files placed by the Share Extension (Voice Memos, etc.)
                    scanSharedContainerForImports(trigger: .pendingToken)
                    // Also scan Documents/Inbox/ for files from "Open In" / document interaction.
                    scanInboxForImportableFiles()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShareExtensionDidSaveFile"))) { _ in
                    NSLog("📎 Darwin notification received from Share Extension")
                    scanSharedContainerForImports(trigger: .pendingToken)
                }
        }
        .commands {
            // MARK: - Mac Menu Bar Commands
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    NotificationCenter.default.post(name: NSNotification.Name("ToggleRecording"), object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("Import Audio...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ImportAudioFromMenu"), object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Import Transcript...") {
                    NotificationCenter.default.post(name: NSNotification.Name("ImportTranscriptFromMenu"), object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(after: .sidebar) {
                Divider()

                Button("Record") {
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToSection"), object: "record")
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Summaries") {
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToSection"), object: "summaries")
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Transcripts") {
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToSection"), object: "transcripts")
                }
                .keyboardShortcut("3", modifiers: .command)
            }
        }
    }

    /// Tracks the last URL processed by handleOpenURL to prevent double imports
    /// (e.g. if both .onOpenURL and AppDelegate fallback fire for the same URL).
    @State private var lastProcessedURL: URL?
    /// True while handleOpenURL is actively importing; prevents Inbox scan from interfering.
    @State private var isHandlingOpenURL = false

    /// Handles files opened from the share sheet (e.g. Voice Memos, Files). Imports audio as recordings, text as transcripts.
    /// Also handles the `bisonnotes://share-import` URL scheme from the Share Extension.
    private func handleOpenURL(_ url: URL) {
        NSLog("📎 handleOpenURL called (scheme: \(url.scheme ?? "nil"), host: \(url.host ?? "nil"), file: \(url.isFileURL ? url.lastPathComponent : "none"))")

        // Handle authenticated custom URL scheme from Share Extension.
        if ShareImportAuthorization.isShareImportURL(url) {
            NSLog("📎 handleOpenURL: Share Extension triggered import via URL scheme")
            scanSharedContainerForImports(trigger: .url(url))
            return
        } else if url.scheme == "bisonnotes" {
            NSLog("📎 handleOpenURL: rejected unsupported bisonnotes URL")
            return
        }

        guard url.isFileURL else { return }

        // Deduplicate: skip if we just processed this exact URL
        if lastProcessedURL == url {
            NSLog("📎 handleOpenURL: skipping duplicate URL")
            return
        }
        lastProcessedURL = url

        let needsStopAccess = url.startAccessingSecurityScopedResource()
        NSLog("📎 Security-scoped access: \(needsStopAccess ? "started" : "not needed")")

        NotificationCenter.default.post(name: Notification.Name("SwitchToRecordTabForImport"), object: nil)

        isHandlingOpenURL = true

        Task { @MainActor in
            defer {
                if needsStopAccess {
                    url.stopAccessingSecurityScopedResource()
                }
                isHandlingOpenURL = false
            }

            await importFileByExtension(url)

            // Clean up the Inbox copy (iOS places shared files in Documents/Inbox/)
            cleanupInboxFileIfNeeded(url)

            // Clear dedup guard after a delay so re-sharing the same file still works
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                if lastProcessedURL == url {
                    lastProcessedURL = nil
                }
            }
        }
    }

    // MARK: - Share Extension Import (App Group Container)

    private let appGroupID = "group.bisonnotesai.shared"
    private let shareInboxFolder = "ShareInbox"

    private enum SharedContainerImportTrigger {
        case url(URL)
        case pendingToken
    }

    /// Scans the App Group shared container for files placed by the Share Extension
    /// (e.g. from Voice Memos share sheet). Imports them and cleans up.
    private func scanSharedContainerForImports(trigger: SharedContainerImportTrigger) {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(shareInboxFolder) else { return }

        guard FileManager.default.fileExists(atPath: containerURL.path) else { return }

        let authorized: Bool
        switch trigger {
        case .url(let url):
            authorized = ShareImportAuthorization.consumeURLToken(from: url, in: containerURL)
        case .pendingToken:
            authorized = ShareImportAuthorization.consumePendingToken(in: containerURL)
        }

        guard authorized else {
            NSLog("📎 Shared container scan skipped: missing or invalid Share Extension import token")
            return
        }

        let files: [URL]
        do {
            files = try FileManager.default
                .contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent != ShareImportAuthorization.tokenFileName }
        } catch {
            return
        }

        guard !files.isEmpty else { return }
        NSLog("📎 Shared container scan: found \(files.count) file(s) from Share Extension")

        NotificationCenter.default.post(name: Notification.Name("SwitchToRecordTabForImport"), object: nil)

        Task { @MainActor in
            var audioFiles: [URL] = []
            var textFiles: [URL] = []

            let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aif"]
            let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "pdf", "doc", "docx"]

            for file in files {
                // Strip UUID prefix to get the original extension
                let ext = file.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    audioFiles.append(file)
                } else if textExtensions.contains(ext) {
                    textFiles.append(file)
                }
            }

            if !audioFiles.isEmpty {
                NSLog("📎 Shared container: importing \(audioFiles.count) audio file(s)")
                await fileImportManager.importAudioFiles(from: audioFiles)
            }

            if !textFiles.isEmpty {
                NSLog("📎 Shared container: importing \(textFiles.count) text file(s)")
                await transcriptImportManager.importTranscriptFiles(from: textFiles)
            }

            // Clean up all files from the shared container after import
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }

            NSLog("📎 Shared container: cleanup complete")
        }
    }

    // MARK: - Inbox Scanning (Share Sheet Fallback)

    /// Scans Documents/Inbox/ for files silently placed by iOS share sheet and imports them.
    /// On modern iOS, the share sheet's "Copy to [App]" action copies files to the Inbox
    /// without opening the app. This method picks them up when the user returns to the app.
    private func scanInboxForImportableFiles() {
        // Don't scan while handleOpenURL is actively importing (it handles its own Inbox cleanup).
        guard !isHandlingOpenURL else { return }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inboxURL = documentsURL.appendingPathComponent("Inbox")

        guard FileManager.default.fileExists(atPath: inboxURL.path) else { return }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)
        } catch {
            return
        }

        guard !files.isEmpty else { return }
        NSLog("📎 Inbox scan: found \(files.count) file(s) to import")

        // Switch to Record tab so the user sees import feedback
        NotificationCenter.default.post(name: Notification.Name("SwitchToRecordTabForImport"), object: nil)

        Task { @MainActor in
            var audioFiles: [URL] = []
            var textFiles: [URL] = []
            var unsupported: [URL] = []

            let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aif"]
            let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "pdf", "doc", "docx"]

            for file in files {
                let ext = file.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    audioFiles.append(file)
                } else if textExtensions.contains(ext) {
                    textFiles.append(file)
                } else {
                    unsupported.append(file)
                }
            }

            if !audioFiles.isEmpty {
                NSLog("📎 Inbox scan: importing \(audioFiles.count) audio file(s)")
                await fileImportManager.importAudioFiles(from: audioFiles)
            }

            if !textFiles.isEmpty {
                NSLog("📎 Inbox scan: importing \(textFiles.count) text file(s)")
                await transcriptImportManager.importTranscriptFiles(from: textFiles)
            }

            // Clean up all Inbox files after import (including unsupported ones)
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }

            // Remove Inbox directory if empty
            let remaining = (try? FileManager.default.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil)) ?? []
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: inboxURL)
            }

            if !unsupported.isEmpty {
                NSLog("📎 Inbox scan: \(unsupported.count) unsupported file(s) cleaned up")
            }
        }
    }

    // MARK: - Import Helpers

    /// Classifies a file by extension and imports via the appropriate manager.
    private func importFileByExtension(_ url: URL) async {
        let ext = url.pathExtension.lowercased()
        let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aif"]
        let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "pdf", "doc", "docx"]

        if audioExtensions.contains(ext) {
            NSLog("📎 Importing audio file (.\(ext))")
            await fileImportManager.importAudioFiles(from: [url])
        } else if textExtensions.contains(ext) {
            NSLog("📎 Importing text file (.\(ext))")
            await transcriptImportManager.importTranscriptFiles(from: [url])
        } else {
            NSLog("📎 Unsupported file type: \(ext)")
            NotificationCenter.default.post(name: Notification.Name("UnsupportedFileTypeFromShare"), object: nil)
        }
    }

    /// Removes the file from Documents/Inbox/ if that's where iOS placed it during share.
    private func cleanupInboxFileIfNeeded(_ url: URL) {
        let inboxPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox")
        guard let inboxPath = inboxPath,
              url.path.hasPrefix(inboxPath.path) else { return }
        try? FileManager.default.removeItem(at: url)
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
        AppLog.shared.general("Background app refresh configured via BGTaskScheduler")
    }
    
    private func handleBackgroundProcessing(task: BGProcessingTask) {
        AppLog.shared.general("Background processing task started: \(task.identifier)")

        // Set expiration handler
        task.expirationHandler = {
            AppLog.shared.general("Background processing task expired", level: .error)
            task.setTaskCompleted(success: false)
        }
        
        // Check for pending transcription/summarization jobs
        Task {
            let backgroundManager = BackgroundProcessingManager.shared

            guard !AppLog.shared.previousSessionCrashed else {
                AppLog.shared.general("Skipping background job processing because previous session crashed", level: .error)
                task.setTaskCompleted(success: true)
                return
            }
            
            // Process any queued jobs
            if !backgroundManager.activeJobs.filter({ $0.status == .queued }).isEmpty {
                AppLog.shared.general("Processing queued jobs in background")
                // The background manager will handle the actual processing
                await backgroundManager.processNextJob()
                task.setTaskCompleted(success: true)
            } else {
                AppLog.shared.general("No queued jobs found for background processing", level: .debug)
                task.setTaskCompleted(success: true)
            }
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        AppLog.shared.general("Background app refresh started")

        task.expirationHandler = {
            AppLog.shared.general("Background app refresh expired", level: .error)
            task.setTaskCompleted(success: false)
        }
        
        // Quick refresh of app state
        Task {
            // Clean up any stale jobs
            let backgroundManager = BackgroundProcessingManager.shared
            await backgroundManager.cleanupStaleJobs()
            
            AppLog.shared.general("Background app refresh completed")
            task.setTaskCompleted(success: true)
        }
    }
    
    private func setupWatchConnectivity() {
        AppLog.shared.general("setupWatchConnectivity() called in BisonNotesAIApp")

        // Initialize watch connectivity for background sync
        let watchManager = WatchConnectivityManager.shared
        AppLog.shared.general("Got WatchConnectivityManager.shared instance", level: .debug)

        // The sync handler will be set up by AudioRecorderViewModel when it's ready
        // We just need to ensure the WatchConnectivityManager singleton is initialized

        // Note: onWatchSyncRecordingReceived is set up by AudioRecorderViewModel
        // Don't override it here - let the proper Core Data integration handle it

        AppLog.shared.general("Setting up onWatchRecordingSyncCompleted callback", level: .debug)
        watchManager.onWatchRecordingSyncCompleted = { recordingId, success in
            AppLog.shared.general("onWatchRecordingSyncCompleted called, success: \(success)", level: .debug)

            // Confirm sync completion back to watch with Core Data ID if successful
            if success {
                // In a real implementation, we'd get the actual Core Data object ID
                // For now, we'll use a placeholder to indicate successful Core Data creation
                let coreDataId = "core_data_\(recordingId.uuidString)"
                AppLog.shared.general("Calling confirmSyncComplete with success=true", level: .debug)
                watchManager.confirmSyncComplete(recordingId: recordingId, success: true, coreDataId: coreDataId)
                AppLog.shared.general("Confirmed reliable watch transfer in Core Data")
            } else {
                AppLog.shared.general("Calling confirmSyncComplete with success=false", level: .debug)
                watchManager.confirmSyncComplete(recordingId: recordingId, success: false)
                AppLog.shared.general("Failed to confirm watch transfer", level: .error)
            }
        }

        AppLog.shared.general("onWatchRecordingSyncCompleted callback configured", level: .debug)

        AppLog.shared.general("iPhone watch connectivity initialized for background sync")
    }
    
    private func setupAppShortcuts() {
        // Update app shortcuts to include our recording intent
        Task {
            AppShortcuts.updateAppShortcutParameters()
        }

        #if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            if let plugInsURL = Bundle.main.builtInPlugInsURL,
               let _ = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
            } else {
                AppLog.shared.general("Unable to enumerate built-in PlugIns", level: .debug)
            }
            ControlCenter.shared.reloadAllControls()
            ControlCenter.shared.reloadControls(ofKind: "com.bisonnotesai.controls.recording")

            Task {
                do {
                    let controls = try await ControlCenter.shared.currentControls()
                    let _ = controls.map { $0.kind }
                } catch {
                    AppLog.shared.general("Failed to fetch current controls: \(error)", level: .error)
                }
            }
        }
        #endif
    }
    
#if DEBUG
    private static func configureCoverageOutputIfNeeded() {
        guard ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"] == nil else { return }
        let tempDirectory = NSTemporaryDirectory()
        let uniqueName = "BisonNotesAI-\(ProcessInfo.processInfo.globallyUniqueString).profraw"
        let destination = (tempDirectory as NSString).appendingPathComponent(uniqueName)
        setenv("LLVM_PROFILE_FILE", destination, 1)
        AppLog.shared.general("Code coverage output redirected to \(destination)", level: .debug)
    }
#endif
}
