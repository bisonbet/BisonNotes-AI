import Foundation

// This registry is intentionally centralized so model capability rules remain auditable.
/// A small, intentionally conservative model database for summary thinking.
///
/// Model names and API transports change independently, so this is kept in one
/// place instead of spreading substring checks through each provider. Unknown
/// models stay unsupported until their request contract is known.
enum SummaryThinkingModelCatalog { // swiftlint:disable:this type_body_length
    /// A bounded "light" budget for hosted Qwen APIs. Alibaba documents that
    /// open-source frameworks do not expose Qwen's hosted budget parameter; in
    /// those runtimes the chat-template switch is the most portable control.
    static let qwenLightThinkingBudget = 1_536

    /// Gemini 2.5's legacy budget field has a documented minimum of 1,024.
    static let geminiLightThinkingBudget = 1_024

    /// Extra output budget for models that spend part of the completion on a
    /// reasoning pass. `max_completion_tokens` covers reasoning *and* the answer
    /// on chat-completion endpoints, so a budget sized for the answer alone gets
    /// eaten by thinking and the answer comes back truncated mid-JSON.
    static let reasoningTokenHeadroom = 4_096

    /// Ceiling for any budget derived here, including truncation retry growth.
    static let maximumCompletionTokenBudget = 32_768

    /// Name markers that identify a reasoning model for budgeting purposes only.
    /// This list is deliberately broader than the transport profiles below: an
    /// output cap that is too high costs nothing (providers bill generated
    /// tokens, not the cap), while one that is too low truncates the response.
    private static let reasoningNameMarkers = [
        "thinking",
        "reasoning",
        "-r1",
        "qwq",
        "magistral",
        "gpt-oss",
        "glm-4.5",
        "glm-4.6",
        "minimax-m",
        "seed-oss"
    ]

    /// Whether the model is expected to emit reasoning tokens that count against
    /// the completion budget. Used to size requests, never to choose a control
    /// field — `requestOptions` remains the only source for those.
    static func emitsReasoningTokens(
        modelName: String,
        engine: AIEngineType,
        baseURL: String? = nil
    ) -> Bool {
        if profile(modelName: modelName, engine: engine, baseURL: baseURL).support != .unsupported {
            return true
        }

        let model = normalized(modelName)
        return reasoningNameMarkers.contains { model.contains($0) }
    }

    /// The completion budget to request for `configured` tokens of answer.
    /// Non-reasoning models are left exactly as the user configured them.
    static func completionTokenBudget(
        configured: Int,
        modelName: String,
        engine: AIEngineType,
        baseURL: String? = nil,
        level: SummaryThinkingLevel = .current
    ) -> Int {
        guard configured > 0 else { return configured }
        guard emitsReasoningTokens(modelName: modelName, engine: engine, baseURL: baseURL) else {
            return configured
        }

        // A model told to think within an explicit budget needs that much room
        // plus a small margin; everything else gets the generic headroom.
        let options = requestOptions(
            modelName: modelName,
            engine: engine,
            baseURL: baseURL,
            level: level
        )
        let headroom = options.thinkingBudget.map { $0 + 512 } ?? reasoningTokenHeadroom

        return min(configured + headroom, maximumCompletionTokenBudget)
    }

