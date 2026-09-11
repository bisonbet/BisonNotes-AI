import Foundation

enum LibrarySettingDisposition: String, CaseIterable, Equatable, Sendable {
    case blockingMetadata
    case owningStore
    case deviceLocal
    case derivedRuntime
    case excludedSecret
}

enum LibrarySettingValueKind: String, CaseIterable, Equatable, Sendable {
    case string
    case integer
    case real
    case bool
    case data
    case date
    case array
}

struct LibrarySettingDefinition: Equatable, Sendable {
    let key: String
    let valueKind: LibrarySettingValueKind
    let disposition: LibrarySettingDisposition
}

enum LibrarySettingsCatalogError: LocalizedError, Equatable {
    case duplicateDefinition(String)
    case unclassifiedKeys([String])
    case nonMigratableKey(String)
    case invalidValue(key: String, reason: String)
    case valueKindMismatch(
        key: String,
        expected: LibrarySettingValueKind,
        actual: LibrarySettingValueKind
    )
    case sourceInventoryDrift(missing: [String], unexpected: [String])

    var errorDescription: String? {
        switch self {
        case .duplicateDefinition(let key):
            return "The settings catalog defines the key more than once: \(key)"
        case .unclassifiedKeys(let keys):
            return "The settings catalog has unclassified keys: \(keys.joined(separator: ", "))"
        case .nonMigratableKey(let key):
            return "The settings key is not approved for SQLite metadata migration: \(key)"
        case .invalidValue(let key, let reason):
            return "The settings key \(key) has an invalid value: \(reason)"
        case let .valueKindMismatch(key, expected, actual):
            return "The settings key \(key) has value kind \(actual.rawValue); expected \(expected.rawValue)."
        case let .sourceInventoryDrift(missing, unexpected):
            let missingDescription = missing.isEmpty ? "none" : missing.joined(separator: ", ")
            let unexpectedDescription = unexpected.isEmpty ? "none" : unexpected.joined(separator: ", ")
            return "The reviewed settings source drifted. Missing: \(missingDescription). "
                + "Unexpected: \(unexpectedDescription)."
        }
    }
}

/// The reviewed boundary between UserDefaults and migration-owned metadata.
///
/// This catalog is deliberately independent of CloudKit's settings-backup
/// list. A key must be classified before a future coordinator may activate the
/// metadata migration. Only `blockingMetadata` keys can cross into SQLite.
enum LibrarySettingsCatalog {
    static let definitions: [LibrarySettingDefinition] =
        blockingMetadataDefinitions
        + owningStoreDefinitions
        + deviceLocalDefinitions
        + derivedRuntimeDefinitions
        + secretDefinitions

    static let definitionsByKey: [String: LibrarySettingDefinition] = {
        var result: [String: LibrarySettingDefinition] = [:]
        for definition in definitions {
            guard result[definition.key] == nil else {
                preconditionFailure("Duplicate library settings catalog key: \(definition.key)")
            }
            result[definition.key] = definition
        }
        return result
    }()

    static var blockingMetadataKeys: [String] {
        definitions
            .filter { $0.disposition == .blockingMetadata }
            .map(\.key)
            .sorted()
    }

    static var knownKeys: Set<String> {
        Set(definitions.map(\.key))
    }

    static func definition(for key: String) -> LibrarySettingDefinition? {
        if let definition = definitionsByKey[key] {
            return definition
        }
        if key.hasPrefix("KeychainSecretStore.revision.") {
            return LibrarySettingDefinition(
                key: key,
                valueKind: .integer,
                disposition: .excludedSecret
            )
        }
        if key.hasPrefix("migrated_unavailable_") {
            return LibrarySettingDefinition(
                key: key,
                valueKind: .string,
                disposition: .derivedRuntime
            )
        }
        return nil
    }

    static func validateSourceKeys(_ keys: [String]) throws {
        let unclassified = Set(keys).filter { definition(for: $0) == nil }.sorted()
        guard unclassified.isEmpty else {
            throw LibrarySettingsCatalogError.unclassifiedKeys(unclassified)
        }
    }

    static func readMigratableSettings(
        from defaults: UserDefaults = .standard,
        sourceKeys: [String]
    ) async throws -> LibrarySettingsSnapshot {
        try validateSourceKeys(sourceKeys)
        let snapshot = try await readSourceSettings(from: defaults)
        try validateMigratableSnapshot(snapshot)
        return snapshot
    }

