//
//  AWSBedrockModels.swift
//  Audio Journal
//
//  AWS Bedrock models and configuration for AI summarization
//

import Foundation

// MARK: - AWS Bedrock Models

enum AWSBedrockModel: String, CaseIterable {
    case claude4Sonnet = "global.anthropic.claude-sonnet-4-20250514-v1:0"
    case claude45Sonnet = "global.anthropic.claude-sonnet-4-5-20250929-v1:0"
    case claude45Haiku = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    case llama4Maverick = "us.meta.llama4-maverick-17b-instruct-v1:0"

    /// Legacy model identifier for migration purposes
    private static let legacyClaude35Haiku = "us.anthropic.claude-3-5-haiku-20241022-v1:0"

    /// Migrates legacy model identifiers to current model cases
    /// - Parameter rawValue: The stored model identifier
    /// - Returns: Migrated model identifier compatible with current enum
    static func migrate(rawValue: String) -> String {
        switch rawValue {
        case legacyClaude35Haiku:
            return AWSBedrockModel.claude45Haiku.rawValue
        default:
            return rawValue
        }
    }
    
    var displayName: String {
        switch self {
        case .claude4Sonnet:
            return "Claude Sonnet 4"
        case .claude45Sonnet:
            return "Claude Sonnet 4.5"
        case .claude45Haiku:
            return "Claude 4.5 Haiku"
        case .llama4Maverick:
            return "Llama 4 Maverick 17B Instruct"
        }
    }

    var description: String {
        switch self {
        case .claude4Sonnet:
            return "Latest Claude Sonnet 4 with advanced reasoning, coding, and analysis capabilities"
        case .claude45Sonnet:
            return "Latest Claude Sonnet 4.5 with advanced reasoning, coding, and analysis capabilities"
        case .claude45Haiku:
            return "Fast and efficient Claude Haiku 4.5 model optimized for quick responses"
        case .llama4Maverick:
            return "Meta's latest Llama 4 Maverick model with enhanced reasoning and performance"
        }
    }

    var maxTokens: Int {
        switch self {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            return 8192
        case .llama4Maverick:
            return 4096
        }
    }

    var contextWindow: Int {
        switch self {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            return 200000
        case .llama4Maverick:
            return 128000
        }
    }

    var costTier: String {
        switch self {
        case .claude4Sonnet, .claude45Sonnet:
            return "Premium"
        case .claude45Haiku:
            return "Standard"
        case .llama4Maverick:
            return "Economy"
        }
    }

    var provider: String {
        switch self {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            return "Anthropic"
        case .llama4Maverick:
            return "Meta"
        }
    }

    var supportsStructuredOutput: Bool {
        switch self {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            return true
        case .llama4Maverick:
            return false
        }
    }

    /// Maximum allowed response length to prevent DoS attacks
    /// Different models have different verbosity characteristics
    var maxResponseLength: Int {
        switch self {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            return 500_000  // Claude models are generally concise
        case .llama4Maverick:
            return 500_000  // Llama models are reasonably concise
        }
    }
}

// MARK: - AWS Bedrock Configuration

struct AWSBedrockConfig: Equatable {
    let region: String
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let model: AWSBedrockModel
    let temperature: Double
    let maxTokens: Int
    let timeout: TimeInterval
    let useProfile: Bool
    let profileName: String?
    
    static var `default`: AWSBedrockConfig {
        return AWSBedrockConfig(
            region: "us-east-1",
            accessKeyId: "",
            secretAccessKey: "",
            sessionToken: nil,
            model: .claude45Haiku,
            temperature: 0.1,
            maxTokens: 8192,
            timeout: SummarizationTimeouts.current(),
            useProfile: false,
            profileName: nil
        )
    }
    
    var isValid: Bool {
        if useProfile {
            return !region.isEmpty && profileName != nil && !profileName!.isEmpty
        } else {
            return !region.isEmpty && !accessKeyId.isEmpty && !secretAccessKey.isEmpty
        }
    }
}

// MARK: - AWS Bedrock API Request/Response Models

struct AWSBedrockInvokeRequest {
    let modelId: String
    let contentType: String
    let accept: String
    let body: Data
    
    init(modelId: String, body: Data) {
        self.modelId = modelId
        self.contentType = "application/json"
        self.accept = "application/json"
        self.body = body
    }
}

struct AWSBedrockInvokeResponse {
    let body: Data
    let contentType: String
}

// MARK: - Model-Specific Request Bodies

protocol BedrockModelRequest: Codable {
    // Protocol for Bedrock model requests
}

