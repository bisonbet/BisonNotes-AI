//
//  BisonNotesAITests.swift
//  BisonNotes AITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest
@testable import BisonNotes_AI

@MainActor
private final class CountingSummarizationEngine: SummarizationEngine {
    let name = "Counting Test Engine"
    let description = "A test engine that records complete-processing calls."
    let version = "test"
    let isAvailable = true
    private(set) var processCompleteCallCount = 0
    private(set) var individualCallCount = 0

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        individualCallCount += 1
        return "individual summary"
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        individualCallCount += 1
        return []
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        individualCallCount += 1
        return []
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        individualCallCount += 1
        return []
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        individualCallCount += 1
        return .general
    }

    func processComplete(text: String) async throws -> SummarizationResult {
        processCompleteCallCount += 1
        return SummarizationResult(
            summary: "combined summary",
            tasks: [TaskItem(text: "Combined task")],
            reminders: [],
            titles: [],
            contentType: .meeting
        )
    }
}

@MainActor
final class BisonNotesAITests: XCTestCase {
    func testProcessingStatusSemanticFlags() {
        XCTAssertTrue(ProcessingStatus.queued.isActive)
        XCTAssertTrue(ProcessingStatus.processing.isActive)
        XCTAssertTrue(ProcessingStatus.completed.isComplete)
        XCTAssertTrue(ProcessingStatus.failed.hasError)
        XCTAssertTrue(ProcessingStatus.cancelled.hasError)
        XCTAssertTrue(ProcessingStatus.interrupted.isResumable)
        XCTAssertFalse(ProcessingStatus.notStarted.isActive)
    }

    func testChunkingConfigKeepsParakeetAtProvenDurationLimit() {
        let config = ChunkingConfig.config(for: .fluidAudio)
        guard case .duration(let maxSeconds) = config.strategy else {
            return XCTFail("Parakeet should use duration-based chunking")
        }

        XCTAssertEqual(maxSeconds, 10 * 60)
    }

    func testBackgroundSummarizationRouteRecognizesOllamaAliases() {
        XCTAssertEqual(BackgroundSummarizationRoute(engineName: "Ollama"), .ollama)
        XCTAssertEqual(BackgroundSummarizationRoute(engineName: "Local LLM (Ollama)"), .ollama)
        XCTAssertEqual(BackgroundSummarizationRoute(engineName: "local"), .ollama)
        XCTAssertEqual(BackgroundSummarizationRoute(engineName: "MLX Swift"), .selectedEngine)
    }

