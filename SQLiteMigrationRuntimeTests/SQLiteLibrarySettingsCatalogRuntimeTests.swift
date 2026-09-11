import Foundation
import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibrarySettingsCatalogRuntimeTests: XCTestCase {
    func testCatalogHasDisjointClassifications() {
        let definitions = LibrarySettingsCatalog.definitions
        let keys = definitions.map(\.key)

        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(keys), LibrarySettingsCatalog.knownKeys)
        XCTAssertFalse(LibrarySettingsCatalog.blockingMetadataKeys.isEmpty)

        for disposition in LibrarySettingDisposition.allCases {
            XCTAssertFalse(
                definitions.filter { $0.disposition == disposition }.isEmpty,
                "Expected catalog entries for \(disposition.rawValue)"
            )
        }

        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "mistralTranscribeModel")?.disposition,
            .blockingMetadata
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "SelectedAIModel")?.disposition,
            .derivedRuntime
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "PlatformDeviceVendorIdentifier")?.disposition,
            .deviceLocal
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "KeychainSecretStore.revision.demo.openAIAPIKey")?.disposition,
            .excludedSecret
        )
    }

    func testSourceInventoryMatchesTheReviewedCatalog() throws {
        let exactKeys = LibrarySettingsSourceInventory.allExactKeys

        XCTAssertEqual(Set(exactKeys).count, exactKeys.count)
        XCTAssertEqual(Set(exactKeys), LibrarySettingsCatalog.knownKeys)
        XCTAssertEqual(
            LibrarySettingsSourceInventory.standardDefaultsKeys,
            LibrarySettingsSourceInventory.standardDefaultsKeys.sorted()
        )
        try LibrarySettingsCatalog.validateSourceKeys(exactKeys)

        for prefix in LibrarySettingsSourceInventory.dynamicKeyPrefixes {
            XCTAssertNotNil(
                LibrarySettingsCatalog.definition(for: "\(prefix)fixture")
            )
        }
    }

    func testCloudKitSourceProjectionMatchesReviewedOmissions() throws {
        let cloudKitKeys = Set(LibrarySettingsCatalog.blockingMetadataKeys)
            .subtracting(LibrarySettingsSourceInventory.reviewedCloudKitOmissions)

        XCTAssertNoThrow(
            try LibrarySettingsSourceInventory.validateCloudKitSourceKeys(
                cloudKitKeys.sorted()
            )
        )
    }

    func testCloudKitSourceProjectionRejectsDrift() {
        let expected = Set(LibrarySettingsCatalog.blockingMetadataKeys)
            .subtracting(LibrarySettingsSourceInventory.reviewedCloudKitOmissions)
        let missingKey = expected.sorted().first!
        let unexpectedKey = "SelectedAIModel"
        let drifted = expected
            .subtracting([missingKey])
            .union([unexpectedKey])

        XCTAssertThrowsError(
            try LibrarySettingsSourceInventory.validateCloudKitSourceKeys(
                drifted.sorted()
            )
        ) { error in
            XCTAssertEqual(
                error as? LibrarySettingsCatalogError,
                .sourceInventoryDrift(
                    missing: [missingKey],
                    unexpected: [unexpectedKey]
                )
            )
        }
    }

    func testCatalogRejectsAnUnclassifiedSourceKey() {
        XCTAssertThrowsError(
            try LibrarySettingsCatalog.validateSourceKeys([
                "SelectedAIEngine",
                "futureSettingThatHasNotBeenReviewed"
            ])
        ) { error in
            XCTAssertEqual(
                error as? LibrarySettingsCatalogError,
                .unclassifiedKeys(["futureSettingThatHasNotBeenReviewed"])
            )
        }
    }

    func testCatalogRejectsNonMigratableAndMismatchedValues() throws {
        XCTAssertThrowsError(
            try LibrarySettingsCatalog.validateMigratableSnapshot(
                LibrarySettingsSnapshot(values: [
                    "openAIAPIKey": .string("secret")
                ])
            )
        ) { error in
            XCTAssertEqual(error as? LibrarySettingsCatalogError, .nonMigratableKey("openAIAPIKey"))
        }

        XCTAssertThrowsError(
            try LibrarySettingsCatalog.validateMigratableSnapshot(
                LibrarySettingsSnapshot(values: [
                    "SelectedAIEngine": .integer(7)
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? LibrarySettingsCatalogError,
                .valueKindMismatch(
                    key: "SelectedAIEngine",
                    expected: .string,
                    actual: .integer
                )
            )
        }
    }

    func testCatalogRejectsInvalidBoundaryValues() {
        let invalidValues: [(String, LibrarySettingValue)] = [
            ("summaryDetailLevel", .integer(3)),
            ("summaryThinkingLevel", .integer(-1)),
            ("summarizationTimeout", .real(601)),
            ("user_preference_time_format", .string("18h")),
            ("fluidAudioSelectedModelVersion", .string("v1")),
            ("fluidAudioSelectedLocalSpeakerLabelMethod", .string("unknown")),
            ("mistralTranscribeModel", .string("unknown-model")),
            ("openAICompatibleManualFormat", .string("json")),
            ("comedyModeStyle", .string("sarcastic")),
            ("SelectedAIEngine", .string("Unknown Engine")),
            ("selectedTranscriptionEngine", .string("Unknown Transcriber")),
            ("whisperProtocol", .string("gRPC")),
            ("ollamaPort", .integer(65_536)),
            ("mlxSwiftMaxTokens", .integer(0)),
            ("openAICompatibleTemperature", .real(.nan)),
            ("openAICompatibleBaseURL", .string("https://user:password@example.com"))
        ]

        for (key, value) in invalidValues {
            XCTAssertThrowsError(
                try LibrarySettingsCatalog.validateMigratableSnapshot(
                    LibrarySettingsSnapshot(values: [key: value])
                ),
                "Expected catalog to reject \(key)"
            ) { error in
                guard let catalogError = error as? LibrarySettingsCatalogError else {
                    return XCTFail("Unexpected error for \(key): \(error)")
                }
                guard case .invalidValue(let actualKey, _) = catalogError else {
                    return XCTFail("Unexpected catalog error for \(key): \(catalogError)")
                }
                XCTAssertEqual(actualKey, key)
            }
        }
    }

    func testCatalogAcceptsNormalizedBoundaryValues() throws {
        let snapshot = LibrarySettingsSnapshot(values: [
            "summaryDetailLevel": .integer(2),
            "summaryThinkingLevel": .integer(1),
            "summarizationTimeout": .real(600),
            "user_preference_time_format": .string("24h"),
            "fluidAudioSelectedModelVersion": .string("v3"),
            "fluidAudioSelectedLocalSpeakerLabelMethod": .string("offlineVBx"),
            "mistralTranscribeModel": .string("voxtral-mini-latest"),
            "openAICompatibleManualFormat": .string("blocks"),
            "comedyModeStyle": .string("funny"),
            "SelectedAIEngine": .string("MLX Swift"),
            "selectedTranscriptionEngine": .string("On Device"),
            "whisperProtocol": .string("REST API"),
            "ollamaPort": .integer(65_535),
            "mlxSwiftMaxTokens": .integer(1_000_000),
            "openAICompatibleTemperature": .real(1),
            "openAICompatibleBaseURL": .string("localhost:8080"),
            "mistralBaseURL": .string("")
        ])

        try LibrarySettingsCatalog.validateMigratableSnapshot(snapshot)
    }

    func testReadMigratableSettingsUsesOnlyBlockingMetadataKeys() async throws {
        let suiteName = "BisonNotesSQLiteRuntimeTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("MLX Swift", forKey: "SelectedAIEngine")
        defaults.set("do-not-copy", forKey: "openAIAPIKey")
        defaults.set(true, forKey: "fluidAudioModelDownloaded")

        let snapshot = try await LibrarySettingsCatalog.readMigratableSettings(
            from: defaults,
            sourceKeys: [
                "SelectedAIEngine",
                "openAIAPIKey",
                "fluidAudioModelDownloaded"
            ]
        )

        XCTAssertEqual(snapshot.values["SelectedAIEngine"], .string("MLX Swift"))
        XCTAssertNil(snapshot.values["openAIAPIKey"])
        XCTAssertNil(snapshot.values["fluidAudioModelDownloaded"])
    }

    func testReadMigratableSettingsRejectsUnclassifiedSourceKey() async throws {
        let suiteName = "BisonNotesSQLiteRuntimeTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create an isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("MLX Swift", forKey: "SelectedAIEngine")
        defaults.set("must block", forKey: "futureUnclassifiedSetting")

        do {
            _ = try await LibrarySettingsCatalog.readMigratableSettings(
                from: defaults,
                sourceKeys: ["SelectedAIEngine", "futureUnclassifiedSetting"]
            )
            XCTFail("Expected an unclassified source key to block settings capture")
        } catch let error as LibrarySettingsCatalogError {
            XCTAssertEqual(
                error,
                .unclassifiedKeys(["futureUnclassifiedSetting"])
            )
        }
    }
}
