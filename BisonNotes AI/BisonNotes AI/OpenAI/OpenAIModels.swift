//
//  CompatibleAPIModels.swift
//  Audio Journal
//
//  Shared chat-completion models and configuration for compatible AI services
//

import Foundation

// MARK: - Compatible API Configuration

struct OpenAICompatibleConfig: Equatable {
    let apiKey: String
    let modelID: String
    let baseURL: String
    let temperature: Double
    let maxTokens: Int
    let timeout: TimeInterval
    let dynamicModelId: String? // For dynamic models not in the predefined enum

    static var defaultTimeout: TimeInterval { SummarizationTimeouts.current() }
    static let connectionTestTimeout: TimeInterval = 30.0

    static var `default`: OpenAICompatibleConfig {
        return OpenAICompatibleConfig(
            apiKey: "",
            modelID: "",
            baseURL: "",
            temperature: 0.1,
            maxTokens: 2048,
            timeout: OpenAICompatibleConfig.defaultTimeout,
            dynamicModelId: nil
        )
    }

    var effectiveModelId: String {
        return dynamicModelId ?? modelID
    }
}

// MARK: - Chat Completion Request/Response Models

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxCompletionTokens: Int?
    let topP: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let responseFormat: ResponseFormat?
    let reasoningEffort: String?  // For reasoning models: "low", "medium", "high"
    let enableThinking: Bool?      // Qwen-compatible hosted APIs
    let thinkingBudget: Int?       // Qwen/Gemini-compatible hosted APIs
    let chatTemplateKwargs: [String: Bool]? // vLLM/llama.cpp-compatible APIs

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxCompletionTokens = "max_completion_tokens"
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
        case reasoningEffort = "reasoning_effort"
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case chatTemplateKwargs = "chat_template_kwargs"
    }

    init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        maxCompletionTokens: Int? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        responseFormat: ResponseFormat? = nil,
        reasoningEffort: String? = nil,
        enableThinking: Bool? = nil,
        thinkingBudget: Int? = nil,
        chatTemplateKwargs: [String: Bool]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxCompletionTokens = maxCompletionTokens
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.responseFormat = responseFormat
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
        self.thinkingBudget = thinkingBudget
        self.chatTemplateKwargs = chatTemplateKwargs
    }
}

// MARK: - Message Content Models

enum MessageContentFormat {
    case string      // Standard chat-completion format: "content": "text"
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

    init(type: String, text: String) {
        self.type = type
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case content
        case thinking
        case reasoning
    }

    /// Mistral reasoning responses may represent thinking as nested blocks,
    /// while other compatible providers use a flat `text` field. Keep decoding
    /// permissive and let ChatMessage.content hide reasoning blocks later.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"

        if let textValue = try container.decodeIfPresent(String.self, forKey: .text) {
            text = textValue
        } else if let contentValue = try container.decodeIfPresent(String.self, forKey: .content) {
            text = contentValue
        } else if let thinkingBlocks = try? container.decode([ContentBlock].self, forKey: .thinking) {
            text = thinkingBlocks.map(\.text).joined(separator: "\n")
        } else if let thinkingText = try? container.decode(String.self, forKey: .thinking) {
            text = thinkingText
        } else if let reasoningBlocks = try? container.decode([ContentBlock].self, forKey: .reasoning) {
            text = reasoningBlocks.map(\.text).joined(separator: "\n")
        } else if let reasoningText = try? container.decode(String.self, forKey: .reasoning) {
            text = reasoningText
        } else {
            text = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(text, forKey: .text)
    }
}

struct ChatMessage: Codable {
    let role: String
    private let stringContent: String?
    private let blockContent: [ContentBlock]?

    // Internal format preference (not encoded)
    private let preferredFormat: MessageContentFormat

    /// CodingUserInfo key for passing MessageContentFormat through the decoder
    static let formatKey = CodingUserInfoKey(rawValue: "messageContentFormat")!

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
            // Filter out reasoning blocks so hidden traces never reach summary
            // parsing or the user-facing summary view.
            let textBlocks = blockContent.filter {
                let type = $0.type.lowercased()
                return type != "thinking" && type != "reasoning" && type != "thought"
            }
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
    /// **Format Detection**: The expected format is passed via `decoder.userInfo[ChatMessage.formatKey]`.
    /// Services should set this when configuring the JSONDecoder to ensure format consistency.
    ///
    /// **How this works**:
    /// 1. Service sets `decoder.userInfo[ChatMessage.formatKey] = cachedMessageFormat`
    /// 2. Decoder retrieves expected format from userInfo (defaults to `.string` if not set)
    /// 3. Tries to decode both string and block formats automatically
    /// 4. Stores the expected format in `preferredFormat` for re-encoding consistency
    /// 5. When re-encoded (e.g., for conversation history), uses the expected format
    ///
    /// **Thread Safety**: This ensures format consistency even when servers send unexpected formats.
    /// For example, if a service expects `.string` but receives `.blocks`, the message will
    /// decode successfully but re-encode as `.string` to match service expectations.
    ///
    /// **Usage**:
    /// ```swift
    /// let decoder = JSONDecoder()
    /// decoder.userInfo[ChatMessage.formatKey] = .blocks  // or .string
    /// let response = try decoder.decode(ChatCompletionResponse.self, from: data)
    /// ```
    ///
    /// **Testing Note**: To verify content blocks decode correctly from Nebius/Anthropic responses,
    /// test with actual API responses containing `"content": [{"type": "text", "text": "..."}]`
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)

        // Get expected format from decoder userInfo (defaults to .string)
        let expectedFormat = decoder.userInfo[ChatMessage.formatKey] as? MessageContentFormat ?? .string

        // Try to decode both ways, but respect expectedFormat for consistency
        // IMPORTANT: We always use expectedFormat (not the detected format) for preferredFormat
        // because we need re-encoding to match what the service expects, not what we received.
        //
        // Example scenario:
        // - Service expects .blocks (Nebius/Anthropic)
        // - Server mistakenly sends .string format
        // - We decode successfully (string format detected)
        // - We store preferredFormat = .blocks (expected, not detected)
        // - When re-encoding for conversation history, we use .blocks (correct for this API)
        //
        // This ensures format consistency across the entire conversation, even if individual
        // responses arrive in unexpected formats.
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

