import Foundation
import XCTest
@testable import BisonNotes_AI

final class LegacyLlamaMigrationTests: XCTestCase {
    private struct ModelMapping {
        let legacyModelID: String
        let ramGB: Double
        let expectedModelID: String
    }

    func testLegacyEngineIdentifiersAreRecognizedWithoutKeepingTheEngineType() {
        let legacyValues = [
            "On-Device AI",
            "On-Device LLM",
            "On Device AI (Legacy)",
            "On-Device AI Legacy"
        ]

        for value in legacyValues {
            XCTAssertTrue(
                LegacyLlamaMigration.isLegacyEngineIdentifier(value),
                "Expected legacy identifier: \(value)"
            )
        }

        XCTAssertFalse(LegacyLlamaMigration.isLegacyEngineIdentifier("MLX Swift"))
        XCTAssertFalse(LegacyLlamaMigration.isLegacyEngineIdentifier("Mistral AI"))
    }

    func testLegacyModelsMapSmallAndMediumTiers() {
        assertMappings([
            ModelMapping(legacyModelID: "lfm-2.5-1.2b", ramGB: 4.0, expectedModelID: MLXSwiftSettingsKeys.smallModelId),
            ModelMapping(legacyModelID: "gemma-3n-e2b", ramGB: 8.0, expectedModelID: MLXSwiftSettingsKeys.smallModelId),
            ModelMapping(
                legacyModelID: "ministral-3b",
                ramGB: 6.0,
                expectedModelID: MLXSwiftSettingsKeys.defaultModelId
            ),
            ModelMapping(
                legacyModelID: "phi4-mini",
                ramGB: 6.0,
                expectedModelID: MLXSwiftSettingsKeys.defaultModelId
            ),
            ModelMapping(
                legacyModelID: "qwen3-4b",
                ramGB: 8.0,
                expectedModelID: MLXSwiftSettingsKeys.defaultModelId
            ),
            ModelMapping(legacyModelID: "qwen3.5-2b", ramGB: 6.0, expectedModelID: MLXSwiftSettingsKeys.smallModelId),
            ModelMapping(legacyModelID: "qwen3.5-4b", ramGB: 8.0, expectedModelID: MLXSwiftSettingsKeys.defaultModelId),
            ModelMapping(
                legacyModelID: "granite-4.0-micro",
                ramGB: 6.0,
                expectedModelID: MLXSwiftSettingsKeys.defaultModelId
            ),
            ModelMapping(
                legacyModelID: "gemma-3n-e4b",
                ramGB: 8.0,
                expectedModelID: MLXSwiftSettingsKeys.defaultModelId
            )
        ])
        XCTAssertNil(LegacyLlamaMigration.mlxModelID(forLegacyModelID: "lfm-2.5-1.2b", ramGB: 3.9))
    }

    func testLegacyModelsMapLargeTierAndDefaults() {
        assertMappings([
            ModelMapping(
                legacyModelID: "granite-4.0-h-tiny",
                ramGB: 8.0,
                expectedModelID: MLXSwiftSettingsKeys.largeModelId
            ),
            ModelMapping(
                legacyModelID: "granite-4.0-h-tiny",
                ramGB: 6.0,
                expectedModelID: MLXSwiftSettingsKeys.defaultModelId
            )
        ])
        XCTAssertEqual(
            LegacyLlamaMigration.defaultMLXModelID(ramGB: 4.0),
            MLXSwiftSettingsKeys.smallModelId
        )
        XCTAssertEqual(
            LegacyLlamaMigration.defaultMLXModelID(ramGB: 6.0),
            MLXSwiftSettingsKeys.defaultModelId
        )
    }

    private func assertMappings(_ mappings: [ModelMapping]) {
        for mapping in mappings {
            XCTAssertEqual(
                LegacyLlamaMigration.mlxModelID(
                    forLegacyModelID: mapping.legacyModelID,
                    ramGB: mapping.ramGB
                ),
                mapping.expectedModelID
            )
        }
    }

    func testCleanupRemovesKnownModelsButPreservesUnknownFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-llama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let knownFile = directory.appendingPathComponent("LFM2.5-1.2B-Thinking-Q4_K_M.gguf")
        let doubleExtensionFile = directory.appendingPathComponent("Ministral-3-3B-Instruct-2512-Q4_K_M.gguf.gguf")
        let unknownFile = directory.appendingPathComponent("user-created-model.gguf")
        let hiddenFile = directory.appendingPathComponent(".user-created-model")
        XCTAssertTrue(FileManager.default.createFile(atPath: knownFile.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: doubleExtensionFile.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: unknownFile.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: hiddenFile.path, contents: Data()))

        let removed = LegacyLlamaMigration.removeDownloadedModels(from: directory)

        XCTAssertEqual(
            removed,
            [
                "LFM2.5-1.2B-Thinking-Q4_K_M.gguf",
                "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf.gguf"
            ]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: knownFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: doubleExtensionFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknownFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenFile.path))
    }

    func testLegacySettingsAreCleared() {
        let suiteName = "LegacyLlamaMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "enableOnDeviceLLM")
        defaults.set("gemma-3n-e4b", forKey: LegacyLlamaMigration.legacySelectedModelKey)
        defaults.set(true, forKey: "onDeviceLLMEnableExperimentalModels")
        defaults.set(true, forKey: "onDeviceLLMNameMigration_v1.5")
        defaults.set(true, forKey: "migrated_unavailable_gemma-3n-e4b")

        let removed = LegacyLlamaMigration.clearLegacySettings(from: defaults)

        XCTAssertEqual(removed.count, 5)
        XCTAssertNil(defaults.object(forKey: "enableOnDeviceLLM"))
        XCTAssertNil(defaults.object(forKey: LegacyLlamaMigration.legacySelectedModelKey))
        XCTAssertNil(defaults.object(forKey: "onDeviceLLMEnableExperimentalModels"))
        XCTAssertNil(defaults.object(forKey: "onDeviceLLMNameMigration_v1.5"))
        XCTAssertNil(defaults.object(forKey: "migrated_unavailable_gemma-3n-e4b"))
    }
}
