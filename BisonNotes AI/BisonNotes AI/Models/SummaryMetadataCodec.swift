import Foundation

struct SummaryMetadataPayload: Codable {
    let engine: String
    let model: String
}

enum SummaryMetadataCodec {
    static func encode(aiEngine: String, aiModel: String) -> String {
        let payload = SummaryMetadataPayload(engine: aiEngine, model: aiModel)
        guard let data = try? JSONEncoder().encode(payload),
              let encoded = String(data: data, encoding: .utf8) else {
            return aiModel
        }
        return encoded
    }

    static func decode(_ storedValue: String) -> (engine: String?, model: String) {
        guard let data = storedValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SummaryMetadataPayload.self, from: data),
              !payload.engine.isEmpty else {
            return (nil, storedValue)
        }
        return (payload.engine, payload.model)
    }

    static func inferredEngine(from model: String) -> String {
        let methodLower = model.lowercased()
        if methodLower.contains("google") || methodLower.contains("gemini") {
            return "Google AI"
        } else if methodLower.contains("openai") || methodLower.contains("gpt") {
            return "OpenAI"
        } else if methodLower.contains("bedrock") || methodLower.contains("claude") || methodLower.contains("aws") {
            return "AWS Bedrock"
        } else if methodLower.contains("openai compatible") || methodLower.contains("openai-compatible") ||
                    methodLower.contains("compatible") || methodLower.contains("custom api") {
            return "OpenAI API Compatible"
        } else if methodLower.contains("mistral ai") {
            return "Mistral AI"
        } else if methodLower.contains("ollama") {
            return "Ollama"
        } else if methodLower.contains("apple") || methodLower.contains("intelligence") {
            return "Apple Intelligence"
        } else if methodLower.contains("device") || methodLower.contains("gemma") || methodLower.contains("phi") ||
                    methodLower.contains("qwen") || methodLower.contains("llama") || methodLower.contains("mistral") ||
                    methodLower.contains("olmo") || methodLower.contains("alpaca") {
            return "On-Device AI"
        } else {
            return "AI Assistant"
        }
    }
}
