import XCTest
@testable import BisonNotes_AI

final class SummaryThinkingTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var originalThinkingValue: Any?

    override func setUp() {
        super.setUp()
        originalThinkingValue = defaults.object(forKey: SummaryThinkingLevel.storageKey)
        defaults.removeObject(forKey: SummaryThinkingLevel.storageKey)
    }

    override func tearDown() {
        if let originalThinkingValue {
            defaults.set(originalThinkingValue, forKey: SummaryThinkingLevel.storageKey)
        } else {
            defaults.removeObject(forKey: SummaryThinkingLevel.storageKey)
        }
        super.tearDown()
    }

    func testThinkingPreferenceDefaultsToNoOverride() {
        XCTAssertEqual(SummaryThinkingLevel.current, .none)

        let options = SummaryThinkingModelCatalog.requestOptions(
            modelName: "qwen3.6-plus",
            engine: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertTrue(options.isEmpty)
    }

    func testQwenUsesTheTransportSpecificLightControl() {
        defaults.set(SummaryThinkingLevel.light.rawValue, forKey: SummaryThinkingLevel.storageKey)

        let hosted = SummaryThinkingModelCatalog.requestOptions(
            modelName: "qwen3.6-plus",
            engine: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(hosted.enableThinking, true)
        XCTAssertEqual(hosted.thinkingBudget, SummaryThinkingModelCatalog.qwenLightThinkingBudget)
        XCTAssertNil(hosted.chatTemplateKwargs)

        let local = SummaryThinkingModelCatalog.requestOptions(
            modelName: "Qwen3.5-4B-Instruct",
            engine: .openAICompatible,
            baseURL: "http://localhost:8000/v1"
        )
        XCTAssertTrue(local.isEmpty, "Explicit instruct names must not receive a thinking override")

        let vLLM = SummaryThinkingModelCatalog.requestOptions(
            modelName: "qwen3.5-32b",
            engine: .openAICompatible,
            baseURL: "http://localhost:8000/v1"
        )
        XCTAssertEqual(vLLM.chatTemplateKwargs, ["enable_thinking": true])
        XCTAssertNil(vLLM.enableThinking)
    }

    func testThinkingOnlyQwenDoesNotReceiveAConflictingOverride() {
        defaults.set(SummaryThinkingLevel.light.rawValue, forKey: SummaryThinkingLevel.storageKey)

        let profile = SummaryThinkingModelCatalog.profile(
            modelName: "qwen3.8-max-preview",
            engine: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertEqual(profile.support, .thinkingOnly)

        let options = SummaryThinkingModelCatalog.requestOptions(
            modelName: "qwen3.8-max-preview",
            engine: .openAICompatible,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        )
        XCTAssertTrue(options.isEmpty)
    }

    func testMajorProviderFamiliesUseTheirNativeLightControl() {
        defaults.set(SummaryThinkingLevel.light.rawValue, forKey: SummaryThinkingLevel.storageKey)

        let gemma = SummaryThinkingModelCatalog.requestOptions(
            modelName: "google/gemma-4-12b-it",
            engine: .openAICompatible,
            baseURL: "http://localhost:8000/v1"
        )
        XCTAssertEqual(gemma.chatTemplateKwargs, ["enable_thinking": true])

        let mistral = SummaryThinkingModelCatalog.requestOptions(
            modelName: "mistral-small-2603",
            engine: .mistralAI
        )
        XCTAssertEqual(mistral.reasoningEffort, "low")

        let oldMistral = SummaryThinkingModelCatalog.requestOptions(
            modelName: "mistral-large-2512",
            engine: .mistralAI
        )
        XCTAssertTrue(oldMistral.isEmpty)

        let gemini3 = SummaryThinkingModelCatalog.requestOptions(
            modelName: "gemini-3.7-flash",
            engine: .googleAIStudio
        )
        XCTAssertEqual(gemini3.thinkingLevel, "low")

        let geminiFlashLite = SummaryThinkingModelCatalog.requestOptions(
            modelName: "gemini-3.5-flash-lite",
            engine: .googleAIStudio
        )
        XCTAssertEqual(geminiFlashLite.thinkingLevel, "low")

        let gemini25 = SummaryThinkingModelCatalog.requestOptions(
            modelName: "gemini-2.5-flash",
            engine: .googleAIStudio
        )
        XCTAssertEqual(gemini25.thinkingBudget, SummaryThinkingModelCatalog.geminiLightThinkingBudget)
    }

    func testOllamaAndMLXProfilesRemainBounded() {
        defaults.set(SummaryThinkingLevel.light.rawValue, forKey: SummaryThinkingLevel.storageKey)

        let gptOSS = SummaryThinkingModelCatalog.requestOptions(
            modelName: "gpt-oss:20b",
            engine: .localLLM
        )
        XCTAssertEqual(gptOSS.ollamaThinkLevel, "low")

        let nonThinking = SummaryThinkingModelCatalog.requestOptions(
            modelName: "llama3.2:instruct",
            engine: .localLLM
        )
        XCTAssertTrue(nonThinking.isEmpty)

        let mlxProfile = SummaryThinkingModelCatalog.profile(
            modelName: "qwen3.5-4b",
            engine: .mlxSwift
        )
        XCTAssertEqual(mlxProfile.support, .controllable(.mlx))
    }

    func testUnsetCompatibleRequestOmitsEveryThinkingField() throws {
        let request = ChatCompletionRequest(
            model: "llama3.2:instruct",
            messages: [ChatMessage(role: "user", content: "Summarize this.")]
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["reasoning_effort"])
        XCTAssertNil(object["enable_thinking"])
        XCTAssertNil(object["thinking_budget"])
        XCTAssertNil(object["chat_template_kwargs"])
    }

    // MARK: - Reasoning Output Budget

    func testNonReasoningModelKeepsTheConfiguredOutputBudget() {
        XCTAssertFalse(
            SummaryThinkingModelCatalog.emitsReasoningTokens(
                modelName: "llama-3.3-70b-instruct",
                engine: .openAICompatible
            )
        )
        XCTAssertEqual(
            SummaryThinkingModelCatalog.completionTokenBudget(
                configured: 4_096,
                modelName: "llama-3.3-70b-instruct",
                engine: .openAICompatible
            ),
            4_096
        )
    }

    func testThinkingModelGetsHeadroomAboveTheConfiguredBudget() {
        let budget = SummaryThinkingModelCatalog.completionTokenBudget(
            configured: 4_096,
            modelName: "aurora/ornith-1.5-35b-a3b-thinking-gguf",
            engine: .openAICompatible
        )

        XCTAssertEqual(budget, 4_096 + SummaryThinkingModelCatalog.reasoningTokenHeadroom)
    }

    func testBudgetHeadroomCoversReasoningModelsTheTransportCatalogDoesNotControl() {
        // deepseek-r1 has no controllable transport on a compatible endpoint, but
        // it still spends completion tokens thinking.
        XCTAssertEqual(
            SummaryThinkingModelCatalog.profile(
                modelName: "deepseek-r1-distill-qwen-32b",
                engine: .openAICompatible
            ).support,
            .unsupported
        )
        XCTAssertTrue(
            SummaryThinkingModelCatalog.emitsReasoningTokens(
                modelName: "deepseek-r1-distill-qwen-32b",
                engine: .openAICompatible
            )
        )
    }

    func testDerivedBudgetStaysWithinTheCatalogCeiling() {
        let budget = SummaryThinkingModelCatalog.completionTokenBudget(
            configured: SummaryThinkingModelCatalog.maximumCompletionTokenBudget,
            modelName: "gpt-5-thinking",
            engine: .openAICompatible
        )

        XCTAssertEqual(budget, SummaryThinkingModelCatalog.maximumCompletionTokenBudget)
    }

    func testTruncatedChoiceIsDetectedFromFinishReason() throws {
        let json = """
        {"index":0,"message":{"role":"assistant","content":"cut off mid-"},"finish_reason":"length"}
        """
        let choice = try JSONDecoder().decode(Choice.self, from: Data(json.utf8))
        XCTAssertTrue(choice.wasTruncatedByTokenLimit)

        let completed = """
        {"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}
        """
        XCTAssertFalse(
            try JSONDecoder().decode(Choice.self, from: Data(completed.utf8)).wasTruncatedByTokenLimit
        )
    }

    func testUsageReportsReasoningTokensWhenTheProviderSendsThem() throws {
        let json = """
        {"prompt_tokens":5735,"completion_tokens":4096,"total_tokens":9831,
         "completion_tokens_details":{"reasoning_tokens":3110}}
        """
        let usage = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.reasoningTokens, 3110)

        let withoutDetails = """
        {"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}
        """
        XCTAssertNil(try JSONDecoder().decode(Usage.self, from: Data(withoutDetails.utf8)).reasoningTokens)
    }

    func testTruncationErrorNamesTheLimitAndTheReasoningCost() {
        let error = SummarizationError.responseTruncated(
            service: "Compatible API (ornith-thinking)",
            tokenLimit: 8_192,
            reasoningTokens: 3_110
        )

        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("8192"), description)
        XCTAssertTrue(description.contains("3110"), description)
        XCTAssertTrue(error.recoverySuggestion?.contains("Max Tokens") == true)
    }

    func testEveryEngineGivesItsReasoningModelsHeadroom() {
        let cases: [(String, AIEngineType)] = [
            ("aurora/ornith-1.5-35b-a3b-thinking-gguf", .openAICompatible),
            ("magistral-medium-latest", .mistralAI),
            ("gemini-3.7-flash", .googleAIStudio),
            ("qwen3.5:8b", .localLLM),
            ("qwen3.5-4b", .mlxSwift)
        ]

        for (model, engine) in cases {
            let budget = SummaryThinkingModelCatalog.completionTokenBudget(
                configured: 4_096,
                modelName: model,
                engine: engine
            )
            XCTAssertGreaterThan(budget, 4_096, "\(model) on \(engine.rawValue) got no reasoning headroom")
        }
    }

    func testOllamaResponseReportsTruncationFromDoneReason() throws {
        let truncated = """
        {"model":"qwen3.5:8b","created_at":"2026-08-22T21:19:17Z","response":"{\\"summary\\": \\"cut",
         "done":true,"done_reason":"length"}
        """
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: Data(truncated.utf8))
        XCTAssertTrue(decoded.wasTruncatedByTokenLimit)

        let completed = """
        {"model":"qwen3.5:8b","created_at":"2026-08-22T21:19:17Z","response":"done",
         "done":true,"done_reason":"stop"}
        """
        XCTAssertFalse(
            try JSONDecoder().decode(OllamaGenerateResponse.self, from: Data(completed.utf8)).wasTruncatedByTokenLimit
        )
    }

    func testGeminiCandidateReportsTruncationFromFinishReason() throws {
        let truncated = """
        {"content":{"parts":[{"text":"{\\"summary\\": \\"cut"}]},"finishReason":"MAX_TOKENS"}
        """
        let candidate = try JSONDecoder().decode(
            GoogleAIStudioService.Candidate.self,
            from: Data(truncated.utf8)
        )
        XCTAssertTrue(candidate.wasTruncatedByTokenLimit)

        let completed = """
        {"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}
        """
        XCTAssertFalse(
            try JSONDecoder().decode(
                GoogleAIStudioService.Candidate.self,
                from: Data(completed.utf8)
            ).wasTruncatedByTokenLimit
        )
    }

    // MARK: - Engine Selection Recovery

    func testUnrecognizedEngineSelectionIsRewrittenToTheFallback() {
        // "AWS Bedrock" names a provider this build removed. It can still reach
        // a device through an iCloud settings restore from an older backup, and
        // the one-shot launch migration will not run again to repair it.
        XCTAssertTrue(
            SummaryManager.shouldPersistFallbackSelection(
                savedEngineName: "AWS Bedrock",
                knownEngineNames: Set(AIEngineType.allCases.map(\.rawValue)),
                removedProviderMigrationCompleted: true
            )
        )
    }

    func testEngineSelectionIsNotRewrittenBeforeTheMigrationHasRun() {
        // The registry is built on first access to SummaryManager, which can
        // happen before the launch migrations. "OpenAI" is not a known engine,
        // but the migration maps it to Compatible API along with its
        // credentials — overwriting it first would destroy the only record of
        // what the user had configured.
        XCTAssertFalse(
            SummaryManager.shouldPersistFallbackSelection(
                savedEngineName: "OpenAI",
                knownEngineNames: Set(AIEngineType.allCases.map(\.rawValue)),
                removedProviderMigrationCompleted: false
            )
        )
        XCTAssertTrue(
            SummaryManager.shouldPersistFallbackSelection(
                savedEngineName: "OpenAI",
                knownEngineNames: Set(AIEngineType.allCases.map(\.rawValue)),
                removedProviderMigrationCompleted: true
            ),
            "once the migration has had its chance, a still-unknown name is dead"
        )
    }

    func testRecognizedButUnavailableEngineKeepsTheUsersPreference() {
        // Ollama is a real engine that is simply unreachable right now; the
        // preference must survive so it works again when the server comes back.
        XCTAssertFalse(
            SummaryManager.shouldPersistFallbackSelection(
                savedEngineName: AIEngineType.localLLM.rawValue,
                knownEngineNames: Set(AIEngineType.allCases.map(\.rawValue)),
                removedProviderMigrationCompleted: true
            )
        )
    }

    func testDeliberateNoneSelectionIsNeverRewritten() {
        let known = Set(AIEngineType.allCases.map(\.rawValue))
        XCTAssertFalse(
            SummaryManager.shouldPersistFallbackSelection(
                savedEngineName: "None",
                knownEngineNames: known,
                removedProviderMigrationCompleted: true
            )
        )
        XCTAssertFalse(
            SummaryManager.shouldPersistFallbackSelection(
                savedEngineName: nil,
                knownEngineNames: known,
                removedProviderMigrationCompleted: true
            )
        )
    }

        // MARK: - Truncation vs Context-Window Classification

    /// Two engines decide whether to fall back to chunked processing by matching
    /// "context" or "token" in the error text. A truncation error names its token
    /// limit, so it collides with that match — and re-chunking is the wrong remedy
    /// for an output-budget problem, since every chunk truncates the same way.
    func testTruncationErrorTextCollidesWithTheContextWindowHeuristic() {
        let truncated = SummarizationError.responseTruncated(
            service: "Ollama (qwen3.5:8b)",
            tokenLimit: 8_192,
            reasoningTokens: 3_110
        )
        let message = (truncated.errorDescription ?? "").lowercased()

        // This is why the engines must match on the typed case before the text:
        // the message legitimately says "token" and always will.
        XCTAssertTrue(message.contains("token"), "message: \(message)")
        XCTAssertFalse(message.contains("context"), "message: \(message)")
    }

    func testTruncationIsDistinguishableFromOtherSummarizationErrors() {
        let truncated = SummarizationError.responseTruncated(
            service: "Google AI Studio (gemini-3.7-flash)",
            tokenLimit: 8_192,
            reasoningTokens: nil
        )
        let unavailable = SummarizationError.aiServiceUnavailable(service: "Google AI Studio")

        func isTruncation(_ error: SummarizationError) -> Bool {
            if case .responseTruncated = error { return true }
            return false
        }

        XCTAssertTrue(isTruncation(truncated))
        XCTAssertFalse(isTruncation(unavailable))
    }

        func testReasoningBlocksAreNotReturnedAsSummaryContent() throws {
        let response = """
        {"role":"assistant","content":[
          {"type":"thinking","thinking":[{"type":"text","text":"hidden reasoning"}]},
          {"type":"text","text":"final summary"}
        ]}
        """
        let data = Data(response.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(message.content, "final summary")
    }
}
