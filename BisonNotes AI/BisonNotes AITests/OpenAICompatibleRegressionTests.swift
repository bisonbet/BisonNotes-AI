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

    func testEmptyCompatibleBaseURLUsesSafeStringFormatWithoutConfiguration() {
        XCTAssertEqual(MessageFormatDetector.detectFormat(for: " \n\t "), .string)
        XCTAssertEqual(MessageFormatDetector.detectFormatWithoutOverride(for: " \n\t "), .string)
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

    // MARK: - Unescaped inner quotes

    private func decodedSummary(fromRepairing json: String) throws -> String? {
        let repaired = try XCTUnwrap(
            ChatCompletionResponseParser.repairMalformedJSON(in: json),
            "The payload needed repair"
        )
        let object = try JSONSerialization.jsonObject(
            with: Data(repaired.utf8)
        ) as? [String: Any]
        return object?["summary"] as? String
    }

    /// A quoted phrase followed by a comma reads exactly like the separator
    /// before the next member. Closing the string there left the repair outside
    /// it, misread every quote after it, and lost the whole summary to a decode
    /// failure.
    func testAQuotedPhraseFollowedByACommaStaysInsideTheString() throws {
        let summary = try decodedSummary(
            fromRepairing: "{\"summary\":\"Use \"foo\", then continue\"}"
        )
        XCTAssertEqual(summary, "Use \"foo\", then continue")
    }

    /// The other half: a comma that really does separate members still closes
    /// the string.
    func testACommaBeforeTheNextKeyStillClosesTheString() throws {
        let json = "{\"summary\":\"He said \"hi\" loudly\",\"model\":\"local\"}"
        let repaired = try XCTUnwrap(ChatCompletionResponseParser.repairMalformedJSON(in: json))
        let object = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
        XCTAssertEqual(object?["summary"] as? String, "He said \"hi\" loudly")
        XCTAssertEqual(object?["model"] as? String, "local")
    }

    /// Non-string elements after a comma are values too, so an array that mixes
    /// them keeps parsing the way it always did.
    func testAMixedArrayIsUnaffected() throws {
        let json = "{\"summary\":\"A \"quoted\" word\",\"items\":[\"a\", 2, true, null]}"
        let repaired = try XCTUnwrap(ChatCompletionResponseParser.repairMalformedJSON(in: json))
        let object = try JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any]
        XCTAssertEqual(object?["summary"] as? String, "A \"quoted\" word")
        XCTAssertEqual((object?["items"] as? [Any])?.count, 4)
    }

    /// `true` is a literal; `then` merely starts with the same letter.
    func testALiteralIsMatchedAsAWholeTokenNotAPrefix() {
        let characters = Array("true, x")
        XCTAssertTrue(ChatCompletionResponseParser.matchesWholeToken("true", at: 0, in: characters))
        XCTAssertFalse(
            ChatCompletionResponseParser.matchesWholeToken("true", at: 0, in: Array("truely yours"))
        )
    }

}
