//
//  MLXSwiftResponseCleanerTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class MLXSwiftResponseCleanerTests: XCTestCase {
    func testRemovesClosedThinkingBlock() {
        let response = """
        <think>
        I should inspect every constraint before answering.
        </think>

        ## Summary
        Final meeting summary.
        """

        XCTAssertEqual(
            MLXSwiftResponseCleaner.stripThinking(from: response),
            "## Summary\nFinal meeting summary."
        )
    }

    func testDropsUnterminatedThinkingBlock() {
        let response = """
        <think>
        The model reached its output limit while reasoning.
        """

        XCTAssertEqual(MLXSwiftResponseCleaner.stripThinking(from: response), "")
    }

    func testRemovesProseThinkingPreambleBeforeSummary() {
        let response = """
        Here's a thinking process:

        1. Analyze User Input
        2. Apply the constraints

        ## Summary
        ### Overview
        Final meeting summary.
        """

        XCTAssertEqual(
            MLXSwiftResponseCleaner.stripThinking(from: response),
            "## Summary\n### Overview\nFinal meeting summary."
        )
    }

    func testRemovesProseThinkingPreambleBeforeFinalAnswerMarker() {
        let response = """
        Reasoning process:
        Check the transcript and organize the result.

        Final answer:
        The final summary begins here.
        """

        XCTAssertEqual(
            MLXSwiftResponseCleaner.stripThinking(from: response),
            "The final summary begins here."
        )
    }

    func testPreservesOrdinarySummaryText() {
        let response = """
        ## Summary
        The team discussed its decision-making process.
        """

        XCTAssertEqual(
            MLXSwiftResponseCleaner.stripThinking(from: response),
            response
        )
    }

    func testThinkingResponseStillExtractsEveryStructuredSection() {
        let response = """
        <think>
        Check the transcript carefully for tasks, dates, and possible titles.
        </think>

        ## Summary
        ### Overview
        The team reviewed alumni account management.

        ## Tasks
        - Remove archived Google Photos data
        - Update the alumni affiliation

        ## Reminders
        - Complete the license review by August 1

        ## Suggested Titles
        - Alumni Account Management Review
        - Workspace Archiving and Licensing
        """

        let result = MLXSwiftResponseParser.parseMarkdown(
            response,
            fallbackText: "The team reviewed alumni account management."
        )

        XCTAssertFalse(result.summary.contains("Check the transcript"))
        XCTAssertTrue(result.summary.contains("alumni account management"))
        XCTAssertEqual(result.tasks.map(\.text), [
            "Remove archived Google Photos data",
            "Update the alumni affiliation"
        ])
        XCTAssertEqual(result.reminders.map(\.text), [
            "Complete the license review by August 1"
        ])
        XCTAssertEqual(result.titles.map(\.text), [
            "Alumni Account Management Review",
            "Workspace Archiving and Licensing"
        ])
    }
}
