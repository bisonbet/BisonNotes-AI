//
//  OpenAICompatibleRegressionTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

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
}
