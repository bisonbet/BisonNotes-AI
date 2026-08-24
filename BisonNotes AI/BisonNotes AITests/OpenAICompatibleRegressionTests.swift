//
//  OpenAICompatibleRegressionTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

@MainActor
final class OpenAICompatibleRegressionTests: XCTestCase {
    func testNormalizesBaseURLForAllCompatibleAPIPaths() {
        XCTAssertEqual(
            OpenAICompatibleService.normalizedBaseURL(" https://api.example.com/v1/// "),
            "https://api.example.com/v1"
        )
        XCTAssertEqual(OpenAICompatibleService.normalizedBaseURL(""), "")
    }

    func testRecognizesGPT5AndLegacyReasoningModelIdentifiers() {
        XCTAssertTrue(OpenAICompatibleService.isReasoningModel("gpt-5-mini"))
        XCTAssertTrue(OpenAICompatibleService.isReasoningModel("gpt5-nano"))
        XCTAssertTrue(OpenAICompatibleService.isReasoningModel("o4-mini"))
        XCTAssertTrue(OpenAICompatibleService.isReasoningModel("provider-reasoning-model"))
        XCTAssertFalse(OpenAICompatibleService.isReasoningModel("gpt-4.1-mini"))
    }

    func testCompatibleEngineUsesPersistedEngineIdentifier() {
        let engine = OpenAICompatibleEngine()

        XCTAssertEqual(engine.name, "Compatible API")
        XCTAssertEqual(engine.engineType, AIEngineType.openAICompatible.rawValue)
    }

    // MARK: - Double-Encoded Text

    func testDoubleEncodedMarkdownIsStillUnescaped() {
        // One flat run with its line breaks spelled \n — the gateway bug this
        // normalisation exists for.
        let flat = "## Overview\\nFirst point\\nSecond point"
        XCTAssertEqual(
            ChatCompletionResponseParser.normalizeModelText(flat),
            "## Overview\nFirst point\nSecond point"
        )
    }

    func testLiteralBackslashesSurviveInAlreadyDecodedText() {
        // JSONDecoder has already run, so these backslashes are the model's own.
        // Unescaping again turned the path into a newline and the regex into a tab.
        let decoded = "Move the export to C:\\new_folder\nThen split on \\t between columns"
        XCTAssertEqual(ChatCompletionResponseParser.normalizeModelText(decoded), decoded)
    }

    func testOrdinaryProseIsLeftExactlyAsItArrived() {
        let prose = "Tim will follow up with AWS.\nJason is testing the NVMe drives."
        XCTAssertEqual(ChatCompletionResponseParser.normalizeModelText(prose), prose)
    }

}