    static func readMigratableSettings(
        from defaults: UserDefaults = .standard,
        sourceKeys: [String],
        normalizationContext: LibrarySettingsNormalizationContext
    ) async throws -> LibrarySettingsSnapshot {
        try validateSourceKeys(sourceKeys)
        let snapshot = try await readSourceSettings(from: defaults)
        return try LibrarySettingsNormalizer.normalize(
            snapshot,
            for: normalizationContext
        ).snapshot
    }

    private static func readSourceSettings(
        from defaults: UserDefaults
    ) async throws -> LibrarySettingsSnapshot {
        let store = try UserDefaultsLibrarySettingsStore(
            defaults: defaults,
            allowedKeys: blockingMetadataKeys
        )
        return try await store.read()
    }
}

private extension LibrarySettingsCatalog {
    static var blockingMetadataDefinitions: [LibrarySettingDefinition] {
        [
            definition("SelectedAIEngine", .string),
            definition("selectedTranscriptionEngine", .string),
            definition("showTranscriptionProgress", .bool),
            definition("enableLiveTranscription", .bool),
            definition("summarizationTimeout", .real),
            definition("summaryDetailLevel", .integer),
            definition("summaryThinkingLevel", .integer),
            definition("user_preference_time_format", .string),
            definition("WatchIntegrationEnabled", .bool),
            definition("WatchAutoSync", .bool),
            definition("WatchBatteryAware", .bool),
            definition("isLocationTrackingEnabled", .bool),
            definition("comedyModeEnabled", .bool),
            definition("comedyModeStyle", .string),
            definition("transcriptCleanupEnabled", .bool),
            definition("enableFluidAudio", .bool),
            definition("fluidAudioSelectedModelVersion", .string),
            definition("fluidAudioLocalSpeakerLabelsEnabled", .bool),
            definition("fluidAudioSelectedLocalSpeakerLabelMethod", .string),
            definition("mlxSwiftExperimentalEnabled", .bool),
            definition("mlxSwiftModelId", .string),
            definition("mlxSwiftMaxTokens", .integer),
            definition("mlxSwiftTemperature", .real),
            definition("mlxSwiftTopK", .integer),
            definition("mlxSwiftTopP", .real),
            definition("mlxSwiftRepeatPenalty", .real),
            definition("openAICompatibleModel", .string),
            definition("openAICompatibleBaseURL", .string),
            definition("openAICompatibleTemperature", .real),
            definition("openAICompatibleMaxTokens", .integer),
            definition("enableOpenAICompatible", .bool),
            definition("openAICompatibleManualFormatOverride", .bool),
            definition("openAICompatibleManualFormat", .string),
            definition("googleAIStudioModel", .string),
            definition("googleAIStudioTemperature", .real),
            definition("googleAIStudioMaxTokens", .integer),
            definition("enableGoogleAIStudio", .bool),
            definition("mistralBaseURL", .string),
            definition("mistralModel", .string),
            definition("mistralTemperature", .real),
            definition("mistralMaxTokens", .integer),
            definition("enableMistralAI", .bool),
            definition("mistralSupportsJsonResponseFormat", .bool),
            definition("mistralTranscribeModel", .string),
            definition("mistralTranscribeDiarize", .bool),
            definition("mistralTranscribeLanguage", .string),
            definition("ollamaServerURL", .string),
            definition("ollamaPort", .integer),
            definition("ollamaModelName", .string),
            definition("ollamaMaxTokens", .integer),
            definition("ollamaTemperature", .real),
            definition("ollamaContextTokens", .integer),
            definition("enableOllama", .bool),
            definition("enableWhisper", .bool),
            definition("whisperServerURL", .string),
            definition("whisperPort", .integer),
            definition("whisperProtocol", .string),
            definition("allowInsecurePublicAIEndpoints", .bool)
        ]
    }

