import Foundation

struct SummaryMetadataPayload: Codable {
    let engine: String
    let model: String
}

/// Constants for AI engine type names used throughout the app
/// These should match the engineType properties of SummarizationEngine implementations
struct AIEngineTypeConstants {
    static let googleAI = "Google AI"
    static let openAI = "OpenAI"
    static let awsBedrock = "AWS Bedrock"
    static let openAICompatible = "OpenAI API Compatible"
    static let mistralAI = "Mistral AI"
    static let ollama = "Ollama"
    static let appleIntelligence = "Apple Intelligence" // Kept for legacy metadata parsing
    static let onDeviceAI = "On-Device AI"
    static let aiAssistant = "AI Assistant"
}

enum SummaryMetadataCodec {
    static func encode(aiEngine: String, aiModel: String) -> String {
        let payload = SummaryMetadataPayload(engine: aiEngine, model: aiModel)
        guard let data = try? JSONEncoder().encode(payload),
              let encoded = String(data: data, encoding: .utf8) else {
            print("⚠️ SummaryMetadataCodec: Failed to encode metadata, falling back to plain model string")
            return aiModel
        }
        return encoded
    }

    static func decode(_ storedValue: String) -> (engine: String?, model: String) {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SummaryMetadataPayload.self, from: data),
              !payload.engine.isEmpty else {
            return (nil, trimmed.isEmpty ? "" : storedValue)
        }
        return (payload.engine, payload.model)
    }

    static func inferredEngine(from model: String) -> String {
        let methodLower = model.lowercased()
        if methodLower.contains("google") || methodLower.contains("gemini") {
            return AIEngineTypeConstants.googleAI
        } else if methodLower.contains("openai compatible") || methodLower.contains("openai-compatible") ||
                    methodLower.contains("compatible") || methodLower.contains("custom api") {
            return AIEngineTypeConstants.openAICompatible
        } else if methodLower.contains("openai") || methodLower.contains("gpt") {
            return AIEngineTypeConstants.openAI
        } else if methodLower.contains("bedrock") || methodLower.contains("claude") || methodLower.contains("aws") {
            return AIEngineTypeConstants.awsBedrock
        } else if methodLower.contains("mistral ai") {
            return AIEngineTypeConstants.mistralAI
        } else if methodLower.contains("ollama") {
            return AIEngineTypeConstants.ollama
        } else if methodLower.contains("apple") || methodLower.contains("intelligence") {
            return AIEngineTypeConstants.appleIntelligence
        } else if methodLower.contains("device") || methodLower.contains("gemma") || methodLower.contains("phi") ||
                    methodLower.contains("qwen") || methodLower.contains("llama") || methodLower.contains("mistral") ||
                    methodLower.contains("olmo") || methodLower.contains("alpaca") {
            return AIEngineTypeConstants.onDeviceAI
        } else {
            return AIEngineTypeConstants.aiAssistant
        }
    }
}
