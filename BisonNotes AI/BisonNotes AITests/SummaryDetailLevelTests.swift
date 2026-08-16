import XCTest
@testable import BisonNotes_AI

final class SummaryDetailLevelTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var originalValue: Any?

    override func setUp() {
        super.setUp()
        originalValue = defaults.object(forKey: SummaryDetailLevel.storageKey)
    }

    override func tearDown() {
        if let originalValue {
            defaults.set(originalValue, forKey: SummaryDetailLevel.storageKey)
        } else {
            defaults.removeObject(forKey: SummaryDetailLevel.storageKey)
        }
        super.tearDown()
    }

    func testLevelsUseUserFacingLabelsAndDescriptions() {
        XCTAssertEqual(SummaryDetailLevel.concise.displayName, "Brief")
        XCTAssertEqual(SummaryDetailLevel.balanced.displayName, "Balanced")
        XCTAssertEqual(SummaryDetailLevel.detailed.displayName, "Detailed")

        for level in SummaryDetailLevel.allCases {
            XCTAssertFalse(level.userDescription.isEmpty)
            XCTAssertTrue(level.schemaDescription.contains(level.displayName))
        }
    }

    func testCurrentReadsPersistedLevelAndDefaultsToBalanced() {
        defaults.removeObject(forKey: SummaryDetailLevel.storageKey)
        XCTAssertEqual(SummaryDetailLevel.current, .balanced)

        defaults.set(SummaryDetailLevel.detailed.rawValue, forKey: SummaryDetailLevel.storageKey)
        XCTAssertEqual(SummaryDetailLevel.current, .detailed)

        defaults.set(99, forKey: SummaryDetailLevel.storageKey)
        XCTAssertEqual(SummaryDetailLevel.current, .balanced)
    }

    func testTargetRangesAndFallbackSentenceLimitsIncreaseWithDetail() {
        let sourceWordCount = 1_000

        XCTAssertEqual(SummaryDetailLevel.concise.targetWordRange(for: sourceWordCount), 50...100)
        XCTAssertEqual(SummaryDetailLevel.balanced.targetWordRange(for: sourceWordCount), 100...150)
        XCTAssertEqual(SummaryDetailLevel.detailed.targetWordRange(for: sourceWordCount), 150...250)

        XCTAssertEqual(SummaryDetailLevel.concise.basicSentenceLimit, 2)
        XCTAssertEqual(SummaryDetailLevel.balanced.basicSentenceLimit, 4)
        XCTAssertEqual(SummaryDetailLevel.detailed.basicSentenceLimit, 7)
    }

    func testPromptInstructionsExplainSelectedLevelAndKeepMetadataFactual() {
        let sourceWordCount = 1_000

        for level in SummaryDetailLevel.allCases {
            let instructions = level.promptInstructions(forSourceWordCount: sourceWordCount)

            XCTAssertTrue(instructions.contains("Summary Detail: \(level.displayName)"))
            XCTAssertTrue(instructions.contains("tasks, reminders, titles, and content type"))
            let targetRange = level.targetWordRange(for: sourceWordCount)
            XCTAssertTrue(instructions.contains("\(targetRange.lowerBound)-\(targetRange.upperBound)"))
        }
    }

    func testSharedChatCompletionPromptsUseSelectedDetailLevel() {
        let sourceText = Array(repeating: "transcript", count: 1_000).joined(separator: " ")

        for level in SummaryDetailLevel.allCases {
            defaults.set(level.rawValue, forKey: SummaryDetailLevel.storageKey)

            let summarySystemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .summary,
                contentType: .general
            )
            let completeSystemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(
                for: .complete,
                contentType: .general
            )
            let summaryUserPrompt = ChatCompletionPromptGenerator.createUserPrompt(
                for: .summary,
                text: sourceText
            )

            XCTAssertTrue(summarySystemPrompt.contains("Summary Detail: \(level.displayName)"))
            XCTAssertTrue(completeSystemPrompt.contains("Summary Detail: \(level.displayName)"))
            XCTAssertTrue(summaryUserPrompt.contains("Summary Detail: \(level.displayName)"))
        }
    }
}