    func testFileRelationshipsReadsLegacyCloudFlagAsEligibility() throws {
        let id = UUID()
        let legacyJSON = """
        {
          "id": "\(id.uuidString)",
          "recordingURL": "file:///tmp/recording.m4a",
          "recordingName": "Recording",
          "recordingDate": 0,
          "transcriptExists": true,
          "summaryExists": true,
          "iCloudSynced": true,
          "lastUpdated": 0
        }
        """

        let relationships = try JSONDecoder().decode(
            FileRelationships.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertEqual(relationships.id, id)
        XCTAssertTrue(relationships.iCloudSyncEligible)
    }

    func testCombinedTaskAndReminderExtractionUsesOneCompleteRequest() async throws {
        let engine = CountingSummarizationEngine()

        let result = try await extractTasksAndRemindersFromCompleteResult(
            using: engine,
            text: "Discuss the launch meeting and assign the follow-up."
        )

        XCTAssertEqual(engine.processCompleteCallCount, 1)
        XCTAssertEqual(engine.individualCallCount, 0)
        XCTAssertEqual(result.tasks.map(\.text), ["Combined task"])
        XCTAssertTrue(result.reminders.isEmpty)
    }

    func testBothComedyModesPersistAndScopeHumorToSummaryNarrative() {
        let defaults = UserDefaults.standard
        let enabledKey = ComedyMode.SettingsKeys.enabled
        let styleKey = ComedyMode.SettingsKeys.style
        let detailKey = SummaryDetailLevel.storageKey
        let originalEnabled = defaults.object(forKey: enabledKey)
        let originalStyle = defaults.object(forKey: styleKey)
        let originalDetail = defaults.object(forKey: detailKey)

        defer {
            if let originalEnabled {
                defaults.set(originalEnabled, forKey: enabledKey)
            } else {
                defaults.removeObject(forKey: enabledKey)
            }

            if let originalStyle {
                defaults.set(originalStyle, forKey: styleKey)
            } else {
                defaults.removeObject(forKey: styleKey)
            }

            if let originalDetail {
                defaults.set(originalDetail, forKey: detailKey)
            } else {
                defaults.removeObject(forKey: detailKey)
            }
        }

        defaults.set(SummaryDetailLevel.detailed.rawValue, forKey: detailKey)

        for mode in [ComedyMode.snarky, .funny] {
            defaults.set(true, forKey: enabledKey)
            defaults.set(mode.rawValue, forKey: styleKey)

            XCTAssertEqual(ComedyMode.current.rawValue, mode.rawValue)

            let summaryPrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .summary,
                contentType: .general
            )
            XCTAssertTrue(summaryPrompt.contains("summary voice only"))
            XCTAssertTrue(summaryPrompt.contains("Comedy is required in the summary"))
            XCTAssertTrue(summaryPrompt.contains("Do not return a neutral, clinical, or purely professional summary"))

            if mode == .snarky {
                XCTAssertTrue(summaryPrompt.contains("Roast-Level Snark Mode"))
                XCTAssertTrue(summaryPrompt.contains("high-energy observational roast"))
            }

            let summaryUserPrompt = ChatCompletionPromptGenerator.createUserPrompt(
                for: .summary,
                text: "A transcript about a scheduling problem."
            )
            XCTAssertTrue(summaryUserPrompt.contains("FINAL SUMMARY STYLE REQUIREMENT"))
            XCTAssertTrue(summaryUserPrompt.contains("not neutral, clinical,"))
            XCTAssertTrue(summaryUserPrompt.contains("or purely professional"))
            XCTAssertTrue(summaryUserPrompt.contains("Summary Detail: Detailed"))

            if mode == .snarky {
                XCTAssertTrue(summaryUserPrompt.contains("ROAST-LEVEL SNARK"))
                XCTAssertTrue(summaryUserPrompt.contains("One mild joke is insufficient"))
            }

            let completePrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .complete,
                contentType: .general
            )
            XCTAssertTrue(completePrompt.contains("COMEDY REQUIRED"))
            XCTAssertTrue(completePrompt.contains("summary field only"))
            XCTAssertTrue(completePrompt.contains("recognizably comedic"))
            XCTAssertTrue(completePrompt.contains("at least one clearly witty aside"))
            XCTAssertTrue(completePrompt.contains("Treat `tasks`, `reminders`, `titles`"))
            XCTAssertTrue(completePrompt.contains("exact requested output format"))

            if mode == .snarky {
                XCTAssertTrue(completePrompt.contains("roast-level, high-energy snark"))
                XCTAssertTrue(completePrompt.contains("recurring sarcastic beats"))
            }

            let completeUserPrompt = ChatCompletionPromptGenerator.createUserPrompt(
                for: .complete,
                text: "A transcript about a scheduling problem."
            )
            XCTAssertTrue(completeUserPrompt.contains("FINAL SUMMARY STYLE REQUIREMENT"))
            XCTAssertTrue(completeUserPrompt.contains("summary` value MUST be"))
            XCTAssertTrue(completeUserPrompt.contains("Summary Detail: Detailed"))

            if mode == .snarky {
                XCTAssertTrue(completeUserPrompt.contains("ROAST-LEVEL SNARK"))
                XCTAssertTrue(completeUserPrompt.contains("recurring punchlines"))
            }

            let tasksPrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .tasks,
                contentType: .general
            )
            XCTAssertFalse(tasksPrompt.contains("Comedy Mode"))
        }
    }

    func testCompleteParserRejectsUnstructuredResponseThatWouldLoseMetadata() {
        let unstructuredResponse = """
        ## Summary

        A summary without the required task, reminder, and title fields.
        """

        XCTAssertThrowsError(
            try ChatCompletionResponseParser.parseCompleteResponseFromJSON(unstructuredResponse)
        )
    }

    func testCompleteParserRepairsInvalidEscapeWithoutFabricatingMetadata() throws {
        let malformedEscapeResponse = #"""
        {
          "summary": "## Insights\n\nA significant\A portion used \"protective\" language.",
          "tasks": [
            {
              "text": "Call genetics specialist",
              "priority": "medium",
              "category": "health",
              "timeReference": null,
              "confidence": 0.9
            }
          ],
          "reminders": [
            {
              "text": "Meeting with genetics specialist",
              "urgency": "later",
              "timeReference": null,
              "confidence": 0.9
            }
          ],
          "titles": [
            {
              "text": "Mental Health Medication Updates",
              "category": "personal",
              "confidence": 0.9
            }
          ]
        }
        """#

        let parsed = try ChatCompletionResponseParser.parseCompleteResponseFromJSON(
            malformedEscapeResponse
        )

        XCTAssertTrue(parsed.summary.contains("A significantA portion"))
        XCTAssertTrue(parsed.summary.contains("\"protective\""))
        XCTAssertTrue(parsed.summary.contains("\n\n"))
        XCTAssertFalse(parsed.summary.contains("\\A"))
        XCTAssertEqual(parsed.tasks.map(\.text), ["Call genetics specialist"])
        XCTAssertEqual(parsed.reminders.map(\.text), ["Meeting with genetics specialist"])
        XCTAssertEqual(parsed.titles.map(\.text), ["Mental Health Medication Updates"])
    }

    func testCompleteParserRejectsMalformedStructuredResponseInsteadOfExtractingMetadata() {
        let malformedStructureResponse = #"""
        {
          "summary": "## Summary\n\nA summary with the right top-level keys.",
          "tasks": ["This is not a task object"],
          "reminders": [],
          "titles": []
        }
        """#

        XCTAssertThrowsError(
            try ChatCompletionResponseParser.parseCompleteResponseFromJSON(malformedStructureResponse)
        )
    }

    func testModelTextNormalizationRemovesNestedEscapesAndInvalidMarkers() {
        let encodedText = #"A\nB\"C\A"#

        XCTAssertEqual(
            ChatCompletionResponseParser.normalizeModelText(encodedText),
            "A\nB\"CA"
        )
    }

    func testTitleAndRecordingNameCleaningRemoveMarkdownArtifactsAndTrailingPunctuation() throws {
        XCTAssertEqual(
            RecordingNameGenerator.cleanStandardizedTitleResponse("Visit Ed **Intercourse,"),
            "Visit Ed Intercourse"
        )
        XCTAssertEqual(
            RecordingNameGenerator.validateAndFixRecordingName(
                "Visit Ed **Intercourse,",
                originalName: "Recording"
            ),
            "Visit Ed Intercourse"
        )

        let json = """
        {
          "summary": "## Summary\\n\\nFacts from the transcript.",
          "tasks": [],
          "reminders": [
            {
              "text": "Call the clinic tomorrow",
              "urgency": "today",
              "timeReference": "tomorrow",
              "confidence": 0.9
            }
          ],
          "titles": [
            {
              "text": "**Project Budget Review,",
              "category": "general",
              "confidence": 0.9
            }
          ]
        }
        """

        let parsed = try ChatCompletionResponseParser.parseCompleteResponseFromJSON(json)
        XCTAssertTrue(parsed.tasks.isEmpty)
        XCTAssertEqual(parsed.reminders.count, 1)
        XCTAssertEqual(parsed.titles.first?.text, "Project Budget Review")
    }
}