/// Detects the appropriate message format for compatible API providers
///
/// Supports automatic detection based on known provider URLs and manual override
/// via UserDefaults. Thread-safe through service-level caching at initialization.
///
/// - Supported Formats:
///   - `.string`: Standard chat-completion format {"content": "text"}
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
        "anthropic.com",            // Anthropic (if using the compatible protocol)
        "fireworks.ai"              // Fireworks AI (some models)
    ]

    // Known providers that use simple string format
    private static let stringFormatProviders = [
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
            AppLog.shared.networking("Manual override enabled: \(manualFormat) format", level: .debug)
            return format
        }

        // Automatic detection based on URL host
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            // If URL parsing fails, fall back to string matching
            AppLog.shared.networking("Failed to parse base URL, using fallback detection", level: .error)
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
                AppLog.shared.networking("Auto-detected block format provider: \(provider)", level: .debug)
                return .blocks
            }
        }

        // Check if it's a known string format provider using proper host matching
        for provider in stringFormatProviders {
            if isHostMatch(lowercasedHost, provider: provider) {
                AppLog.shared.networking("Auto-detected string format provider: \(provider)", level: .debug)
                return .string
            }
        }

        // Default to string format (most common)
        AppLog.shared.networking("Unknown provider, defaulting to string format", level: .debug)
        return .string
    }

    /// Check if a host matches a provider domain
    /// Handles: exact matches, subdomains, localhost variations, and IP addresses
    ///
    /// **Note**: Currently "localhost" is not in any provider list, but this logic is
    /// future-proof for development/testing scenarios where localhost-based providers
    /// might be added (e.g., for local LLM servers or testing environments).
    private static func isHostMatch(_ host: String, provider: String) -> Bool {
        // Exact match (works for domains, IPs, and "localhost")
        if host == provider {
            return true
        }

        // Subdomain match (e.g., "api.example.com" matches "example.com")
        // Does not apply to IP addresses or "localhost"
        if host.hasSuffix("." + provider) {
            return true
        }

        // Special handling for localhost variants (future-proofing)
        // If "localhost" is ever added to a provider list, this ensures
        // that "127.0.0.1" and "::1" are also matched
        if provider == "localhost" && (host == "127.0.0.1" || host == "::1") {
            return true
        }

        // IP address exact match (IPv4 and IPv6)
        // Prevents prefix matching for security (e.g., "127.0.0.1" shouldn't match "127.0.0.10")
        if provider.starts(with: "127.") || provider.starts(with: "::1") || provider.contains(":") {
            return host == provider
        }

        return false
    }

    /// Fallback detection using string matching when URL parsing fails
    /// Uses more restrictive matching to avoid false positives from query params/fragments
    /// Logs a warning and defaults to .string format for safety
    private static func detectFormatFallback(for baseURL: String) -> MessageContentFormat {
        AppLog.shared.networking("URL parsing failed, using fallback string matching", level: .error)

        // Extract only the host portion before query params (?) and fragments (#)
        // This prevents matching providers in URLs like: https://example.com?provider=other.example.com
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
                AppLog.shared.networking("Fallback matched block format provider: \(provider)", level: .debug)
                return .blocks
            }
        }

        for provider in stringFormatProviders {
            if matchesProviderDomain(lowercasedHost, provider: provider) {
                AppLog.shared.networking("Fallback matched string format provider: \(provider)", level: .debug)
                return .string
            }
        }

        AppLog.shared.networking("No provider match in fallback, defaulting to string format", level: .debug)
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

}

struct ChatCompletionResponse: Codable {
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

// MARK: - Models List Response (for /models endpoint)

struct CompatibleModelsResponse: Codable {
    let data: [CompatibleModelInfo]
    let object: String?
}

struct CompatibleModelInfo: Codable {
    let id: String
    let object: String?
    let created: Int?
    let ownedBy: String?

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}

struct CompatibleAPIErrorResponse: Codable {
    let error: CompatibleAPIError
}

struct CompatibleAPIError: Codable {
    let message: String
    let type: String?
    let code: String?
}
