import XCTest
@testable import BisonNotes_AI

/// Pins every Ollama summary prompt, tool and schema for the Default preset to
/// its v3.0 text (`OllamaDefaultPromptFixtures`). The Summary Prompt beta gates
/// dozens of phrases in these builders; a dropped space or a misplaced gate
/// would change Default output silently without this.
@MainActor
final class OllamaDefaultPromptGoldenTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var savedValues: [String: Any] = [:]

    /// Every setting the Default output depends on.
    private var keys: [String] {
        BetaFeatures.allStorageKeys + [
            SummaryDetailLevel.storageKey,
            ComedyMode.SettingsKeys.enabled,
            ComedyMode.SettingsKeys.style,
            SummaryPromptLibrary.storageKey,
            SummaryPromptLibrary.defaultPromptIDKey,
        ]
    }

    override func setUp() async throws {
        try await super.setUp()
        for key in keys {
            if let value = defaults.object(forKey: key) {
                savedValues[key] = value
            }
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = savedValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await super.tearDown()
    }

    private let text = OllamaDefaultPromptFixtures.transcript

    func testPromptsMatchV30() {
        let service = OllamaService()
        let cases: [(String, String, String)] = [
            ("robust summary", service.createRobustSummaryPrompt(from: text), OllamaDefaultPromptFixtures.robustSummary),
            ("robust complete", service.createRobustCompleteProcessingPrompt(from: text), OllamaDefaultPromptFixtures.robustComplete),
            ("structured complete", service.createStructuredCompleteProcessingPrompt(from: text), OllamaDefaultPromptFixtures.structuredComplete),
            ("Qwen summary", service.createQwenToolPrompt(for: "summary", text: text), OllamaDefaultPromptFixtures.qwenSummary),
            ("Qwen complete", service.createQwenToolPrompt(for: "complete", text: text), OllamaDefaultPromptFixtures.qwenComplete),
            ("GPT-OSS summary", service.createGPTOSSToolPrompt(for: "summary", text: text), OllamaDefaultPromptFixtures.gptossSummary),
            ("GPT-OSS complete", service.createGPTOSSToolPrompt(for: "complete", text: text), OllamaDefaultPromptFixtures.gptossComplete),
            ("Magistral summary", service.createMagistralToolPrompt(for: "summary", text: text), OllamaDefaultPromptFixtures.magistralSummary),
            ("Magistral complete", service.createMagistralToolPrompt(for: "complete", text: text), OllamaDefaultPromptFixtures.magistralComplete),
        ]
        for (name, actual, expected) in cases {
            XCTAssertEqual(actual, expected, "\(name) prompt drifted from v3.0")
        }
    }

    func testBetaOnWithDefaultSelectedStillMatchesV30() {
        defaults.set(true, forKey: BetaFeatures.masterStorageKey)
        defaults.set(true, forKey: BetaFeature.customSummaryPrompt.storageKey)
        SummaryPromptLibrary.setDefaultPrompt(id: SummaryPrompt.defaultID)
        testPromptsMatchV30()
        testToolsAndSchemaMatchV30()
    }

    /// JSON is compared structurally: key order and spacing differ by platform.
    func testToolsAndSchemaMatchV30() {
        let service = OllamaService()
        let encoder = JSONEncoder()
        let cases: [(String, Any, String)] = [
            ("summary tool", jsonObject(try? encoder.encode(service.createSummaryTool(SummaryPromptComposer.current))), OllamaDefaultPromptFixtures.summaryTool),
            ("complete tool", jsonObject(try? encoder.encode(service.createCompleteAnalysisTool(SummaryPromptComposer.current))), OllamaDefaultPromptFixtures.completeTool),
            ("schema", OllamaJSONSchemas.completeAnalysisSchema, OllamaDefaultPromptFixtures.schema),
        ]
        for (name, actual, expected) in cases {
            let expectedObject = jsonObject(Data(expected.utf8))
            XCTAssertEqual(actual as? NSDictionary, expectedObject as? NSDictionary, "\(name) drifted from v3.0")
        }
    }

    func testCustomPromptDropsTheSummaryLengthFloor() throws {
        defaults.set(true, forKey: BetaFeatures.masterStorageKey)
        defaults.set(true, forKey: BetaFeature.customSummaryPrompt.storageKey)
        let custom = try XCTUnwrap(SummaryPromptLibrary.addCustom())
        SummaryPromptLibrary.setDefaultPrompt(id: custom.id)

        let summary = try XCTUnwrap((OllamaJSONSchemas.completeAnalysisSchema["properties"] as? [String: Any])?["summary"] as? [String: Any])
        XCTAssertNil(summary["minLength"], "A custom prompt sets the summary's length")
        let prompt = OllamaService().createRobustSummaryPrompt(from: text)
        XCTAssertFalse(prompt.contains("detail level"))
        XCTAssertFalse(prompt.contains("SUMMARY DETAIL REQUIREMENT"))
    }

    private func jsonObject(_ data: Data?) -> Any? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
}
