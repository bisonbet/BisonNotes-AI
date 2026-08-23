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
            modelName: "gemini-3-flash-preview",
            engine: .googleAIStudio
        )
        XCTAssertEqual(gemini3.thinkingLevel, "low")

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
            ("gemini-3-flash-preview", .googleAIStudio),
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
