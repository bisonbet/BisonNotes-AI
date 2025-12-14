//
//  OpenAIModels.swift
//  Audio Journal
//
//  OpenAI models and configuration for AI summarization
//

import Foundation

// MARK: - OpenAI Models for Summarization

enum OpenAISummarizationModel: String, CaseIterable {
    case gpt41 = "gpt-4.1"
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41Nano = "gpt-4.1-nano"
    
    var displayName: String {
        switch self {
        case .gpt41:
            return "GPT-4.1"
        case .gpt41Mini:
            return "GPT-4.1 Mini"
        case .gpt41Nano:
            return "GPT-4.1 Nano"
        }
    }
    
    var description: String {
        switch self {
        case .gpt41:
            return "Most robust and comprehensive analysis with advanced reasoning capabilities"
        case .gpt41Mini:
            return "Balanced performance and cost, suitable for most summarization tasks"
        case .gpt41Nano:
            return "Fastest and most economical for basic summarization needs"
        }
    }
    
    var maxTokens: Int {
        switch self {
        case .gpt41:
            return 4096
        case .gpt41Mini:
            return 2048
        case .gpt41Nano:
            return 1024
        }
    }
    
    var costTier: String {
        switch self {
        case .gpt41:
            return "Premium"
        case .gpt41Mini:
            return "Standard"
        case .gpt41Nano:
            return "Economy"
        }
    }
}

// MARK: - OpenAI Configuration

struct OpenAISummarizationConfig: Equatable {
    let apiKey: String
    let model: OpenAISummarizationModel
    let baseURL: String
    let temperature: Double
    let maxTokens: Int
    let timeout: TimeInterval
    let dynamicModelId: String? // For dynamic models not in the predefined enum
    
    static let `default` = OpenAISummarizationConfig(
        apiKey: "",
        model: .gpt41Mini,
        baseURL: "https://api.openai.com/v1",
        temperature: 0.1,
        maxTokens: 2048,
        timeout: 30.0,
        dynamicModelId: nil
    )
    
    var effectiveModelId: String {
        return dynamicModelId ?? model.rawValue
    }
}

// MARK: - OpenAI API Request/Response Models

struct OpenAIChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxCompletionTokens: Int?
    let topP: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let responseFormat: ResponseFormat?
    
    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxCompletionTokens = "max_tokens"
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
    }
    
    init(model: String, messages: [ChatMessage], temperature: Double? = nil, maxCompletionTokens: Int? = nil, topP: Double? = nil, frequencyPenalty: Double? = nil, presencePenalty: Double? = nil, responseFormat: ResponseFormat? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxCompletionTokens = maxCompletionTokens
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.responseFormat = responseFormat
    }
}

// MARK: - Message Content Models

enum MessageContentFormat {
    case string      // Standard OpenAI format: "content": "text"
    case blocks      // Nebius/Anthropic format: "content": [{"type": "text", "text": "..."}]

    /// Human-readable description for logging and display
    var displayName: String {
        switch self {
        case .string:
            return "simple string"
        case .blocks:
            return "content blocks"
        }
    }
}

struct ContentBlock: Codable {
    let type: String
    let text: String
}

struct ChatMessage: Codable {
    let role: String
    private let stringContent: String?
    private let blockContent: [ContentBlock]?

    // Internal format preference (not encoded)
    private let preferredFormat: MessageContentFormat

    // Convenience initializer for simple string content
    init(role: String, content: String, format: MessageContentFormat = .string) {
        self.role = role
        self.preferredFormat = format

        switch format {
        case .string:
            self.stringContent = content
            self.blockContent = nil
        case .blocks:
            self.stringContent = nil
            // Note: Single text block for now. Future: support multiple content blocks
            // for multimodal features (text + images, etc.)
            self.blockContent = [ContentBlock(type: "text", text: content)]
        }
    }

    // Initializer for multiple content blocks (supports multimodal content)
    init(role: String, blocks: [ContentBlock], format: MessageContentFormat = .blocks) {
        self.role = role
        self.preferredFormat = format
        self.stringContent = nil
        self.blockContent = blocks
    }

