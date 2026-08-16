//
//  BisonNotesAITests.swift
//  BisonNotes AITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest
@testable import BisonNotes_AI

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

    func testMissingOnDeviceModelThrowsRecoverableError() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-model-\(UUID().uuidString).gguf")

        XCTAssertThrowsError(try OnDeviceLLM(from: missingPath.path)) { error in
            guard let llmError = error as? OnDeviceLLMError,
                  case .configurationError = llmError else {
                return XCTFail("Expected a recoverable model configuration error, got \(error)")
            }
        }
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
        let originalEnabled = defaults.object(forKey: enabledKey)
        let originalStyle = defaults.object(forKey: styleKey)

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
        }

        for mode in [ComedyMode.snarky, .funny] {
            defaults.set(true, forKey: enabledKey)
            defaults.set(mode.rawValue, forKey: styleKey)

            XCTAssertEqual(ComedyMode.current.rawValue, mode.rawValue)

            let summaryPrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .summary,
                contentType: .general
            )
            XCTAssertTrue(summaryPrompt.contains("summary narrative only"))

            let completePrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .complete,
                contentType: .general
            )
            XCTAssertTrue(completePrompt.contains("COMEDY SCOPE"))
            XCTAssertTrue(completePrompt.contains("summary field only"))
            XCTAssertTrue(completePrompt.contains("Treat `tasks`, `reminders`, `titles`"))
            XCTAssertTrue(completePrompt.contains("exact requested output format"))

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