// Anthropic Claude 3.5 Models
struct Claude35Request: BedrockModelRequest {
    let messages: [Claude35Message]
    let maxTokens: Int
    let temperature: Double
    let topP: Double?
    let topK: Int?
    let stopSequences: [String]?
    let anthropicVersion: String
    let system: String?
    
    enum CodingKeys: String, CodingKey {
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case stopSequences = "stop_sequences"
        case anthropicVersion = "anthropic_version"
        case system
    }
    
    init(messages: [Claude35Message], maxTokens: Int, temperature: Double, system: String? = nil) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = nil
        self.topK = nil
        self.stopSequences = nil
        self.anthropicVersion = "bedrock-2023-05-31"
        self.system = system
    }
}

struct Claude35Message: Codable {
    let role: String
    let content: [Claude35Content]
    
    init(role: String, text: String) {
        self.role = role
        self.content = [Claude35Content(type: "text", text: text)]
    }
}

struct Claude35Content: Codable {
    let type: String
    let text: String
}

// Meta Llama Models
struct LlamaRequest: BedrockModelRequest {
    let prompt: String
    let maxGenLen: Int
    let temperature: Double
    let topP: Double
    
    enum CodingKeys: String, CodingKey {
        case prompt
        case maxGenLen = "max_gen_len"
        case temperature
        case topP = "top_p"
    }
    
    init(prompt: String, maxTokens: Int, temperature: Double) {
        self.prompt = prompt
        self.maxGenLen = maxTokens
        self.temperature = temperature
        self.topP = 0.9
    }
}

// MARK: - Model-Specific Response Bodies

protocol BedrockModelResponse: Codable {
    var content: String { get }
}

struct Claude35Response: BedrockModelResponse {
    let id: String?
    let type: String?
    let role: String?
    let contentArray: [Claude35ResponseContent]
    let model: String?
    let stopReason: String?
    let stopSequence: String?
    let usage: Claude35Usage?
    
    var content: String {
        return contentArray.compactMap { $0.text }.joined(separator: "")
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, role, model
        case contentArray = "content"
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }
}

struct Claude35ResponseContent: Codable {
    let type: String
    let text: String?
}

struct Claude35Usage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct LlamaResponse: BedrockModelResponse {
    let generation: String
    let promptTokenCount: Int?
    let generationTokenCount: Int?
    let stopReason: String?
    
    var content: String { return generation }
    
    enum CodingKeys: String, CodingKey {
        case generation
        case promptTokenCount = "prompt_token_count"
        case generationTokenCount = "generation_token_count"
        case stopReason = "stop_reason"
    }
}

// MARK: - AWS Error Response

struct AWSBedrockError: Codable, LocalizedError {
    let message: String
    let type: String?
    let code: String?
    
    var errorDescription: String? {
        return message
    }
    
    enum CodingKeys: String, CodingKey {
        case message
        case type = "__type"
        case code
    }
}

// MARK: - Model Factory

class AWSBedrockModelFactory {
    static func createRequest(
        for model: AWSBedrockModel,
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int,
        temperature: Double
    ) -> any BedrockModelRequest {
        switch model {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            var messages = [Claude35Message]()
            messages.append(Claude35Message(role: "user", text: prompt))
            return Claude35Request(
                messages: messages,
                maxTokens: maxTokens,
                temperature: temperature,
                system: systemPrompt
            )

        case .llama4Maverick:
            let formattedPrompt = formatLlamaPrompt(prompt: prompt, systemPrompt: systemPrompt)
            return LlamaRequest(
                prompt: formattedPrompt,
                maxTokens: maxTokens,
                temperature: temperature
            )
        }
    }

    static func parseResponse(
        for model: AWSBedrockModel,
        data: Data
    ) throws -> any BedrockModelResponse {
        switch model {
        case .claude4Sonnet, .claude45Sonnet, .claude45Haiku:
            // Claude models use explicit CodingKeys, no strategy needed
            let decoder = JSONDecoder()
            return try decoder.decode(Claude35Response.self, from: data)

        case .llama4Maverick:
            // Llama models use explicit CodingKeys, no strategy needed
            let decoder = JSONDecoder()
            return try decoder.decode(LlamaResponse.self, from: data)
        }
    }
    
    private static func formatLlamaPrompt(prompt: String, systemPrompt: String?) -> String {
        let system = systemPrompt ?? "You are a helpful assistant."
        return """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>
        
        \(system)<|eot_id|><|start_header_id|>user<|end_header_id|>
        
        \(prompt)<|eot_id|><|start_header_id|>assistant<|end_header_id|>
        
        """
    }
}