    // Get the content as a string (for internal use)
    // Combines all content blocks into a single string when multiple blocks are present
    var content: String {
        if let stringContent = stringContent {
            return stringContent
        } else if let blockContent = blockContent, !blockContent.isEmpty {
            // Filter out non-text blocks and combine text blocks
            let textBlocks = blockContent.filter { $0.type == "text" }
            guard !textBlocks.isEmpty else { return "" }
            return textBlocks.map { $0.text }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Codable Implementation

    enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        // Encode based on preferred format
        switch preferredFormat {
        case .string:
            try container.encode(stringContent ?? "", forKey: .content)
        case .blocks:
            try container.encode(blockContent ?? [], forKey: .content)
        }
    }

    /// Decode ChatMessage from JSON
    ///
    /// **Important**: The `expectedFormat` parameter is NOT automatically used by JSONDecoder.
    /// Swift's automatic decoder synthesis calls `init(from:)` without custom parameters.
    ///
    /// **How this works**:
    /// 1. When decoding API responses, Swift uses the default `expectedFormat = .string`
    /// 2. The decoder tries both string and block formats automatically (lines 207-214)
    /// 3. Successfully decodes either format but stores `preferredFormat = expectedFormat`
    /// 4. When re-encoded (e.g., for conversation history), uses the expected format
    ///
    /// **Thread Safety**: This ensures format consistency even when servers send unexpected formats.
    /// For example, if a service expects `.string` but receives `.blocks`, the message will
    /// decode successfully but re-encode as `.string` to match service expectations.
    ///
    /// **Testing Note**: To verify content blocks decode correctly from Nebius/Anthropic responses,
    /// test with actual API responses containing `"content": [{"type": "text", "text": "..."}]`
    init(from decoder: Decoder, expectedFormat: MessageContentFormat = .string) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        // Try to decode both ways, but respect expectedFormat for consistency
        if let stringValue = try? container.decode(String.self, forKey: .content) {
            stringContent = stringValue
            blockContent = nil
            preferredFormat = expectedFormat  // Use expected, not inferred
        } else if let blocksValue = try? container.decode([ContentBlock].self, forKey: .content) {
            stringContent = nil
            blockContent = blocksValue
            preferredFormat = expectedFormat  // Use expected, not inferred
        } else {
            // Fallback to empty string
            stringContent = ""
            blockContent = nil
            preferredFormat = expectedFormat
        }
    }
}

// MARK: - Provider Detection

/// Detects the appropriate message format for OpenAI-compatible API providers
///
/// Supports automatic detection based on known provider URLs and manual override
/// via UserDefaults. Thread-safe through service-level caching at initialization.
///
/// - Supported Formats:
///   - `.string`: Standard OpenAI format {"content": "text"}
///   - `.blocks`: Content blocks format {"content": [{"type": "text", "text": "..."}]}
///
/// - Detection Priority:
///   1. Manual override (if enabled in settings)
///   2. URL-based automatic detection (domain matching)
///   3. Fallback to `.string` (most common)
///
/// - Note: Services cache format detection results at initialization to ensure thread safety
class MessageFormatDetector {

    // UserDefaults keys for manual override
    private static let manualOverrideEnabledKey = "openAICompatibleManualFormatOverride"
    private static let manualFormatKey = "openAICompatibleManualFormat"

    // Known providers that use content blocks format
    private static let blockFormatProviders = [
        "nebius.com",               // Nebius API (matches *.nebius.com including api.tokenfactory.nebius.com)
        "anthropic.com",            // Anthropic (if using OpenAI compat)
        "fireworks.ai"              // Fireworks AI (some models)
    ]

    // Known providers that use simple string format
    private static let stringFormatProviders = [
        "openai.com",               // Official OpenAI (matches *.openai.com)
        "groq.com",                 // Groq
        "openrouter.ai",            // OpenRouter
        "together.xyz",             // Together AI
        "perplexity.ai"             // Perplexity
    ]

    /// Detect the message format based on the base URL
    /// Checks manual override first, then falls back to automatic detection
    static func detectFormat(for baseURL: String) -> MessageContentFormat {
        // Check for manual override first
        if UserDefaults.standard.bool(forKey: manualOverrideEnabledKey) {
            let manualFormat = UserDefaults.standard.string(forKey: manualFormatKey) ?? "string"
            let format: MessageContentFormat = manualFormat == "blocks" ? .blocks : .string
            #if DEBUG
            print("🔧 Manual override enabled: \(manualFormat) format")
            #endif
            return format
        }

        // Automatic detection based on URL host
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            // If URL parsing fails, fall back to string matching
            #if DEBUG
            print("⚠️ Failed to parse base URL: \(baseURL), using fallback detection")
            #endif
            return detectFormatFallback(for: baseURL)
        }

