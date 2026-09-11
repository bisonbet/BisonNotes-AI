import XCTest
@testable import BisonNotesSQLiteRuntime

final class SQLiteLibrarySettingsNormalizationRuntimeTests: XCTestCase {
    func testNormalizerCanonicalizesLegacyIdentifiersAndEndpoints() throws {
        let snapshot = LibrarySettingsSnapshot(values: [
            "SelectedAIEngine": .string(" OpenAI "),
            "selectedTranscriptionEngine": .string("On Device (WhisperKit)"),
            "openAICompatibleBaseURL": .string(" https://example.com/v1/// ")
        ])
        let context = LibrarySettingsNormalizationContext(
            targetPlatform: .macOS,
            supportsMLX: true,
            supportedMLXModelIDs: ["small-model"],
            preferredMLXModelID: "small-model"
        )

        let result = try LibrarySettingsNormalizer.normalize(snapshot, for: context)

        XCTAssertEqual(
            result.snapshot.values,
            [
                "SelectedAIEngine": .string("OpenAI API Compatible"),
                "selectedTranscriptionEngine": .string("On Device"),
                "openAICompatibleBaseURL": .string("https://example.com/v1")
            ]
        )
        XCTAssertEqual(
            result.changedKeys,
            ["SelectedAIEngine", "openAICompatibleBaseURL", "selectedTranscriptionEngine"]
        )
        XCTAssertTrue(result.omittedKeys.isEmpty)
    }

    func testNormalizerOmitsOllamaAndClampsModelForIOS() throws {
        let snapshot = LibrarySettingsSnapshot(values: [
            "SelectedAIEngine": .string("Ollama"),
            "enableOllama": .bool(true),
            "ollamaServerURL": .string("http://localhost:11434/"),
            "ollamaPort": .integer(11_434),
            "ollamaModelName": .string("llama3"),
            "ollamaMaxTokens": .integer(2_048),
            "ollamaTemperature": .real(0.7),
            "ollamaContextTokens": .integer(4_096),
            "mlxSwiftModelId": .string("mac-only-model"),
            "mistralBaseURL": .string(" https://api.mistral.ai/// ")
        ])
        let context = LibrarySettingsNormalizationContext(
            targetPlatform: .iOS,
            supportsMLX: true,
            supportedMLXModelIDs: ["small-model", "default-model"],
            preferredMLXModelID: "small-model"
        )

        let result = try LibrarySettingsNormalizer.normalize(snapshot, for: context)

        XCTAssertEqual(result.snapshot.values["SelectedAIEngine"], .string("None"))
        XCTAssertEqual(result.snapshot.values["mlxSwiftModelId"], .string("small-model"))
        XCTAssertEqual(
            result.snapshot.values["mistralBaseURL"],
            .string("https://api.mistral.ai")
        )
        XCTAssertTrue(
            result.omittedKeys.contains(
                "ollamaServerURL"
            )
        )
        XCTAssertEqual(
            Set(result.omittedKeys),
            [
                "enableOllama",
                "ollamaContextTokens",
                "ollamaMaxTokens",
                "ollamaModelName",
                "ollamaPort",
                "ollamaServerURL",
                "ollamaTemperature"
            ]
        )
    }

    func testNormalizerDisablesUnsupportedMLXStateWithoutInventingFallbackConfiguration() throws {
        let snapshot = LibrarySettingsSnapshot(values: [
            "SelectedAIEngine": .string("MLX Swift"),
            "mlxSwiftExperimentalEnabled": .bool(true),
            "mlxSwiftModelId": .string("large-model")
        ])
        let context = LibrarySettingsNormalizationContext(
            targetPlatform: .iOS,
            supportsMLX: false
        )

        let result = try LibrarySettingsNormalizer.normalize(snapshot, for: context)

        XCTAssertEqual(result.snapshot.values["SelectedAIEngine"], .string("None"))
        XCTAssertEqual(
            result.snapshot.values["mlxSwiftExperimentalEnabled"],
            .bool(false)
        )
        XCTAssertNil(result.snapshot.values["mlxSwiftModelId"])
        XCTAssertEqual(result.omittedKeys, ["mlxSwiftModelId"])
    }

    func testNormalizerRejectsInvalidFallbackAndPreferredModelContext() {
        XCTAssertThrowsError(
            try LibrarySettingsNormalizer.normalize(
                LibrarySettingsSnapshot(values: [:]),
                for: LibrarySettingsNormalizationContext(
                    targetPlatform: .macOS,
                    supportsMLX: true,
                    fallbackAIEngine: "Unknown"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LibrarySettingsNormalizationError,
                .invalidFallbackAIEngine("Unknown")
            )
        }

        XCTAssertThrowsError(
            try LibrarySettingsNormalizer.normalize(
                LibrarySettingsSnapshot(values: [:]),
                for: LibrarySettingsNormalizationContext(
                    targetPlatform: .iOS,
                    supportsMLX: true,
                    supportedMLXModelIDs: ["small-model"],
                    preferredMLXModelID: "large-model"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? LibrarySettingsNormalizationError,
                .invalidPreferredMLXModelID("large-model")
            )
        }
    }
}
