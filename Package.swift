// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BisonNotesSQLiteRuntime",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BisonNotesSQLiteRuntime",
            targets: ["BisonNotesSQLiteRuntime"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        )
    ],
    targets: [
        .target(
            name: "BisonNotesSQLiteRuntime",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "BisonNotes AI/BisonNotes AI/Models",
            exclude: [
                "AdvancedTroubleshootingService.swift",
                "AppDataCoordinator.swift",
                "AudioChunkingModels.swift",
                "AudioModels.swift",
                "ConfigurationWarningHelper.swift",
                "CoreDataManager.swift",
                "CoreDataLibraryRepository.swift",
                "DataMigrationManager.swift",
                "DeviceCompatibility.swift",
                "EnhancedSummaryData.swift",
                "MacRecordingReliability.swift",
                "RecordingArchiveService.swift",
                "RecordingFile.swift",
                "RecordingNameGenerator.swift",
                "RecordingWorkflowManager.swift",
                "SummaryAttachmentStore.swift",
                "SummaryMetadataCodec.swift",
                "SummaryPresencePolicy.swift",
                "SummaryThinking.swift",
                "SummaryThinkingModelCatalog.swift",
                "SummarizationEngine.swift",
                "SummarizationErrors.swift",
                "TranscriptData.swift",
                "TranscriptManager.swift",
                "TranscriptionStarter.swift",
                "UserPreferences.swift"
            ],
            sources: [
                "LibraryRepository.swift",
                "LibraryObservation.swift",
                "CoreDataLibraryObservation.swift",
                "CoreDataMigrationSnapshotReader.swift",
                "LibrarySettingsStore.swift",
                "LibrarySettingsCatalog.swift",
                "LibrarySettingsCatalogValidation.swift",
                "SQLiteLibraryStore.swift",
                "SQLiteLibraryObservation.swift",
                "SQLiteLibraryStoreMigrations.swift",
                "SQLiteLibrarySettingsPersistence.swift",
                "SQLiteLibraryStoreOperationalSchema.swift",
                "SQLiteLibraryStoreSchema.swift",
                "SQLiteLibraryStoreMigrationImport.swift",
                "SQLiteLibraryStoreRecovery.swift",
                "SQLiteLibraryRepository.swift",
                "SQLiteLibraryRepositoryMapper.swift",
                "SQLiteMigrationModels.swift",
                "SQLiteMigrationImporter.swift",
                "SQLiteMigrationRecovery.swift",
                "SQLiteMigrationStoreSupport.swift",
                "SQLiteMigrationVerification.swift",
                "SQLiteMigrationVerifier.swift"
            ]
        ),
        .testTarget(
            name: "BisonNotesSQLiteRuntimeTests",
            dependencies: [
                "BisonNotesSQLiteRuntime",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "SQLiteMigrationRuntimeTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
