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

struct ChatMessage: Codable {
    let role: String
    let content: String
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