        // Use extracted logic for host-based detection
        return detectFormatByHost(host)
    }

    /// Core detection logic based on host name
    /// Extracted to avoid duplication between detectFormat and detectFormatWithoutOverride
    /// Handles edge cases: ports, IP addresses, localhost, and subdomains
    private static func detectFormatByHost(_ host: String) -> MessageContentFormat {
        // URL.host already strips the port for us, no manual extraction needed
        let lowercasedHost = host.lowercased()

        // Check if it's a known block format provider using proper host matching
        for provider in blockFormatProviders {
            if isHostMatch(lowercasedHost, provider: provider) {
                #if DEBUG
                print("🔍 Auto-detected block format provider: \(provider)")
                #endif
                return .blocks
            }
        }

        // Check if it's a known string format provider using proper host matching
        for provider in stringFormatProviders {
            if isHostMatch(lowercasedHost, provider: provider) {
                #if DEBUG
                print("🔍 Auto-detected string format provider: \(provider)")
                #endif
                return .string
            }
        }

        // Default to string format (most common)
        #if DEBUG
        print("🔍 Unknown provider, defaulting to string format")
        #endif
        return .string
    }

    /// Check if a host matches a provider domain
    /// Handles: exact matches, subdomains, localhost, and IP addresses
    private static func isHostMatch(_ host: String, provider: String) -> Bool {
        // Exact match
        if host == provider {
            return true
        }

        // Subdomain match (e.g., "api.openai.com" matches "openai.com")
        if host.hasSuffix("." + provider) {
            return true
        }

        // Localhost variations (for development servers)
        // Only match localhost variants exactly to prevent false positives
        if provider == "localhost" && (host == "localhost" || host == "127.0.0.1" || host == "::1") {
            return true
        }

        // For IP addresses, require exact match
        if provider.starts(with: "127.") || provider.starts(with: "::1") {
            return host == provider
        }

        return false
    }

    /// Fallback detection using string matching when URL parsing fails
    /// Uses more restrictive matching to avoid false positives from query params/fragments
    /// Logs a warning and defaults to .string format for safety
    private static func detectFormatFallback(for baseURL: String) -> MessageContentFormat {
        #if DEBUG
        print("⚠️ URL parsing failed for: \(baseURL)")
        print("⚠️ Using fallback string matching - this may not be reliable")
        #endif

        // Extract only the host portion before query params (?) and fragments (#)
        // This prevents matching providers in URLs like: https://example.com?provider=openai.com
        let hostPortion: String
        if let queryIndex = baseURL.firstIndex(of: "?") {
            hostPortion = String(baseURL[..<queryIndex])
        } else if let fragmentIndex = baseURL.firstIndex(of: "#") {
            hostPortion = String(baseURL[..<fragmentIndex])
        } else {
            hostPortion = baseURL
        }

        let lowercasedHost = hostPortion.lowercased()

        // More restrictive matching: require the provider domain to appear in the host portion
        // with proper domain boundaries (preceded by "://" or ".")
        for provider in blockFormatProviders {
            if matchesProviderDomain(lowercasedHost, provider: provider) {
                #if DEBUG
                print("⚠️ Fallback matched block format provider: \(provider)")
                #endif
                return .blocks
            }
        }

        for provider in stringFormatProviders {
            if matchesProviderDomain(lowercasedHost, provider: provider) {
                #if DEBUG
                print("⚠️ Fallback matched string format provider: \(provider)")
                #endif
                return .string
            }
        }

        #if DEBUG
        print("⚠️ No provider match in fallback, defaulting to .string format")
        #endif
        return .string
    }

    /// Check if a URL string contains a provider domain with proper boundaries
    /// Prevents false matches in query params or malicious URLs
    private static func matchesProviderDomain(_ urlString: String, provider: String) -> Bool {
        // Match if provider appears after "://" (protocol boundary)
        if urlString.contains("://\(provider)") {
            return true
        }

        // Match if provider appears after "." (subdomain boundary)
        if urlString.contains(".\(provider)") {
            return true
        }

        // Match if provider appears at start with "://" following
        if urlString.hasPrefix(provider + "/") || urlString.hasPrefix(provider + ":") {
            return true
        }

        return false
    }

    /// Get the detected format as a string (for display purposes)
    static func getDetectedFormatString(for baseURL: String) -> String {
        let format = detectFormatWithoutOverride(for: baseURL)
        return format == .blocks ? "Content Blocks" : "Simple String"
    }

    /// Detect format without considering manual override (for UI display)
    static func detectFormatWithoutOverride(for baseURL: String) -> MessageContentFormat {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            return detectFormatFallback(for: baseURL)
        }

        // Use extracted logic for host-based detection
        return detectFormatByHost(host)
    }

    /// Check if a base URL should use response_format
    /// Uses precise URL matching to avoid false positives
    static func shouldUseResponseFormat(for baseURL: String) -> Bool {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            return false
        }

        // Only use response_format with official OpenAI API
        // Must be exactly "api.openai.com" or a subdomain of "openai.com"
        return host == "api.openai.com" || host == "openai.com" || host.hasSuffix(".openai.com")
    }
}

