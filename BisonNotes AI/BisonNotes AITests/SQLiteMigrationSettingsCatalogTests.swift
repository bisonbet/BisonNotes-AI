import XCTest
@testable import BisonNotes_AI

final class SQLiteMigrationSettingsCatalogTests: XCTestCase {
    func testCloudKitSettingsSourceKeysAreClassified() throws {
        let sourceKeys = iCloudStorageManager.backedUpSettingsKeys

        XCTAssertFalse(sourceKeys.isEmpty)
        XCTAssertEqual(sourceKeys.count, Set(sourceKeys).count)
        try LibrarySettingsCatalog.validateSourceKeys(sourceKeys)
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
            .derivedRuntime
        )
    }
}