    static var owningStoreDefinitions: [LibrarySettingDefinition] {
        [
            definition("lastAutoBackupDate", .date, disposition: .owningStore),
            definition("lastSyncDate", .date, disposition: .owningStore),
            definition("iCloudLastSuccessfulRoutineSyncV1", .date, disposition: .owningStore),
            definition("iCloudSyncNextEligibleDateV1", .date, disposition: .owningStore),
            definition("iCloudBackupStateSignatureV1", .string, disposition: .owningStore),
            definition("iCloudActiveManifestMigrationCompletedV2", .bool, disposition: .owningStore),
            definition("iCloudQuarantinedBackupRecordNamesV2", .array, disposition: .owningStore),
            definition("iCloudQuarantinedLegacySummaryRecordNamesV2", .array, disposition: .owningStore),
            definition("iCloudLegacySummaryRecordsAbsentAtV2", .date, disposition: .owningStore),
            definition("iCloudPendingDeletionMarkersV1", .data, disposition: .owningStore),
            definition("iCloudPendingLocalOnlyRemovalsV1", .data, disposition: .owningStore),
            definition("iCloudPendingSummaryRemovalsV1", .data, disposition: .owningStore),
            definition("iCloudPendingTranscriptRemovalsV1", .data, disposition: .owningStore),
            definition("iCloudPendingImportedAudioRemovalsV1", .data, disposition: .owningStore),
            definition("iCloudSyncEnabled", .bool, disposition: .owningStore),
            definition("unifiedICloudSyncEnabled", .bool, disposition: .owningStore),
            definition("shouldPerformFullSyncOnStartup", .bool, disposition: .owningStore),
            definition("autoSyncMode", .string, disposition: .owningStore),
            definition("hasCompletedInitialSetup", .bool, disposition: .owningStore),
            definition("hasCompletedFirstSetup", .bool, disposition: .owningStore),
            definition("hasCompletedInitialLaunch", .bool, disposition: .owningStore),
            definition("hasSeeniCloudPrompt", .bool, disposition: .owningStore),
            definition("iCloudBackupIncludeAudioFiles", .bool, disposition: .owningStore),
            definition("iCloudBackupIncludeSettings", .bool, disposition: .owningStore),
            definition("iCloudBackupIncludeSensitiveSettings", .bool, disposition: .owningStore),
            definition("AppLog_CleanShutdown", .bool, disposition: .owningStore),
            definition("hasAskedLocationPermission", .bool, disposition: .owningStore),
            definition("aiEngineSelectionMigrated_v1.3", .bool, disposition: .owningStore),
            definition("removedProviderSelectionsMigrated_v2.3", .bool, disposition: .owningStore),
            definition("removedProviderSelectionsMigrated_v2.5", .bool, disposition: .owningStore),
            definition("whisperKitRemovedMigration_v1.8", .bool, disposition: .owningStore),
            definition("appleIntelligenceToOnDeviceLLMMigrated_v1.4", .bool, disposition: .owningStore),
            definition("removedModelsMigrated_v1.8", .bool, disposition: .owningStore),
            definition("googleAIStudioModelNamesMigrated_v1", .bool, disposition: .owningStore),
            definition("llamaCppRemovalMigration_v2.4", .bool, disposition: .owningStore),
            definition("mlxModelTierRepair_v2.4", .bool, disposition: .owningStore),
            definition("llamaCppModelCleanup_v2.4", .bool, disposition: .owningStore),
            definition("iCloudSensitiveBackupDefaultMigrated_v1.4", .bool, disposition: .owningStore),
            definition("fileProtectionDowngradeMigration_v1.11.1", .bool, disposition: .owningStore),
            definition("showOllamaMigrationAlert", .bool, disposition: .owningStore),
            definition("showWhisperKitSwitchedToParakeet", .bool, disposition: .owningStore),
            definition("showWhisperKitRemovedAlert", .bool, disposition: .owningStore),
            definition("showAppleIntelligenceMigrationAlert", .bool, disposition: .owningStore),
            definition("showParakeetMigrationSettings", .bool, disposition: .owningStore),
            definition("showLlamaCppRemovalAlert", .bool, disposition: .owningStore),
            definition("openAISummarizationBaseURL", .string, disposition: .owningStore),
            definition("openAISummarizationModel", .string, disposition: .owningStore),
            definition("openAISummarizationTemperature", .real, disposition: .owningStore),
            definition("openAISummarizationMaxTokens", .integer, disposition: .owningStore),
            definition("enableWhisperKit", .bool, disposition: .owningStore),
            definition("whisperKitSelectedModel", .string, disposition: .owningStore),
            definition("whisperKitModelDownloaded", .bool, disposition: .owningStore),
            definition("whisperKitModelPath", .string, disposition: .owningStore),
            definition("enableOnDeviceLLM", .bool, disposition: .owningStore),
            definition("onDeviceLLMSelectedModel", .string, disposition: .owningStore),
            definition("onDeviceLLMEnableExperimentalModels", .bool, disposition: .owningStore),
            definition("onDeviceLLMTemperature", .real, disposition: .owningStore),
            definition("onDeviceLLMMaxTokens", .integer, disposition: .owningStore),
            definition("onDeviceLLMTopK", .integer, disposition: .owningStore),
            definition("onDeviceLLMTopP", .real, disposition: .owningStore),
            definition("onDeviceLLMMinP", .real, disposition: .owningStore),
            definition("onDeviceLLMRepeatPenalty", .real, disposition: .owningStore),
            definition("currentlyDownloadingModelId", .string, disposition: .owningStore),
            definition("onDeviceLLMNameMigration_v1.5", .bool, disposition: .owningStore),
            definition("legacyOnDeviceSubSixGBMigration_v2.0", .bool, disposition: .owningStore),
            definition("SavedEnhancedSummaries", .data, disposition: .owningStore),
            definition("SavedEnhancedSummariesMigrationVersion", .integer, disposition: .owningStore),
            definition("iCloudLegacySummaryDiscoveryCompletedV1", .bool, disposition: .owningStore)
        ]
    }

