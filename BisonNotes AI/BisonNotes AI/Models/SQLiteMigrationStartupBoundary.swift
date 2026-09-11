import CoreData
import Foundation

enum SQLiteMigrationStartupBoundaryStatus: Equatable, Sendable {
    case notPrepared
    case notApplicable
    case ready
    case needsReview
}

/// Builds the app-facing migration inputs without selecting a SQLite
/// generation. This is the narrow pre-cutover bridge: source-list drift and
/// settings normalization are checked during startup, while the current
/// Core Data store remains authoritative and UserDefaults remains unchanged.
@MainActor
enum SQLiteMigrationStartupBoundary {
    static func makeNormalizationContext() throws -> LibrarySettingsNormalizationContext {
        try LibrarySettingsCatalog.validateSourceKeys(
            LibrarySettingsSourceInventory.standardDefaultsKeys
        )
        try LibrarySettingsSourceInventory.validateCloudKitSourceKeys(
            iCloudStorageManager.backedUpSettingsKeys
        )

        let supportsMLX = DeviceCapabilities.supportsMLX
        let ramGB = DeviceCapabilities.totalRAMInGB
        let supportedModelIDs = Set<String>(
            MLXSwiftSettingsKeys.minimumRAMGB.compactMap { modelID, requiredRAMGB -> String? in
                guard supportsMLX, ramGB >= requiredRAMGB else { return nil }
#if os(macOS)
                return modelID
#else
                return modelID == MLXSwiftSettingsKeys.macModelId ? nil : modelID
#endif
            }
        )

        return LibrarySettingsNormalizationContext(
            targetPlatform: targetPlatform,
            supportsMLX: supportsMLX,
            supportedMLXModelIDs: supportedModelIDs,
            preferredMLXModelID: MLXSwiftSettingsKeys.recommendedModelId(forRAM: ramGB),
            fallbackAIEngine: supportsMLX ? AIEngineType.mlxSwift.rawValue : "None",
            fallbackTranscriptionEngine: TranscriptionEngine.notConfigured.rawValue
        )
    }

    static func captureNormalizedSettings(
        from defaults: UserDefaults = .standard
    ) async throws -> LibrarySettingsNormalizationResult {
        let context = try makeNormalizationContext()
        let sourceStore = try UserDefaultsLibrarySettingsStore(
            defaults: defaults,
            allowedKeys: LibrarySettingsCatalog.blockingMetadataKeys
        )
        let sourceSnapshot = try await sourceStore.read()
        return try LibrarySettingsNormalizer.normalize(sourceSnapshot, for: context)
    }

    private static var targetPlatform: LibrarySettingsTargetPlatform {
#if os(macOS)
        return .macOS
#else
        return .iOS
#endif
    }
}