    static func profile( // swiftlint:disable:this cyclomatic_complexity
        modelName: String,
        engine: AIEngineType? = nil,
        baseURL: String? = nil
    ) -> SummaryThinkingProfile {
        let model = normalized(modelName)
        let hasThinkingMarker = model.contains("thinking") || model.contains("reasoning")
        let hasInstructMarker = model.contains("instruct")

        // An explicit model suffix/name wins over family heuristics. This is
        // useful for user-entered names such as qwen3.6-instruct or foo-thinking.
        if hasInstructMarker && !hasThinkingMarker {
            return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
        }

        switch engine {
        case .googleAIStudio:
            return googleProfile(modelName: modelName, normalizedModel: model)
        case .mistralAI:
            return mistralProfile(modelName: modelName, normalizedModel: model)
        case .localLLM:
            return ollamaProfile(modelName: modelName, normalizedModel: model)
        case .mlxSwift:
            return mlxProfile(modelName: modelName, normalizedModel: model)
        case .openAICompatible:
            return compatibleProfile(modelName: modelName, normalizedModel: model, baseURL: baseURL)
        case .appleNative:
            return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
        case nil:
            break
        }

        if isGemma4(model) {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.gemmaChatTemplate)
            )
        }
        if isQwenHybrid(model) {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.qwenChatTemplate)
            )
        }
        if hasThinkingMarker {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.openAIReasoningEffort)
            )
        }
        if isOpenAIReasoningModel(model) {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.openAIReasoningEffort)
            )
        }

        return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
    }

    static func requestOptions( // swiftlint:disable:this function_body_length
        modelName: String,
        engine: AIEngineType,
        baseURL: String? = nil,
        level: SummaryThinkingLevel = .current
    ) -> SummaryThinkingRequestOptions {
        guard level == .light else { return .none }

        let profile = profile(modelName: modelName, engine: engine, baseURL: baseURL)
        guard case .controllable(let transport) = profile.support else {
            return .none
        }

        switch transport {
        case .openAIReasoningEffort, .mistralReasoningEffort:
            return SummaryThinkingRequestOptions(
                reasoningEffort: "low",
                enableThinking: nil,
                thinkingBudget: nil,
                thinkingLevel: nil,
                chatTemplateKwargs: nil,
                ollamaThinkLevel: nil
            )
        case .qwenHosted:
            return SummaryThinkingRequestOptions(
                reasoningEffort: nil,
                enableThinking: true,
                thinkingBudget: qwenLightThinkingBudget,
                thinkingLevel: nil,
                chatTemplateKwargs: nil,
                ollamaThinkLevel: nil
            )
        case .qwenChatTemplate, .gemmaChatTemplate:
            return SummaryThinkingRequestOptions(
                reasoningEffort: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                thinkingLevel: nil,
                chatTemplateKwargs: ["enable_thinking": true],
                ollamaThinkLevel: nil
            )
        case .geminiThinkingLevel:
            return SummaryThinkingRequestOptions(
                reasoningEffort: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                thinkingLevel: "low",
                chatTemplateKwargs: nil,
                ollamaThinkLevel: nil
            )
        case .geminiThinkingBudget:
            return SummaryThinkingRequestOptions(
                reasoningEffort: nil,
                enableThinking: nil,
                thinkingBudget: geminiLightThinkingBudget,
                thinkingLevel: nil,
                chatTemplateKwargs: nil,
                ollamaThinkLevel: nil
            )
        case .ollama:
            return SummaryThinkingRequestOptions(
                reasoningEffort: nil,
                enableThinking: nil,
                thinkingBudget: nil,
                thinkingLevel: nil,
                chatTemplateKwargs: nil,
                ollamaThinkLevel: "low"
            )
        case .mlx:
            // These runtimes receive the switch through their native template
            // context, not through a network request field.
            return .none
        }
    }

    static func currentEngine() -> AIEngineType {
        let rawValue = UserDefaults.standard.string(forKey: "SelectedAIEngine")
            ?? AIEngineType.mlxSwift.rawValue
        return AIEngineType(rawValue: rawValue) ?? .mlxSwift
    }

    static func currentModelIdentifier(for engine: AIEngineType = currentEngine()) -> String {
        switch engine {
        case .openAICompatible:
            return UserDefaults.standard.string(forKey: "openAICompatibleModel") ?? ""
        case .mistralAI:
            return UserDefaults.standard.string(forKey: "mistralModel")
                ?? MistralAIModel.mistralMedium2508.rawValue
        case .localLLM:
            return UserDefaults.standard.string(forKey: "ollamaModelName")
                ?? AppSettingsKeys.Defaults.ollamaModelName
        case .googleAIStudio:
            return UserDefaults.standard.string(forKey: "googleAIStudioModel")
                ?? "gemini-3.7-flash"
        case .mlxSwift:
            return UserDefaults.standard.string(forKey: MLXSwiftSettingsKeys.modelId)
                ?? MLXSwiftSettingsKeys.defaultModelId
        case .appleNative:
            return "Foundation Models"
        }
    }

    static func currentProfile() -> SummaryThinkingProfile {
        let engine = currentEngine()
        let baseURL: String?
        if engine == .openAICompatible {
            baseURL = UserDefaults.standard.string(forKey: "openAICompatibleBaseURL")
        } else {
            baseURL = nil
        }

        return profile(
            modelName: currentModelIdentifier(for: engine),
            engine: engine,
            baseURL: baseURL
        )
    }

    // MARK: Family Profiles

    private static func compatibleProfile(
        modelName: String,
        normalizedModel model: String,
        baseURL: String?
    ) -> SummaryThinkingProfile {
        if isGemma4(model) {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.gemmaChatTemplate)
            )
        }

        if isQwenHybrid(model) {
            if model.contains("qwen3.8") || model.contains("qwen3-8"), model.contains("max") {
                return SummaryThinkingProfile(modelName: modelName, support: .thinkingOnly)
            }

            let hostedEndpoint = isQwenHostedEndpoint(baseURL)
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(hostedEndpoint ? .qwenHosted : .qwenChatTemplate)
            )
        }

        if isMistralAdjustable(model) {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.mistralReasoningEffort)
            )
        }

        if isOpenAIReasoningModel(model) || model.contains("thinking") || model.contains("reasoning") {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.openAIReasoningEffort)
            )
        }

        return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
    }

    private static func googleProfile(
        modelName: String,
        normalizedModel model: String
    ) -> SummaryThinkingProfile {
        if model.contains("gemini-3") || model.contains("gemini3") {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.geminiThinkingLevel)
            )
        }
        if model.contains("gemini-2.5") || model.contains("gemini2.5") || model.contains("gemini-25") {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.geminiThinkingBudget)
            )
        }
        return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
    }

    private static func mistralProfile(
        modelName: String,
        normalizedModel model: String
    ) -> SummaryThinkingProfile {
        if model.contains("magistral") {
            return SummaryThinkingProfile(modelName: modelName, support: .thinkingOnly)
        }
        if isMistralAdjustable(model) {
            return SummaryThinkingProfile(
                modelName: modelName,
                support: .controllable(.mistralReasoningEffort)
            )
        }
        return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
    }

    private static func ollamaProfile(
        modelName: String,
        normalizedModel model: String
    ) -> SummaryThinkingProfile {
        if isGemma4(model) || isQwenHybrid(model) || model.contains("gpt-oss") {
            if model.contains("qwen3.8") || model.contains("qwen3-8"), model.contains("max") {
                return SummaryThinkingProfile(modelName: modelName, support: .thinkingOnly)
            }
            return SummaryThinkingProfile(modelName: modelName, support: .controllable(.ollama))
        }
        if model.contains("deepseek-r1") || model.contains("-r1") || model.hasSuffix(":r1") {
            return SummaryThinkingProfile(modelName: modelName, support: .thinkingOnly)
        }
        if model.contains("magistral") {
            return SummaryThinkingProfile(modelName: modelName, support: .thinkingOnly)
        }
        if model.contains("thinking") || model.contains("reasoning") {
            return SummaryThinkingProfile(modelName: modelName, support: .controllable(.ollama))
        }
        return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
    }

    private static func mlxProfile(
        modelName: String,
        normalizedModel model: String
    ) -> SummaryThinkingProfile {
        if model.contains("ternary-bonsai-27b") || model.contains("qwen3.5") || model.contains("qwen3-5") {
            return SummaryThinkingProfile(modelName: modelName, support: .controllable(.mlx))
        }
        return SummaryThinkingProfile(modelName: modelName, support: .unsupported)
    }

    private static func normalized(_ modelName: String) -> String {
        modelName.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isGemma4(_ model: String) -> Bool {
        model.contains("gemma4") || model.contains("gemma-4")
    }

    private static func isQwenHybrid(_ model: String) -> Bool {
        model.contains("qwen3.5")
            || model.contains("qwen3-5")
            || model.contains("qwen35")
            || model.contains("qwen3.6")
            || model.contains("qwen3-6")
            || model.contains("qwen36")
            || model.contains("qwen3.7")
            || model.contains("qwen3-7")
            || model.contains("qwen37")
            || model.contains("qwen3")
    }

    private static func isMistralAdjustable(_ model: String) -> Bool {
        model.contains("mistral-small-2603")
            || model.contains("mistral-small-latest")
            || model.contains("mistral-medium-3-5")
            || model.contains("mistral-medium-latest")
    }

    private static func isOpenAIReasoningModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-5")
            || model.hasPrefix("gpt5")
            || model.hasPrefix("o1")
            || model.hasPrefix("o3")
            || model.hasPrefix("o4")
    }

    private static func isQwenHostedEndpoint(_ baseURL: String?) -> Bool {
        guard let baseURL else { return false }
        let endpoint = baseURL.lowercased()
        return endpoint.contains("dashscope")
            || endpoint.contains("aliyuncs.com")
            || endpoint.contains("qwencloud")
    }
}