    static var deviceLocalDefinitions: [LibrarySettingDefinition] {
        [
            definition("fluidAudioModelDownloaded", .bool, disposition: .deviceLocal),
            definition("fluidAudioDownloadedModelVersion", .string, disposition: .deviceLocal),
            definition("mlxSwiftInFlightDownloadModelID", .string, disposition: .deviceLocal),
            definition("processedWatchRecordingIds", .array, disposition: .deviceLocal),
            definition("PreferredAudioInputUID", .string, disposition: .deviceLocal),
            definition("MacSystemAudioCaptureEnabled", .bool, disposition: .deviceLocal),
            definition("actionButtonShouldStartRecording", .bool, disposition: .deviceLocal),
            definition("bisonnotes.mac.settings.selectedPane", .string, disposition: .deviceLocal),
            definition("PlatformDeviceVendorIdentifier", .string, disposition: .deviceLocal)
        ]
    }

    static var derivedRuntimeDefinitions: [LibrarySettingDefinition] {
        [
            definition("SelectedAIModel", .string, disposition: .derivedRuntime),
            definition("mlxSwiftContextTokens", .integer, disposition: .derivedRuntime),
            definition("maxChunkDuration", .real, disposition: .derivedRuntime),
            definition("maxTranscriptionTime", .real, disposition: .derivedRuntime),
            definition("chunkOverlap", .real, disposition: .derivedRuntime),
            definition("lastGeneratedTitle", .string, disposition: .derivedRuntime)
        ]
    }

    static var secretDefinitions: [LibrarySettingDefinition] {
        [
            definition("openAIAPIKey", .string, disposition: .excludedSecret),
            definition("openAICompatibleAPIKey", .string, disposition: .excludedSecret),
            definition("googleAIStudioAPIKey", .string, disposition: .excludedSecret),
            definition("mistralAPIKey", .string, disposition: .excludedSecret),
            definition("AWSCredentials", .data, disposition: .excludedSecret),
            definition("awsBedrockSessionToken", .string, disposition: .excludedSecret),
            definition("awsAccessKey", .string, disposition: .excludedSecret),
            definition("awsSecretKey", .string, disposition: .excludedSecret),
            definition("awsSecretAccessKey", .string, disposition: .excludedSecret),
            definition("awsRegion", .string, disposition: .excludedSecret),
            definition("awsBucketName", .string, disposition: .excludedSecret),
            definition("awsBedrockModel", .string, disposition: .excludedSecret),
            definition("awsBedrockTemperature", .real, disposition: .excludedSecret),
            definition("awsBedrockMaxTokens", .integer, disposition: .excludedSecret),
            definition("awsBedrockUseProfile", .bool, disposition: .excludedSecret),
            definition("awsBedrockProfileName", .string, disposition: .excludedSecret),
            definition("awsBedrockModelMigrated_v1.3", .bool, disposition: .excludedSecret),
            definition("enableAWSBedrock", .bool, disposition: .excludedSecret),
            definition("enableAWSTranscribe", .bool, disposition: .excludedSecret)
        ]
    }

    static func definition(
        _ key: String,
        _ valueKind: LibrarySettingValueKind,
        disposition: LibrarySettingDisposition = .blockingMetadata
    ) -> LibrarySettingDefinition {
        LibrarySettingDefinition(key: key, valueKind: valueKind, disposition: disposition)
    }
}
