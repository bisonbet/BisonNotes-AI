//
//  BisonNotesAIApp.swift
//  BisonNotes AI
//
//  Created by Tim Champ on 7/26/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
import UserNotifications
import AppIntents
import WidgetKit
import Network
#if DEBUG
import Darwin
#endif

@main
struct BisonNotesAIApp: App {
    let persistenceController = PersistenceController.shared
    @StateObject private var appCoordinator = AppDataCoordinator()
    @StateObject private var recorderVM = AudioRecorderViewModel()
    @StateObject private var fileImportManager = FileImportManager()
    @StateObject private var transcriptImportManager = TranscriptImportManager()
    @State private var hasQueuedParakeetStartupRepair = false
    @FocusedValue(\.summaryExportAction) private var summaryExportAction
    @FocusedValue(\.transcriptSaveAction) private var transcriptSaveAction

    // Phase 6: Register AppDelegate for notification handling
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

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
            if hasOnDeviceAISupport,
               let defaultModelId = MLXSwiftSettingsKeys.recommendedModelId(forRAM: deviceRAM) {
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

    /// Ollama is supported only by the native Mac app. Move legacy iPhone and
    /// iPad selections to the best available on-device engine before startup
    /// can try to restore the unsupported provider.
    static func migrateIOSOllamaSelection() {
#if os(macOS)
        return
#else
        let defaults = UserDefaults.standard
        let aiEngineKey = "SelectedAIEngine"
        guard defaults.string(forKey: aiEngineKey) == AIEngineType.localLLM.rawValue else {
            return
        }

        let replacement: AIEngineType
        if let onDeviceEngine = AIEngineType.preferredOnDeviceMigrationEngine(
            supportsMLX: DeviceCapabilities.supportsMLX
        ) {
            replacement = onDeviceEngine
            switch onDeviceEngine {
            case .mlxSwift:
                defaults.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                if let defaultModelId = MLXSwiftSettingsKeys.recommendedModelId(
                    forRAM: DeviceCapabilities.totalRAMInGB
                ) {
                    defaults.set(defaultModelId, forKey: MLXSwiftSettingsKeys.modelId)
                }
            default:
                break
            }
        } else if AIEngineFactory.createEngine(type: .appleNative).isAvailable {
            replacement = .appleNative
        } else if let fallback = AIEngineType.availableCases.first(where: { engineType in
            engineType != .localLLM && AIEngineFactory.createEngine(type: engineType).isAvailable
        }) {
            replacement = fallback
        } else {
            defaults.set("None", forKey: aiEngineKey)
            defaults.set(false, forKey: "enableOllama")
            defaults.set(true, forKey: "showOllamaMigrationAlert")
            NSLog("⚠️ Ollama is Mac-only; no replacement engine is currently available on this device")
            return
        }

        defaults.set(replacement.rawValue, forKey: aiEngineKey)
        defaults.set(false, forKey: "enableOllama")
        defaults.set(true, forKey: "showOllamaMigrationAlert")
        NSLog("✅ Migrated iOS Ollama selection to \(replacement.displayName)")
#endif
    }

    /// Migrates selections that depended on removed provider options.
    /// Existing compatible-API summarization selections are preserved.
    private func migrateRemovedProviderSelections() {
        let migrationKey = "removedProviderSelectionsMigrated_v2.3"
        let previousMigrationKey = "removedProviderSelectionsMigrated_v2.5"
        let defaults = UserDefaults.standard

        guard !defaults.bool(forKey: migrationKey) else {
            return
        }

        let aiEngineKey = "SelectedAIEngine"
        let transcriptionEngineKey = "selectedTranscriptionEngine"
        normalizeLegacyCompatibleEngineIdentifier(in: defaults, key: aiEngineKey)
        let migratedLegacyOpenAI = migrateLegacyOpenAIConfiguration()
        let hasOnDeviceAISupport = DeviceCapabilities.supportsMLX

        migrateRemovedAIEngineSelection(
            currentAIEngine: defaults.string(forKey: aiEngineKey),
            migratedLegacyOpenAI: migratedLegacyOpenAI,
            previousMigrationCompleted: defaults.bool(forKey: previousMigrationKey),
            hasOnDeviceAISupport: hasOnDeviceAISupport
        )
        migrateRemovedTranscriptionSelection(
            currentTranscriptionEngine: defaults.string(forKey: transcriptionEngineKey),
            hasOnDeviceAISupport: hasOnDeviceAISupport,
            defaults: defaults,
            key: transcriptionEngineKey
        )
        migrateInvalidAIEngineSelection(in: defaults, key: aiEngineKey, hasOnDeviceAISupport: hasOnDeviceAISupport)
        migrateInvalidTranscriptionSelection(
            in: defaults,
            key: transcriptionEngineKey,
            hasOnDeviceAISupport: hasOnDeviceAISupport
        )

        defaults.set(true, forKey: migrationKey)
    }

    /// Normalizes compatible-engine identifiers written by older builds.
    private func normalizeLegacyCompatibleEngineIdentifier(in defaults: UserDefaults, key: String) {
        let legacyCompatibleEngineNames = ["Compatible API", "OpenAI-Compatible"]
        if let selectedAIEngine = defaults.string(forKey: key),
           legacyCompatibleEngineNames.contains(selectedAIEngine) {
            defaults.set(AIEngineType.openAICompatible.rawValue, forKey: key)
        }
    }

    private func migrateRemovedAIEngineSelection(
        currentAIEngine: String?,
        migratedLegacyOpenAI: Bool,
        previousMigrationCompleted: Bool,
        hasOnDeviceAISupport: Bool
    ) {
        let defaults = UserDefaults.standard
        let key = "SelectedAIEngine"

        if currentAIEngine == "OpenAI" {
            if migratedLegacyOpenAI {
                defaults.set(AIEngineType.openAICompatible.rawValue, forKey: key)
                defaults.set(true, forKey: "enableOpenAICompatible")
                NSLog("✅ Migrated removed OpenAI selection to Compatible API")
            } else if hasOnDeviceAISupport,
                      let defaultModelId = MLXSwiftSettingsKeys.recommendedModelId(
                          forRAM: DeviceCapabilities.totalRAMInGB
                      ) {
                defaults.set(AIEngineType.mlxSwift.rawValue, forKey: key)
                defaults.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                defaults.set(defaultModelId, forKey: MLXSwiftSettingsKeys.modelId)
                NSLog("✅ Migrated removed cloud AI selection to On-Device AI (model: \(defaultModelId))")
            } else {
                setConfiguredFallbackAIEngine(forKey: key)
            }
        } else if currentAIEngine == AIEngineType.mistralAI.rawValue,
                  previousMigrationCompleted,
                  !AIEngineFactory.createEngine(type: .mistralAI).isAvailable {
            // Repair installations that already ran the original v2.5 migration,
            // which selected Mistral without checking its credentials.
            setConfiguredFallbackAIEngine(forKey: key)
        }
    }

    private func migrateRemovedTranscriptionSelection(
        currentTranscriptionEngine: String?,
        hasOnDeviceAISupport: Bool,
        defaults: UserDefaults,
        key: String
    ) {
        guard currentTranscriptionEngine == "OpenAI" || currentTranscriptionEngine == "OpenAI API Compatible" else {
            return
        }

        if hasOnDeviceAISupport,
           TranscriptionEngine.fluidAudio.isAvailable,
           FluidAudioManager.shared.isModelReady {
            defaults.set(TranscriptionEngine.fluidAudio.rawValue, forKey: key)
            defaults.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
            NSLog("✅ Migrated removed cloud transcription selection to On-Device transcription")
        } else if AIEngineFactory.createEngine(type: .mistralAI).isAvailable {
            defaults.set(TranscriptionEngine.mistralAI.rawValue, forKey: key)
            NSLog("✅ Migrated removed cloud transcription selection to configured Mistral AI")
        } else {
            defaults.set(TranscriptionEngine.notConfigured.rawValue, forKey: key)
            NSLog("⚠️ No ready transcription engine is available; leaving selection unconfigured")
        }
    }

    private func migrateInvalidAIEngineSelection(in defaults: UserDefaults, key: String, hasOnDeviceAISupport: Bool) {
        let validAIEngineNames = Set(AIEngineType.allCases.map(\.rawValue))
        guard let selectedAIEngine = defaults.string(forKey: key),
              selectedAIEngine != "None",
              !validAIEngineNames.contains(selectedAIEngine) else {
            return
        }

        if hasOnDeviceAISupport {
            defaults.set(AIEngineType.mlxSwift.rawValue, forKey: key)
            defaults.set(true, forKey: MLXSwiftSettingsKeys.enabled)
            MLXSwiftSettingsKeys.normalizeStoredModelId(
                in: defaults,
                ramGB: DeviceCapabilities.totalRAMInGB
            )
            NSLog("✅ Migrated unavailable AI selection to On-Device AI")
        } else {
            setConfiguredFallbackAIEngine(forKey: key)
        }
    }

    private func migrateInvalidTranscriptionSelection(
        in defaults: UserDefaults,
        key: String,
        hasOnDeviceAISupport: Bool
    ) {
        let validTranscriptionEngineNames = Set(TranscriptionEngine.allCases.map(\.rawValue))
        guard let selectedTranscriptionEngine = defaults.string(forKey: key),
              !validTranscriptionEngineNames.contains(selectedTranscriptionEngine) else {
            return
        }

        if hasOnDeviceAISupport {
            defaults.set(TranscriptionEngine.fluidAudio.rawValue, forKey: key)
            defaults.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
            NSLog("✅ Migrated unavailable transcription selection to On-Device transcription")
        } else {
            defaults.set(TranscriptionEngine.mistralAI.rawValue, forKey: key)
            NSLog("✅ Migrated unavailable transcription selection to Mistral AI")
        }
    }

    /// Carries an existing OpenAI configuration into the compatible API engine.
    /// The old provider is removed, but its credentials and model settings remain
    /// valid for the official OpenAI-compatible endpoint.
    private func migrateLegacyOpenAIConfiguration() -> Bool {
        let defaults = UserDefaults.standard
        let keychain = KeychainSecretStore.shared
        let compatibleKey = KeychainSecretStore.openAICompatibleAPIKey

        let existingCompatibleKey = keychain.string(forKey: compatibleKey)
        let oldOpenAIKey = keychain.string(forKey: KeychainSecretStore.openAIAPIKey)
        guard let apiKey = existingCompatibleKey?.isEmpty == false ? existingCompatibleKey : oldOpenAIKey,
              !apiKey.isEmpty else {
            return false
        }

        if existingCompatibleKey?.isEmpty != false {
            let result = keychain.setString(apiKey, forKey: compatibleKey)
            guard case .success = result, keychain.string(forKey: compatibleKey) == apiKey else {
                NSLog("⚠️ Could not migrate the legacy OpenAI API key to Compatible API")
                return false
            }

            // Delete the legacy key only after the compatible key has been read back.
            _ = keychain.delete(forKey: KeychainSecretStore.openAIAPIKey)
        }

        let compatibleBaseURL = defaults.string(forKey: "openAICompatibleBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compatibleBaseURL?.isEmpty != false {
            let legacyBaseURL = defaults.string(forKey: "openAISummarizationBaseURL") ?? "https://api.openai.com/v1"
            defaults.set(OpenAICompatibleService.normalizedBaseURL(legacyBaseURL), forKey: "openAICompatibleBaseURL")
        }
        let compatibleModel = defaults.string(forKey: "openAICompatibleModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compatibleModel?.isEmpty != false {
            let legacyModel = defaults.string(forKey: "openAISummarizationModel") ?? "gpt-4.1-mini"
            defaults.set(legacyModel, forKey: "openAICompatibleModel")
        }
        if defaults.object(forKey: "openAICompatibleTemperature") == nil {
            let legacyTemperature = defaults.double(forKey: "openAISummarizationTemperature")
            defaults.set(legacyTemperature > 0 ? legacyTemperature : 0.1, forKey: "openAICompatibleTemperature")
        }
        if defaults.object(forKey: "openAICompatibleMaxTokens") == nil {
            let legacyMaxTokens = defaults.integer(forKey: "openAISummarizationMaxTokens")
            defaults.set(legacyMaxTokens > 0 ? legacyMaxTokens : 2048, forKey: "openAICompatibleMaxTokens")
        }
        defaults.set(true, forKey: "enableOpenAICompatible")
        return true
    }

    /// Selects an engine that is actually configured, or leaves the selection
    /// unconfigured so the user can choose one instead of creating a dead state.
    private func setConfiguredFallbackAIEngine(forKey key: String) {
        let fallback = AIEngineType.availableCases.first { engineType in
            AIEngineFactory.createEngine(type: engineType).isAvailable
        }
        if let fallback {
            UserDefaults.standard.set(fallback.rawValue, forKey: key)
            NSLog("✅ Migrated unavailable AI selection to configured \(fallback.displayName)")
        } else {
            UserDefaults.standard.set("None", forKey: key)
            NSLog("⚠️ No configured AI engine is available; leaving selection unconfigured")
        }
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

    /// Migrates users from Apple Intelligence to the current on-device AI
    /// engine. The migration key is retained for existing installations that
    /// have already run older versions of this migration.
    private func migrateAppleIntelligenceToMLX() {
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

            // Migrate to MLX when the device supports it. Otherwise preserve
            // the existing app policy of selecting a configured alternative.
            if let modelID = MLXSwiftSettingsKeys.recommendedModelId(
                forRAM: DeviceCapabilities.totalRAMInGB
            ) {
                UserDefaults.standard.set(AIEngineType.mlxSwift.rawValue, forKey: aiEngineKey)
                UserDefaults.standard.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                UserDefaults.standard.set(modelID, forKey: MLXSwiftSettingsKeys.modelId)
            } else {
                setConfiguredFallbackAIEngine(forKey: aiEngineKey)
            }

            // Also update transcription if it was using Apple Intelligence
            let transcriptionEngineKey = "selectedTranscriptionEngine"
            let currentTranscription = UserDefaults.standard.string(forKey: transcriptionEngineKey)
            if let transcription = currentTranscription, appleIntelligenceVariants.contains(transcription) {
                UserDefaults.standard.set(TranscriptionEngine.fluidAudio.rawValue, forKey: transcriptionEngineKey)
                UserDefaults.standard.set(true, forKey: FluidAudioModelInfo.SettingsKeys.enableFluidAudio)
                UserDefaults.standard.set(true, forKey: "showParakeetMigrationSettings")
            }

            NSLog("✅ Migrated from Apple Intelligence (\(engine)) to the current on-device AI engine")
        }

        // Mark migration as complete
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Migrates removed Google AI Studio and on-device models to current defaults.
    /// This keeps existing installations from retaining invalid model selections.
    private func migrateRemovedModels() {
        let migrationKey = "removedModelsMigrated_v1.8"

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            return
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

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Migrates any persisted llama.cpp selection to the closest MLX model and
    /// removes the old engine's settings and known downloaded GGUF files.
    /// This also handles stale pre-v2.0 selections that should never be active
    /// on the current 6GB+ llama.cpp path but may still be present in storage.
    private func migrateLegacyLlamaCppToMLX() {
        let defaults = UserDefaults.standard

        // Disk cleanup carries its own key so a failed deletion can be retried.
        // The legacy engine is gone, so a file left behind here has no other
        // code path left to reclaim it and would be orphaned permanently.
        migrateLegacyLlamaCppModelFiles(defaults: defaults)

        let migrationKey = "llamaCppRemovalMigration_v2.4"
        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        let selectedEngine = defaults.string(forKey: "SelectedAIEngine")
        let selectedModel = defaults.string(forKey: LegacyLlamaMigration.legacySelectedModelKey)
        let wasUsingLegacyEngine = LegacyLlamaMigration.isLegacyEngineIdentifier(selectedEngine)

        if wasUsingLegacyEngine {
            if let modelID = LegacyLlamaMigration.mlxModelID(
                forLegacyModelID: selectedModel,
                ramGB: DeviceCapabilities.totalRAMInGB
            ) {
                defaults.set(AIEngineType.mlxSwift.rawValue, forKey: "SelectedAIEngine")
                defaults.set(true, forKey: MLXSwiftSettingsKeys.enabled)
                defaults.set(modelID, forKey: MLXSwiftSettingsKeys.modelId)
                NSLog("✅ Migrated legacy llama.cpp selection to MLX model \(modelID)")
            } else {
                // This is only reachable for stale pre-v2.0 data on a device
                // below MLX's 4GB floor. Pick an engine that is actually
                // configured rather than assuming Mistral has credentials.
                setConfiguredFallbackAIEngine(forKey: "SelectedAIEngine")
            }

            // The user's downloaded GGUF weights were just deleted and the
            // replacement MLX model is almost certainly not downloaded yet, so
            // tell them instead of letting the next summary silently pull
            // hundreds of megabytes (or fail outright while offline).
            defaults.set(true, forKey: "showLlamaCppRemovalAlert")
        }

        let removedSettings = LegacyLlamaMigration.clearLegacySettings(from: defaults)
        if !removedSettings.isEmpty {
            NSLog("✅ Removed \(removedSettings.count) legacy llama.cpp settings")
        }
    }

    /// Repairs MLX model selections that are too large for the device. Older
    /// setup flows wrote the 6GB-only 4B model on any device that cleared the
    /// 4GB MLX floor, which left 4-6GB devices pointing at a model they cannot
    /// load and that the model picker hides.
    private func migrateUnsupportedMLXModelSelection() {
        let migrationKey = "mlxModelTierRepair_v2.4"
        let defaults = UserDefaults.standard

        guard !defaults.bool(forKey: migrationKey) else { return }
        defer { defaults.set(true, forKey: migrationKey) }

        guard let stored = defaults.string(forKey: MLXSwiftSettingsKeys.modelId) else { return }
        guard let supported = MLXSwiftSettingsKeys.supportedModelId(
            stored,
            forRAM: DeviceCapabilities.totalRAMInGB
        ), supported != stored else {
            return
        }

        defaults.set(supported, forKey: MLXSwiftSettingsKeys.modelId)
        NSLog("✅ Repaired unsupported MLX model selection '\(stored)' → '\(supported)'")
    }

    /// Deletes known legacy GGUF files, retrying on later launches until the
    /// cleanup actually completes.
    private func migrateLegacyLlamaCppModelFiles(defaults: UserDefaults) {
        let cleanupKey = "llamaCppModelCleanup_v2.4"
        guard !defaults.bool(forKey: cleanupKey) else { return }

        let cleanup = LegacyLlamaMigration.removeDownloadedModels()

        if !cleanup.removed.isEmpty {
            NSLog("✅ Removed \(cleanup.removed.count) legacy llama.cpp model files")
        }

        if cleanup.isComplete {
            defaults.set(true, forKey: cleanupKey)
        } else {
            NSLog("⚠️ \(cleanup.failed.count) legacy llama.cpp model files could not be removed; will retry on next launch")
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

        guard PlatformApp.isProtectedDataAvailable else {
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
        BisonNotesUITestSupport.configureProcessDefaults()
#endif
        KeychainSecretStore.shared.migrateLegacySecretsFromUserDefaults()

        // Log device capabilities on startup
        logDeviceCapabilities()

        setupBackgroundTasks()
        setupAppShortcuts()
        migrateAIEngineSelection()
        Self.migrateIOSOllamaSelection()
        migrateLegacyLlamaCppToMLX()
        migrateAppleIntelligenceToMLX()
        migrateRemovedProviderSelections()
        migrateWhisperKitToParakeet()
        migrateRemovedModels()
        migrateUnsupportedMLXModelSelection()
        migrateiCloudSensitiveBackupDefault()
        setupDarwinNotificationObserver()
        ActionButtonLaunchManager.startObservingRecordingRequests()
    }

    /// Registers a Darwin notification observer so the Share Extension can signal
    /// the main app to scan the shared container immediately (works when the app
    /// is suspended or backgrounded).
    private func setupDarwinNotificationObserver() {
        let name = ShareExtensionContract.darwinNotificationName as CFString
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
        let report = DeviceCapabilities.getCapabilityReport()
            .split(whereSeparator: \.isNewline)
            .dropFirst(2)
            .joined(separator: ", ")
        AppLog.shared.general("Device capabilities: \(report)")
    }

    private func queueParakeetStartupRepairIfNeeded() {
        guard !hasQueuedParakeetStartupRepair else { return }
        hasQueuedParakeetStartupRepair = true

        Task { @MainActor in
            let selectedEngineRaw = UserDefaults.standard.string(forKey: "selectedTranscriptionEngine")
            guard selectedEngineRaw == TranscriptionEngine.fluidAudio.rawValue else {
                AppLog.shared.transcription(
                    "Parakeet startup repair skipped: selected transcription engine is \(selectedEngineRaw ?? "nil")",
                    level: .debug
                )
                return
            }

            guard TranscriptionEngine.fluidAudio.isAvailable else {
                AppLog.shared.transcription(
                    "Parakeet startup repair skipped: FluidAudio is not available on this device/build",
                    level: .debug
                )
                return
            }

            let manager = FluidAudioManager.shared
            guard !manager.isModelReady else {
                AppLog.shared.transcription(
                    "Parakeet startup repair skipped: selected model is already ready",
                    level: .debug
                )
                return
            }

            guard !manager.isDownloading else {
                AppLog.shared.transcription(
                    "Parakeet startup repair skipped: download already in progress",
                    level: .debug
                )
                return
            }

            guard await Self.isOnWiFiForStartupModelDownload() else {
                AppLog.shared.transcription(
                    "Parakeet startup repair skipped: Wi-Fi is not available",
                    level: .debug
                )
                return
            }

            do {
                AppLog.shared.transcription(
                    "Parakeet startup repair: selected model is missing or incomplete; starting Wi-Fi background download"
                )
                try await manager.downloadAndPrepareModel()
                AppLog.shared.transcription("Parakeet startup repair completed")
            } catch {
                AppLog.shared.transcription(
                    "Parakeet startup repair failed: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }

    private static func isOnWiFiForStartupModelDownload() async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ParakeetStartupRepairNetworkMonitor")
        monitor.start(queue: queue)
        try? await Task.sleep(nanoseconds: 750_000_000)
        let path = monitor.currentPath
        monitor.cancel()
        return path.status == .satisfied
            && path.usesInterfaceType(.wifi)
            && !path.isExpensive
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .environmentObject(fileImportManager)
                .environmentObject(transcriptImportManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onReceive(NotificationCenter.default.publisher(for: PlatformLifecycle.didFinishLaunchingNotification)) { _ in
                    requestBackgroundAppRefreshPermission()
                    setupWatchConnectivity()
                    // Note: Notification permission is now requested when first needed (in BackgroundProcessingManager)
                    // Initialize download monitor for on-device AI models
                    _ = OnDeviceAIDownloadMonitor.shared
                    queueParakeetStartupRepairIfNeeded()
                    TemporaryFileCleanupService.shared.cleanupStaleFiles()
                    appCoordinator.reconcileiCloudIfEnabled(reason: "app launch", force: true)
                }
                .onOpenURL(perform: handleOpenURL)
                #if os(iOS)
                // iOS can kill a backgrounded app without ever sending willTerminate, so
                // entering the background is the last reliable clean-shutdown checkpoint.
                // On macOS this notification maps to NSApplication.didHideNotification (Cmd-H),
                // which is NOT a shutdown — a crash while hidden must still be detected — so
                // macOS relies on willTerminate below instead.
                .onReceive(NotificationCenter.default.publisher(for: PlatformLifecycle.didEnterBackgroundNotification)) { _ in
                    AppLog.shared.markCleanShutdown()
                }
                #endif
                .onReceive(NotificationCenter.default.publisher(for: PlatformLifecycle.willTerminateNotification)) { _ in
                    AppLog.shared.markCleanShutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: PlatformLifecycle.didBecomeActiveNotification)) { _ in
                    AppLog.shared.markSessionActive()
                    // Clear badge when the user actively opens the app. Using the
                    // scene-phase notification here (rather than AppDelegate
                    // applicationDidBecomeActive) ensures this fires reliably in
                    // scene-based SwiftUI apps where the UIApplicationDelegate method
                    // may be skipped.
                    appDelegate.clearAppBadge(reason: "activation")
                    // Repair any files left at .complete protection by v1.11.0.
                    migrateFileProtectionForExistingFiles()
                    TemporaryFileCleanupService.shared.cleanupStaleFiles()
                    // Scan for files placed by the Share Extension (Voice Memos, etc.)
                    scanSharedContainerForImports(trigger: .pendingToken)
                    // Also scan Documents/Inbox/ for files from "Open In" / document interaction.
                    scanInboxForImportableFiles()
                    appCoordinator.reconcileiCloudIfEnabled(reason: "app active")
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ShareExtensionDidSaveFile"))) { _ in
                    NSLog("📎 Darwin notification received from Share Extension")
                    scanSharedContainerForImports(trigger: .pendingToken)
                }
                .nativeMainWindowSizing()
        }
        #if os(macOS)
        .defaultSize(width: 1_100, height: 720)
        .windowResizability(.contentMinSize)
        #endif
        .commands {
            // MARK: - Mac Menu Bar Commands
            // Keep the system undo/redo and pasteboard groups untouched so
            // focused TextField/TextEditor controls retain standard Edit-menu behavior.
            CommandGroup(replacing: .newItem) {
                Button("New Recording") {
                    postRecordingCommand(named: "ToggleRecording")
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Import Audio...") {
                    postRecordingCommand(named: "ImportAudioFromMenu")
                }
                .keyboardShortcut("i", modifiers: .command)

                Button("Import Transcript...") {
                    postRecordingCommand(named: "ImportTranscriptFromMenu")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Import From Link...") {
                    postRecordingCommand(named: "ImportFromLinkFromMenu")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("Export Summary...") {
                    summaryExportAction?.perform()
                }
                .disabled(summaryExportAction == nil)
            }

            #if os(macOS)
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    transcriptSaveAction?.perform()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(transcriptSaveAction == nil)
            }
            #endif

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

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .frame(minWidth: 680, minHeight: 600)
        }
        .defaultSize(width: 760, height: 700)

        // Restoration stays disabled so the window never reopens on its own at launch:
        // its `.task` starts a CloudKit scan, which must remain user-initiated.
        Window("iCloud Items Review", id: NativeWindowID.cloudReview) {
            CloudReviewItemsView()
                .environmentObject(appCoordinator)
                .frame(minWidth: 680, minHeight: 520)
        }
        .defaultSize(width: 780, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        WindowGroup("Summary", id: NativeWindowID.summary, for: UUID.self) { $recordingID in
            if let recordingID {
                NativeSummaryWindowView(recordingID: recordingID)
                    .environmentObject(appCoordinator)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            } else {
                ContentUnavailableView(
                    "Summary Not Available",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a summary from the main window.")
                )
            }
        }
        .defaultSize(width: 760, height: 700)
        .windowResizability(.contentMinSize)

        WindowGroup("Transcript", id: NativeWindowID.transcript, for: UUID.self) { $recordingID in
            if let recordingID {
                NativeTranscriptWindowView(recordingID: recordingID)
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            }
        }
        .defaultSize(width: 820, height: 720)
        .windowResizability(.contentMinSize)

        // Single player window by design — the app supports only one open
        // recording player at a time. A singleton Window (driven by
        // appCoordinator.macPlayerRecordingID) prevents multiple player windows
        // from fighting over the shared AudioRecorderViewModel playback state.
        Window("Recording", id: NativeWindowID.recording) {
            if let recordingID = appCoordinator.macPlayerRecordingID {
                NativeRecordingWindowView(recordingID: recordingID)
                    .environmentObject(recorderVM)
                    .environmentObject(appCoordinator)
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            } else {
                ContentUnavailableView(
                    "No Recording Selected",
                    systemImage: "waveform",
                    description: Text("Choose a recording from the library to play it here.")
                )
            }
        }
        .defaultSize(width: 720, height: 680)
        .windowResizability(.contentMinSize)

        Window("Recordings", id: NativeWindowID.recordings) {
            RecordingsListView()
                .nativeMacPresentationContext(.modelessWindow)
                .environment(\.isEmbeddedInSplitView, false)
                .environmentObject(recorderVM)
                .environmentObject(appCoordinator)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 900, height: 720)
        .windowResizability(.contentMinSize)

        WindowGroup("Location", id: NativeWindowID.location, for: LocationData.self) { $locationData in
            if let locationData {
                LocationDetailView(locationData: locationData)
                    .nativeMacPresentationContext(.modelessWindow)
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 680, height: 620)
        .windowResizability(.contentMinSize)

        Window("Background Processing", id: NativeWindowID.backgroundProcessing) {
            BackgroundProcessingView()
                .nativeMacPresentationContext(.modelessWindow)
                .frame(minWidth: 620, minHeight: 500)
        }
        .defaultSize(width: 760, height: 680)
        .windowResizability(.contentMinSize)

        WindowGroup("Processing Job", id: NativeWindowID.processingJob, for: UUID.self) { $jobID in
            if let jobID {
                NativeProcessingJobWindowView(jobID: jobID)
            }
        }
        .defaultSize(width: 620, height: 540)
        .windowResizability(.contentMinSize)
        #endif
    }

    private func postRecordingCommand(named name: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("SwitchToRecordTabForImport"),
            object: nil
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name(name), object: nil)
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

    private let appGroupID = ShareExtensionContract.appGroupIdentifier
    private let shareInboxFolder = ShareExtensionContract.inboxFolderName

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
            // If an import is already running, importAudioFiles/importTranscriptFiles
            // would silently no-op and the cleanup below would still delete every staged
            // file — discarding the share. Re-arm the token and leave the inbox intact so
            // a later activation scan retries once the importer is free.
            if fileImportManager.isImporting || transcriptImportManager.isImporting {
                NSLog("📎 Shared container scan deferred: an import is already in progress")
                ShareImportAuthorization.rearmToken(in: containerURL)
                return
            }

            var audioFiles: [URL] = []
            var textFiles: [URL] = []

            let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aif"]
            let textExtensions = ShareExtensionContract.supportedExtensions
                .subtracting(audioExtensions)

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
            // If an import is already running, importAudioFiles/importTranscriptFiles
            // would silently no-op and the cleanup below would still delete every Inbox
            // file — discarding the share. Leave the files so the next activation scan
            // retries (this Inbox scan runs unconditionally, so no token is needed).
            if fileImportManager.isImporting || transcriptImportManager.isImporting {
                NSLog("📎 Inbox scan deferred: an import is already in progress")
                return
            }

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
        #if os(iOS)
        // Register background task identifiers
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.bisonai.audio-processing", using: nil) { task in
            handleBackgroundProcessing(task: task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.bisonai.app-refresh", using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        #endif
        // macOS: no BGTaskScheduler — the app keeps running; jobs continue in-process.
    }

    private func requestBackgroundAppRefreshPermission() {
        #if os(iOS)
        // Background app refresh is now handled via BGTaskScheduler in setupBackgroundTasks()
        // No need for the deprecated setMinimumBackgroundFetchInterval
        AppLog.shared.general("Background app refresh configured via BGTaskScheduler")
        #else
        AppLog.shared.general("Mac background jobs continue in-process", level: .debug)
        #endif
    }

    #if os(iOS)
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
    #endif

    private func setupWatchConnectivity() {
        // Initialize watch connectivity for background sync
        let watchManager = WatchConnectivityManager.shared

        // The sync handler will be set up by AudioRecorderViewModel when it's ready
        // We just need to ensure the WatchConnectivityManager singleton is initialized

        // Note: onWatchSyncRecordingReceived is set up by AudioRecorderViewModel
        // Don't override it here - let the proper Core Data integration handle it

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

    }

    private func setupAppShortcuts() {
        // Update app shortcuts to include our recording intent
        Task {
            AppShortcuts.updateAppShortcutParameters()
        }

        #if os(iOS)
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
                    _ = controls.map { $0.kind }
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

private extension View {
    @ViewBuilder
    func nativeMainWindowSizing() -> some View {
        #if os(macOS)
        frame(minWidth: 860, minHeight: 560)
        #else
        self
        #endif
    }
}
