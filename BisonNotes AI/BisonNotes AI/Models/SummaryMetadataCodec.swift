import Foundation

struct SummaryMetadataPayload: Codable {
    let engine: String
    let model: String
    /// The Summary Prompt template, when it was not Default. Older app versions
    /// ignore the key, and an absent key reads as Default.
    var promptTemplate: SummaryPromptTemplate?

    init(engine: String, model: String, promptTemplate: SummaryPromptTemplate?) {
        self.engine = engine
        self.model = model
        self.promptTemplate = promptTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case engine, model, promptTemplate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(String.self, forKey: .engine)
        model = try container.decode(String.self, forKey: .model)
        // A template this build cannot read (one from a newer build, or a
        // damaged one) reads as Default rather than costing engine and model.
        promptTemplate = (try? container.decodeIfPresent(SummaryPromptTemplate.self, forKey: .promptTemplate)) ?? nil
    }
}

/// Constants for AI engine type names used throughout the app
/// These should match the engineType properties of SummarizationEngine implementations
struct AIEngineTypeConstants {
    static let googleAI = "Google AI"
    static let openAICompatible = "OpenAI API Compatible"
    static let mistralAI = "Mistral AI"
    static let ollama = "Ollama"
    static let appleIntelligence = "Apple Intelligence" // Kept for legacy metadata parsing
    static let onDeviceAI = "On-Device AI"
    static let mlxSwift = "MLX Swift"
    static let aiAssistant = "AI Assistant"
}

enum SummaryMetadataCodec {
    static func encode(aiEngine: String, aiModel: String, promptTemplate: SummaryPromptTemplate?) -> String {
        let payload = SummaryMetadataPayload(
            engine: aiEngine,
            model: aiModel,
            promptTemplate: promptTemplate?.recordedValue
        )
        guard let data = try? JSONEncoder().encode(payload),
              let encoded = String(data: data, encoding: .utf8) else {
            AppLog.shared.summarization("SummaryMetadataCodec: Failed to encode metadata, falling back to plain model string", level: .error)
            return aiModel
        }
        return encoded
    }

    static func decode(_ storedValue: String) -> (engine: String?, model: String, promptTemplate: SummaryPromptTemplate?) {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SummaryMetadataPayload.self, from: data),
              !payload.engine.isEmpty else {
            return (nil, trimmed.isEmpty ? "" : storedValue, nil)
        }
        return (payload.engine, payload.model, payload.promptTemplate?.recordedValue)
    }

    static func inferredEngine(from model: String) -> String {
        let methodLower = model.lowercased()
        if methodLower.contains("google") || methodLower.contains("gemini") {
            return AIEngineTypeConstants.googleAI
        } else if methodLower.contains("openai compatible") || methodLower.contains("openai-compatible") ||
                    methodLower.contains("compatible") || methodLower.contains("custom api") {
            return AIEngineTypeConstants.openAICompatible
        } else if methodLower.contains("openai") || methodLower.contains("gpt") {
            return AIEngineTypeConstants.aiAssistant
        } else if methodLower.contains("mistral ai") {
            return AIEngineTypeConstants.mistralAI
        } else if methodLower.contains("ollama") {
            return AIEngineTypeConstants.ollama
        } else if methodLower.contains("apple") || methodLower.contains("intelligence") {
            return AIEngineTypeConstants.appleIntelligence
        } else if methodLower.contains("mlx") || methodLower.contains("bonsai") || methodLower.contains("ternary") {
            return AIEngineTypeConstants.mlxSwift
        } else if methodLower.contains("device") || methodLower.contains("gemma") || methodLower.contains("phi") ||
                    methodLower.contains("qwen") || methodLower.contains("llama") || methodLower.contains("mistral") ||
                    methodLower.contains("olmo") || methodLower.contains("alpaca") {
            return AIEngineTypeConstants.onDeviceAI
        } else {
            return AIEngineTypeConstants.aiAssistant
        }
    }
}
