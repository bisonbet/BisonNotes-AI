import XCTest
@testable import BisonNotes_AI

final class SQLiteMigrationSettingsCatalogTests: XCTestCase {
    @MainActor
    func testCloudKitSettingsSourceKeysAreClassified() throws {
        let sourceKeys = iCloudStorageManager.backedUpSettingsKeys

        XCTAssertFalse(sourceKeys.isEmpty)
        XCTAssertEqual(sourceKeys.count, Set(sourceKeys).count)
        try LibrarySettingsCatalog.validateSourceKeys(sourceKeys)
    }

    @MainActor
    func testCloudKitSettingsSourceMatchesReviewedBlockingInventory() {
        let cloudKitKeys = Set(iCloudStorageManager.backedUpSettingsKeys)
        let reviewedOmissions = LibrarySettingsSourceInventory.reviewedCloudKitOmissions
        let blockingKeys = Set(LibrarySettingsCatalog.blockingMetadataKeys)
        let sourceKeys = Set(LibrarySettingsSourceInventory.standardDefaultsKeys)

        XCTAssertNoThrow(
            try LibrarySettingsSourceInventory.validateCloudKitSourceKeys(
                iCloudStorageManager.backedUpSettingsKeys
            )
        )
        XCTAssertTrue(cloudKitKeys.isSubset(of: sourceKeys))
        XCTAssertTrue(cloudKitKeys.isDisjoint(with: reviewedOmissions))
        XCTAssertEqual(cloudKitKeys.union(reviewedOmissions), blockingKeys)
        XCTAssertTrue(LegacyLlamaMigration.legacySettingsKeys.isSubset(of: sourceKeys))
    }

    @MainActor
    func testStartupBoundaryNormalizesWithoutWritingDefaults() async throws {
        let suiteName = "BisonNotesSQLiteStartupBoundary-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(" OpenAI ", forKey: "SelectedAIEngine")
        defaults.set("On Device (WhisperKit)", forKey: "selectedTranscriptionEngine")
        defaults.set(" https://example.test/v1/// ", forKey: "openAICompatibleBaseURL")

        let normalized = try await SQLiteMigrationStartupBoundary.captureNormalizedSettings(
            from: defaults
        )

        XCTAssertEqual(
            normalized.snapshot.values["SelectedAIEngine"],
            .string("OpenAI API Compatible")
        )
        XCTAssertEqual(
            normalized.snapshot.values["selectedTranscriptionEngine"],
            .string("On Device")
        )
        XCTAssertEqual(
            normalized.snapshot.values["openAICompatibleBaseURL"],
            .string("https://example.test/v1")
        )
        XCTAssertEqual(defaults.string(forKey: "SelectedAIEngine"), " OpenAI ")
        XCTAssertEqual(
            defaults.string(forKey: "selectedTranscriptionEngine"),
            "On Device (WhisperKit)"
        )
        XCTAssertEqual(
            defaults.string(forKey: "openAICompatibleBaseURL"),
            " https://example.test/v1/// "
        )
    }

    func testLegacySettingsSourceKeysAreClassified() throws {
        try LibrarySettingsCatalog.validateSourceKeys(
            Array(LegacyLlamaMigration.legacySettingsKeys)
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "onDeviceLLMEnableExperimentalModels")?.disposition,
            .owningStore
        )
    }

    func testReviewedSourceOmissionsRemainClassified() throws {
        let omittedUserFacingKeys = [
            "enableFluidAudio",
            "fluidAudioSelectedModelVersion",
            "enableLiveTranscription",
            "transcriptCleanupEnabled",
            "comedyModeEnabled",
            "comedyModeStyle",
            "allowInsecurePublicAIEndpoints"
        ]

        try LibrarySettingsCatalog.validateSourceKeys(omittedUserFacingKeys)
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "fluidAudioSelectedModelVersion")?.disposition,
            .blockingMetadata
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "mistralTranscribeModel")?.disposition,
            .blockingMetadata
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "PlatformDeviceVendorIdentifier")?.disposition,
            .deviceLocal
        )
    }
}
