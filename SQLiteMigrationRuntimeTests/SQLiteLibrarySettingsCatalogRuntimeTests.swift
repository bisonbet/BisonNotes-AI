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
            .derivedRuntime
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "SelectedAIModel")?.disposition,
            .derivedRuntime
        )
        XCTAssertEqual(
            LibrarySettingsCatalog.definition(for: "KeychainSecretStore.revision.demo.openAIAPIKey")?.disposition,
            .excludedSecret
        )
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

        let snapshot = try await LibrarySettingsCatalog.readMigratableSettings(from: defaults)

        XCTAssertEqual(snapshot.values["SelectedAIEngine"], .string("MLX Swift"))
        XCTAssertNil(snapshot.values["openAIAPIKey"])
        XCTAssertNil(snapshot.values["fluidAudioModelDownloaded"])
    }
}