struct OpenAIChatCompletionResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage?
}

struct Choice: Codable {
    let index: Int
    let message: ChatMessage
    let finishReason: String?
    
    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

struct Usage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

// MARK: - Structured Output Support

struct ResponseFormat: Codable {
    let type: String
    let jsonSchema: JSONSchema?
    
    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
    
    static func jsonSchema(name: String, schema: [String: Any], strict: Bool = true) -> ResponseFormat {
        return ResponseFormat(
            type: "json_schema",
            jsonSchema: JSONSchema(name: name, schema: schema, strict: strict)
        )
    }
    
    static let json = ResponseFormat(type: "json_object", jsonSchema: nil)
}

struct JSONSchema: Codable {
    let name: String
    let schema: [String: Any]
    let strict: Bool?
    
    enum CodingKeys: String, CodingKey {
        case name
        case schema
        case strict
    }
    
    init(name: String, schema: [String: Any], strict: Bool? = true) {
        self.name = name
        self.schema = schema
        self.strict = strict
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(strict, forKey: .strict)
        
        // Encode the schema as a raw JSON object
        let jsonData = try JSONSerialization.data(withJSONObject: schema, options: [])
        if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
            try container.encode(AnyCodable(jsonObject), forKey: .schema)
        } else {
            try container.encode(schema.mapValues { AnyCodable($0) }, forKey: .schema)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict)
        
        let anyCodable = try container.decode(AnyCodable.self, forKey: .schema)
        schema = anyCodable.value as? [String: Any] ?? [:]
    }
}

// Helper for encoding Any types
struct AnyCodable: Codable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let intVal = value as? Int {
            try container.encode(intVal)
        } else if let stringVal = value as? String {
            try container.encode(stringVal)
        } else if let boolVal = value as? Bool {
            try container.encode(boolVal)
        } else if let arrayVal = value as? [Any] {
            try container.encode(arrayVal.map { AnyCodable($0) })
        } else if let dictVal = value as? [String: Any] {
            try container.encode(dictVal.mapValues { AnyCodable($0) })
        } else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Invalid type for AnyCodable"))
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            throw DecodingError.typeMismatch(AnyCodable.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Could not decode AnyCodable"))
        }
    }
}

// MARK: - Schema Helpers

extension ResponseFormat {
    static var completeResponseSchema: ResponseFormat {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "The main summary of the content"
                ],
                "tasks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "priority": ["type": "string", "enum": ["high", "medium", "low"]],
                            "category": ["type": "string", "enum": ["call", "meeting", "purchase", "research", "email", "travel", "health", "general"]],
                            "timeReference": ["type": "string"],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1]
                        ],
                        "required": ["text", "priority"],
                        "additionalProperties": false
                    ]
                ],
                "reminders": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "urgency": ["type": "string", "enum": ["immediate", "today", "thisWeek", "later"]],
                            "timeReference": ["type": "string"],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1]
                        ],
                        "required": ["text"],
                        "additionalProperties": false
                    ]
                ],
                "titles": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "category": ["type": "string", "enum": ["meeting", "personal", "technical", "general"]],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1]
                        ],
                        "required": ["text", "confidence"],
                        "additionalProperties": false
                    ]
                ],
                "contentType": [
                    "type": "string",
                    "enum": ["meeting", "personalJournal", "technical", "general"],
                    "description": "The type of content being summarized"
                ]
            ],
            "required": ["summary", "tasks", "reminders", "titles"],
            "additionalProperties": false
        ]
        
        return ResponseFormat.jsonSchema(name: "complete_response", schema: schema)
    }
}

// OpenAIErrorResponse and OpenAIError are defined in OpenAITranscribeService.swift

// MARK: - Model Discovery Support for OpenAI Compatible APIs

struct OpenAIModelsListResponse: Codable {
    let data: [OpenAIModelInfo]
    let object: String?
}

struct OpenAIModelInfo: Codable {
    let id: String
    let object: String
    let created: Int?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
    }
}
