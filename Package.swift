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
                "SQLiteLibraryStore.swift",
                "SQLiteLibraryStoreOperationalSchema.swift",
                "SQLiteLibraryStoreSchema.swift",
                "SQLiteMigrationModels.swift",
                "SQLiteMigrationStoreSupport.swift"
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
