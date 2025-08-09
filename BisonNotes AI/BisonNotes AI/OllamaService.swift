//
//  OllamaService.swift
//  Audio Journal
//
//  Service for communicating with Ollama local LLM server
//

import Foundation

// MARK: - Ollama Configuration

struct OllamaConfig {
    let serverURL: String
    let port: Int
    let modelName: String
    let maxTokens: Int
    let temperature: Double
    /// Maximum number of tokens the model can accept in the prompt/context
    let maxContextTokens: Int
    
    var baseURL: String {
        return "\(serverURL):\(port)"
    }
    
    static let `default` = OllamaConfig(
        serverURL: "http://localhost",
        port: 11434,
        modelName: "llama2:7b",
        maxTokens: 2048,
        temperature: 0.1,
        maxContextTokens: 4096
    )
}

// MARK: - Ollama API Models

struct OllamaListResponse: Codable {
    let models: [OllamaModel]
}

struct OllamaModel: Codable {
    let name: String
    let modified_at: String
    let size: Int64
    
    var displayName: String {
        return name.replacingOccurrences(of: ":", with: " ")
    }
}

struct OllamaGenerateRequest {
    let model: String
    let prompt: String
    let stream: Bool
    let format: OllamaFormat?
    let options: OllamaOptions?
    let tools: [OllamaTool]?
    let think: Bool?
}

// MARK: - Structured Output Format Support

// Simplified approach for OllamaFormat to avoid complex Any encoding issues
enum OllamaFormat {
    case json
    case schema([String: Any])
}

// Manual JSON conversion for OllamaGenerateRequest
extension OllamaGenerateRequest {
    func toJSONData() throws -> Data {
        var jsonDict: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": stream
        ]
        
        // Handle format field
        if let format = format {
            switch format {
            case .json:
                jsonDict["format"] = "json"
            case .schema(let schema):
                jsonDict["format"] = schema
            }
        }
        
        // Add other fields
        if let options = options {
            jsonDict["options"] = [
                "num_predict": options.num_predict,
                "temperature": options.temperature,
                "top_p": options.top_p,
                "top_k": options.top_k
            ]
        }
        
        if let tools = tools {
            // Convert tools to JSON-compatible format
            let toolsData = try JSONEncoder().encode(tools)
            let toolsJSON = try JSONSerialization.jsonObject(with: toolsData, options: [])
            jsonDict["tools"] = toolsJSON
        }
        
        if let think = think {
            jsonDict["think"] = think
        }
        
        return try JSONSerialization.data(withJSONObject: jsonDict, options: [])
    }
}


// MARK: - JSON Schema Definitions

struct OllamaJSONSchemas {
    
    static let completeAnalysisSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": [
                "type": "string",
                "description": "The main comprehensive summary of the entire transcript (15-20% of original length). Should include complete overview, key points, insights, takeaways, main themes and conclusions. Use markdown formatting with ## headers, **bold**, • bullets. This is the primary content field and should be substantial and detailed."
            ],
            "tasks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Concise, specific task description (one clear action item, not a long explanation)"],
                        "priority": ["type": "string", "enum": ["High", "Medium", "Low"]],
                        "category": ["type": "string", "enum": ["Call", "Email", "Meeting", "Purchase", "Research", "Travel", "Health", "General"]],
                        "timeReference": ["type": ["string", "null"], "description": "Time reference mentioned or null"]
                    ],
                    "required": ["text", "priority", "category"]
                ]
            ],
            "reminders": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Reminder description"],
                        "urgency": ["type": "string", "enum": ["Immediate", "Today", "This Week", "Later"]],
                        "timeReference": ["type": ["string", "null"], "description": "Specific time/date mentioned or null"]
                    ],
                    "required": ["text", "urgency"]
                ]
            ],
            "titles": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Descriptive title (40-60 characters)"],
                        "category": ["type": "string", "enum": ["Meeting", "Personal", "Technical", "General"]],
                        "confidence": ["type": "number", "minimum": 0.0, "maximum": 1.0]
                    ],
                    "required": ["text", "category", "confidence"]
                ]
            ],
            "contentType": [
                "type": "string",
                "enum": ["Meeting", "Personal", "Technical", "General"]
            ]
        ],
        "required": ["summary", "tasks", "reminders", "titles", "contentType"]
    ]
    
    static let tasksRemindersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "tasks": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Task description"],
                        "priority": ["type": "string", "enum": ["High", "Medium", "Low"]],
                        "category": ["type": "string", "enum": ["Call", "Email", "Meeting", "Purchase", "Research", "Travel", "Health", "General"]],
                        "timeReference": ["type": ["string", "null"], "description": "Time reference mentioned or null"]
                    ],
                    "required": ["text", "priority", "category"]
                ]
            ],
            "reminders": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Reminder description"],
                        "urgency": ["type": "string", "enum": ["Immediate", "Today", "This Week", "Later"]],
                        "timeReference": ["type": ["string", "null"], "description": "Specific time/date mentioned or null"]
                    ],
                    "required": ["text", "urgency"]
                ]
            ]
        ],
        "required": ["tasks", "reminders"]
    ]
    
    static let titlesSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "titles": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Descriptive title (40-60 characters)"],
                        "category": ["type": "string", "enum": ["Meeting", "Personal", "Technical", "General"]],
                        "confidence": ["type": "number", "minimum": 0.0, "maximum": 1.0]
                    ],
                    "required": ["text", "category", "confidence"]
                ]
            ]
        ],
        "required": ["titles"]
    ]
}

// MARK: - Tool Calling Support

struct OllamaTool: Codable {
    let type: String
    let function: OllamaFunction
}

struct OllamaFunction: Codable {
    let name: String
    let description: String
    let parameters: OllamaFunctionParameters
}

struct OllamaFunctionParameters: Codable {
    let type: String
    let properties: [String: OllamaProperty]
    let required: [String]
}

// Use class to handle recursive properties (classes allow recursion)
class OllamaProperty: Codable {
    let type: String
    let description: String
    let items: OllamaProperty?
    let properties: [String: OllamaProperty]?
    let required: [String]?
    
    init(type: String, description: String, items: OllamaProperty? = nil, properties: [String: OllamaProperty]? = nil, required: [String]? = nil) {
        self.type = type
        self.description = description
        self.items = items
        self.properties = properties
        self.required = required
    }
    
    // Static factory methods for cleaner syntax
    static func simple(_ type: String, _ description: String) -> OllamaProperty {
        return OllamaProperty(type: type, description: description)
    }
    
    static func array(_ type: String, _ description: String, items: OllamaProperty) -> OllamaProperty {
        return OllamaProperty(type: type, description: description, items: items)
    }
    
    static func object(_ type: String, _ description: String, properties: [String: OllamaProperty], required: [String]? = nil) -> OllamaProperty {
        return OllamaProperty(type: type, description: description, properties: properties, required: required)
    }
}

struct OllamaOptions: Codable {
    let num_predict: Int
    let temperature: Double
    let top_p: Double
    let top_k: Int
}

struct OllamaGenerateResponse: Codable {
    let model: String
    let created_at: String
    let response: String
    let done: Bool
    let done_reason: String?
    let context: [Int]?
    let total_duration: Int64?
    let load_duration: Int64?
    let prompt_eval_count: Int?
    let prompt_eval_duration: Int64?
    let eval_count: Int?
    let eval_duration: Int64?
    let tool_calls: [OllamaToolCall]?
}

struct OllamaToolCall: Codable {
    let function: OllamaToolCallFunction
}

struct OllamaToolCallFunction: Codable {
    let name: String
    let arguments: String
}

// MARK: - Ollama Service

class OllamaService: ObservableObject {
    private let config: OllamaConfig
    private let session: URLSession
    private static var requestCounter = 0

    @Published var isConnected: Bool = false
    @Published var availableModels: [OllamaModel] = []
    @Published var connectionError: String?

    /// Maximum context tokens supported by the configured model
    var maxContextTokens: Int { config.maxContextTokens }
    
    init(config: OllamaConfig = .default) {
        self.config = config
        
        // Create a custom URLSession with longer timeout for Ollama requests
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1800.0  // 30 minutes
        config.timeoutIntervalForResource = 1800.0 // 30 minutes
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Connection Management
    
    func testConnection() async -> Bool {
        do {
            let url = URL(string: "\(config.baseURL)/api/tags")!
            print("🔧 OllamaService: Testing connection to \(url)")
            
            let (data, response) = try await session.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("🔧 OllamaService: Connection test response: \(httpResponse.statusCode)")
                let success = httpResponse.statusCode == 200
                
                if success {
                    print("✅ OllamaService: Connection successful")
                } else {
                    print("❌ OllamaService: Connection failed with status \(httpResponse.statusCode)")
                    
                    // Log response data for debugging
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("❌ OllamaService: Error response: \(responseString)")
                    }
                }
                
                await MainActor.run {
                    self.isConnected = success
                    self.connectionError = success ? nil : "Server returned status code \(httpResponse.statusCode)"
                }
                return success
            }
            
            print("❌ OllamaService: Invalid response type from server")
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "Invalid response from server"
            }
            return false
            
        } catch {
            print("❌ OllamaService: Connection test failed: \(error.localizedDescription)")
            await MainActor.run {
                self.isConnected = false
                self.connectionError = error.localizedDescription
            }
            return false
        }
    }
    
    func loadAvailableModels() async throws -> [OllamaModel] {
        guard isConnected else {
            throw OllamaError.notConnected
        }
        
        let url = URL(string: "\(config.baseURL)/api/tags")!
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OllamaError.serverError("Failed to fetch models")
        }
        
        let listResponse = try JSONDecoder().decode(OllamaListResponse.self, from: data)
        
        await MainActor.run {
            self.availableModels = listResponse.models
        }
        
        return listResponse.models
    }
    
    func isModelAvailable(_ modelName: String) async -> Bool {
        do {
            let models = try await loadAvailableModels()
            return models.contains { $0.name == modelName }
        } catch {
            print("❌ OllamaService: Failed to check model availability: \(error)")
            return false
        }
    }
    
    func getFirstAvailableModel() async -> String? {
        do {
            let models = try await loadAvailableModels()
            return models.first?.name
        } catch {
            print("❌ OllamaService: Failed to get available models: \(error)")
            return nil
        }
    }
    
    // MARK: - Response Cleaning
    
    private func cleanOllamaResponse(_ response: String) -> String {
        // Remove <think> tags and their content using regex
        let thinkPattern = #"<think>[\s\S]*?</think>"#
        var cleanedResponse = response.replacingOccurrences(
            of: thinkPattern,
            with: "",
            options: .regularExpression
        )
        
        // Remove word count patterns at the end (e.g., "(199 words)", "(200 words)", etc.)
        let wordCountPattern = #"\s*\(\d+\s+words?\)\s*$"#
        cleanedResponse = cleanedResponse.replacingOccurrences(
            of: wordCountPattern,
            with: "",
            options: .regularExpression
        )
        
        // Convert \n escape sequences to actual newlines
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "\\n", with: "\n")
        
        // Clean up markdown formatting
        cleanedResponse = cleanMarkdownFormatting(cleanedResponse)
        
        // Try to extract JSON from the response if it's not already valid JSON
        if !isValidJSON(cleanedResponse) {
            cleanedResponse = extractJSONFromResponse(cleanedResponse)
        }
        
        // Trim whitespace and newlines
        return cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func isValidJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            return false
        }
    }
    
    private func extractJSONFromResponse(_ response: String) -> String {
        print("🔍 OllamaService: Attempting to extract JSON from response")
        
        // First, try to find a complete JSON object
        let jsonPattern = #"\{[\s\S]*\}"#
        if let match = response.range(of: jsonPattern, options: .regularExpression) {
            let jsonString = String(response[match])
            print("🔍 OllamaService: Found potential JSON: '\(jsonString)'")
            
            if isValidJSON(jsonString) {
                print("✅ OllamaService: Extracted valid JSON")
                return jsonString
            } else {
                print("❌ OllamaService: Extracted JSON is not valid")
            }
        }
        
        // Try to find JSON between code blocks or markdown
        let codeBlockPattern = #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#
        if let match = response.range(of: codeBlockPattern, options: .regularExpression) {
            let fullMatch = String(response[match])
            // Extract just the JSON part
            if let jsonMatch = fullMatch.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) {
                let jsonString = String(fullMatch[jsonMatch])
                print("🔍 OllamaService: Found JSON in code block: '\(jsonString)'")
                
                if isValidJSON(jsonString) {
                    print("✅ OllamaService: Extracted valid JSON from code block")
                    return jsonString
                }
            }
        }
        
        // Try to clean up common issues and extract JSON
        var cleanedResponse = response
        
        // Remove common prefixes/suffixes
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "Here's the JSON:", with: "")
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "Here is the JSON:", with: "")
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "```json", with: "")
        cleanedResponse = cleanedResponse.replacingOccurrences(of: "```", with: "")
        cleanedResponse = cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try again with cleaned response
        if let match = cleanedResponse.range(of: jsonPattern, options: .regularExpression) {
            let jsonString = String(cleanedResponse[match])
            print("🔍 OllamaService: Found JSON in cleaned response: '\(jsonString)'")
            
            if isValidJSON(jsonString) {
                print("✅ OllamaService: Extracted valid JSON from cleaned response")
                return jsonString
            }
        }
        
        // Try to convert wrong schema to correct schema if possible
        if let convertedJSON = convertWrongSchemaToCorrect(response) {
            print("⚙️ OllamaService: Successfully converted wrong schema to correct format")
            return convertedJSON
        }
        
        // If no valid JSON found, return empty JSON structure
        print("⚠️ OllamaService: Could not extract valid JSON from response, returning empty structure")
        print("📝 OllamaService: Original response was: '\(response)'")
        
        // Determine which type of JSON structure to return based on the context
        if response.contains("\"summary\"") || response.contains("\"contentType\"") || response.contains("\"transcript\"") || response.contains("\"key_points\"") {
            // Complete processing structure - model may have used wrong schema
            print("⚠️ OllamaService: Detected complete processing context but invalid schema, returning empty structure")
            return "{\"summary\":\"\",\"tasks\":[],\"reminders\":[],\"titles\":[],\"contentType\":\"General\"}"
        } else if response.contains("\"titles\"") || response.contains("title") {
            return "{\"titles\":[]}"
        } else {
            return "{\"tasks\":[],\"reminders\":[]}"
        }
    }
    
    // Helper method to convert wrong JSON schema to the correct one
    private func convertWrongSchemaToCorrect(_ response: String) -> String? {
        do {
            guard let data = response.data(using: .utf8) else { return nil }
            
            // Try to parse as generic JSON to see what fields we have
            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            print("🔍 OllamaService: Detected JSON fields: \(Array(jsonObject.keys))")
            
            // Check if this looks like a wrong schema response
            let hasWrongFields = jsonObject.keys.contains { key in
                ["transcript", "key_points", "participants", "topics_discussed", "next_steps"].contains(key)
            }
            
            guard hasWrongFields else { return nil }
            
            // Try to map the wrong schema to the correct one
            var correctedJSON: [String: Any] = [:]
            
            // Map summary field
            if let summary = jsonObject["summary"] as? String {
                correctedJSON["summary"] = summary
            } else {
                correctedJSON["summary"] = ""
            }
            
            // Convert next_steps to tasks if available
            var tasks: [[String: Any]] = []
            if let nextSteps = jsonObject["next_steps"] as? [String] {
                for step in nextSteps {
                    tasks.append([
                        "text": step,
                        "priority": "Medium",
                        "category": "General",
                        "timeReference": NSNull()
                    ])
                }
            }
            correctedJSON["tasks"] = tasks
            
            // Empty arrays for reminders and titles since wrong schema doesn't have them
            correctedJSON["reminders"] = []
            correctedJSON["titles"] = []
            correctedJSON["contentType"] = "General"
            
            // Convert back to JSON string
            let correctedData = try JSONSerialization.data(withJSONObject: correctedJSON, options: [])
            return String(data: correctedData, encoding: .utf8)
            
        } catch {
            print("❌ OllamaService: Failed to convert wrong schema: \(error)")
            return nil
        }
    }
    
    private func cleanMarkdownFormatting(_ text: String) -> String {
        var cleaned = text
        
        // Convert \n escape sequences to actual newlines first
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        
        // Remove excessive markdown formatting
        cleaned = cleaned.replacingOccurrences(of: "\\*\\*\\*", with: "**", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\*\\*\\*\\*", with: "**", options: .regularExpression)
        
        // Fix common markdown issues
        cleaned = cleaned.replacingOccurrences(of: "\\*\\s+\\*", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\*\\*\\s+\\*\\*", with: " ", options: .regularExpression)
        
        // Remove excessive newlines
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        
        return cleaned
    }
    
    private func cleanTitleResponse(_ response: String) -> String {
        // Use the centralized title cleaning function from RecordingNameGenerator
        return RecordingNameGenerator.cleanStandardizedTitleResponse(response)
    }
    
    private func cleanSummaryResponse(_ response: String) -> String {
        var cleaned = response
        
        // Remove <think> tags and their content using regex
        let thinkPattern = #"<think>[\s\S]*?</think>"#
        cleaned = cleaned.replacingOccurrences(
            of: thinkPattern,
            with: "",
            options: .regularExpression
        )
        
        // Remove word count patterns at the end (e.g., "(199 words)", "(200 words)", etc.)
        let wordCountPattern = #"\s*\(\d+\s+words?\)\s*$"#
        cleaned = cleaned.replacingOccurrences(
            of: wordCountPattern,
            with: "",
            options: .regularExpression
        )
        
        // Convert \n escape sequences to actual newlines
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        
        // Clean up markdown formatting but preserve readability
        cleaned = cleanMarkdownFormatting(cleaned)
        
        // Don't try to extract JSON - we want the full text response for summaries
        
        // Trim whitespace and newlines
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - AI Processing
    
    func processComplete(from text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Try tool calling first for models that support it
        if let result = try await processCompleteWithTools(from: text) {
            return result
        }
        
        // Try structured outputs with JSON schema for better reliability
        do {
            let structuredPrompt = createStructuredCompleteProcessingPrompt(from: text)
            let response = try await generateStructuredResponse(
                prompt: structuredPrompt,
                model: config.modelName,
                schema: OllamaJSONSchemas.completeAnalysisSchema
            )
            
            print("✅ OllamaService: Got structured output response, parsing...")
            return try parseStructuredCompleteResponse(response)
            
        } catch {
            print("⚠️ OllamaService: Structured outputs failed, falling back to traditional prompting: \(error)")
        }
        
        // Fallback to traditional prompting
        let prompt = createRobustCompleteProcessingPrompt(from: text)
        
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        // Debug logging
        print("🔍 OllamaService: Raw response for complete processing:")
        print("📝 Response: '\(response)'")
        print("📏 Response length: \(response.count) characters")
        
        // Check if response is empty
        guard !response.isEmpty else {
            print("❌ OllamaService: Received empty response")
            throw OllamaError.parsingError("Received empty response from Ollama server")
        }
        
        // Parse JSON response
        guard let data = response.data(using: .utf8) else {
            print("❌ OllamaService: Failed to convert response to UTF-8 data")
            throw OllamaError.parsingError("Failed to convert response to data")
        }
        
        print("📊 OllamaService: Data size: \(data.count) bytes")
        
        do {
            let rawResult = try JSONDecoder().decode(RawCompleteResult.self, from: data)
            
            // Convert raw results to proper objects
            let tasks = rawResult.tasks.map { rawTask in
                TaskItem(
                    text: rawTask.text,
                    priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                    timeReference: rawTask.timeReference,
                    category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                    confidence: 0.8
                )
            }
            
            let reminders = rawResult.reminders.map { rawReminder in
                ReminderItem(
                    text: rawReminder.text,
                    timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                    urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                    confidence: 0.8
                )
            }
            
            let titles = rawResult.titles.map { rawTitle in
                TitleItem(
                    text: rawTitle.text,
                    confidence: rawTitle.confidence,
                    category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                )
            }
            
            let contentType = ContentType(rawValue: rawResult.contentType) ?? .general
            
            print("✅ OllamaService: Successfully parsed complete result")
            print("📊 Summary: \(rawResult.summary.count) chars, Tasks: \(tasks.count), Reminders: \(reminders.count), Titles: \(titles.count)")
            
            return (rawResult.summary, tasks, reminders, titles, contentType)
            
        } catch {
            print("❌ OllamaService: JSON parsing failed for complete processing: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            print("❌ OllamaService: Raw response that failed to parse: '\(response)'")
            
            // Try to extract JSON from the response if it's embedded in other text
            let cleanedResponse = extractJSONFromResponse(response)
            if cleanedResponse != response {
                print("🔄 OllamaService: Attempting to parse cleaned JSON: '\(cleanedResponse)'")
                
                guard let cleanedData = cleanedResponse.data(using: .utf8) else {
                    throw OllamaError.parsingError("Failed to convert cleaned response to data")
                }
                
                do {
                    let rawResult = try JSONDecoder().decode(RawCompleteResult.self, from: cleanedData)
                    
                    let tasks = rawResult.tasks.map { rawTask in
                        TaskItem(
                            text: rawTask.text,
                            priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                            timeReference: rawTask.timeReference,
                            category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                            confidence: 0.8
                        )
                    }
                    
                    let reminders = rawResult.reminders.map { rawReminder in
                        ReminderItem(
                            text: rawReminder.text,
                            timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                            urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                            confidence: 0.8
                        )
                    }
                    
                    let titles = rawResult.titles.map { rawTitle in
                        TitleItem(
                            text: rawTitle.text,
                            confidence: rawTitle.confidence,
                            category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                        )
                    }
                    
                    let contentType = ContentType(rawValue: rawResult.contentType) ?? .general
                    
                    print("✅ OllamaService: Successfully parsed cleaned JSON for complete processing")
                    return (rawResult.summary, tasks, reminders, titles, contentType)
                    
                } catch {
                    print("❌ OllamaService: Cleaned JSON parsing also failed: \(error)")
                    throw OllamaError.parsingError("Failed to parse JSON response after cleaning: \(error.localizedDescription)")
                }
            }
            
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription)")
        }
    }
    
    func generateSummary(from text: String) async throws -> String {
        // Try tool calling first for models that support it
        if let summary = try await generateSummaryWithTools(from: text) {
            return summary
        }
        
        // Fallback to traditional prompting
        let prompt = createRobustSummaryPrompt(from: text)
        
        do {
            return try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
        } catch OllamaError.parsingError(let message) {
            print("❌ OllamaService: Summary generation failed with parsing error: \(message)")
            throw OllamaError.serverError("Failed to generate summary: \(message)")
        } catch {
            print("❌ OllamaService: Summary generation failed: \(error)")
            throw error
        }
    }
    
    private func generateSummaryWithTools(from text: String) async throws -> String? {
        // Check model type and use appropriate tool calling method
        if isQwenModel(config.modelName) {
            return try await generateSummaryWithQwenTools(from: text)
        } else if isGPTOSSModel(config.modelName) {
            return try await generateSummaryWithGPTOSSTools(from: text)
        } else if isMagistralModel(config.modelName) {
            return try await generateSummaryWithMagistralTools(from: text)
        }
        
        // Standard Ollama tool calling
        let tools = [createSummaryTool()]
        let prompt = "Please analyze the following transcript and create a comprehensive summary using the create_summary function:\n\n\(text)"
        
        do {
            let response = try await generateResponseWithTools(prompt: prompt, model: config.modelName, tools: tools)
            
            // Check if we got a tool call response
            if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                let toolCall = toolCalls[0]
                if toolCall.function.name == "create_summary" {
                    // Parse the JSON arguments
                    if let data = toolCall.function.arguments.data(using: .utf8),
                       let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let summary = json["summary"] as? String {
                        print("✅ OllamaService: Successfully generated summary using standard tool calling")
                        return summary
                    }
                }
            }
            
            print("⚠️ OllamaService: No tool calls in response, falling back to traditional prompting")
            return nil
            
        } catch {
            print("⚠️ OllamaService: Standard tool calling failed, falling back to traditional prompting: \(error)")
            return nil
        }
    }
    
    // MARK: - Tool Definitions
    
    private func createSummaryTool() -> OllamaTool {
        return OllamaTool(
            type: "function",
            function: OllamaFunction(
                name: "create_summary",
                description: "Create a comprehensive summary of the transcript with proper Markdown formatting",
                parameters: OllamaFunctionParameters(
                    type: "object",
                    properties: [
                        "summary": OllamaProperty.simple(
                            "string",
                            "A comprehensive markdown-formatted summary (15-20% of original length) with ## headers, **bold** text, • bullet points, and proper structure"
                        )
                    ],
                    required: ["summary"]
                )
            )
        )
    }
    
    private func createCompleteAnalysisTool() -> OllamaTool {
        return OllamaTool(
            type: "function",
            function: OllamaFunction(
                name: "complete_analysis",
                description: "Perform complete analysis extracting summary, tasks, reminders, titles, and content type",
                parameters: OllamaFunctionParameters(
                    type: "object",
                    properties: [
                        "summary": OllamaProperty.simple(
                            "string",
                            "Comprehensive markdown-formatted summary with ## headers, **bold** text, • bullets"
                        ),
                        "tasks": OllamaProperty.array(
                            "array",
                            "Array of actionable tasks extracted from the content",
                            items: OllamaProperty.object(
                                "object",
                                "Task object",
                                properties: [
                                    "text": OllamaProperty.simple("string", "Task description"),
                                    "priority": OllamaProperty.simple("string", "Priority: High, Medium, or Low"),
                                    "category": OllamaProperty.simple("string", "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General"),
                                    "timeReference": OllamaProperty.simple("string", "Time reference mentioned or null")
                                ],
                                required: ["text", "priority", "category"]
                            )
                        ),
                        "reminders": OllamaProperty.array(
                            "array",
                            "Array of time-sensitive reminders",
                            items: OllamaProperty.object(
                                "object",
                                "Reminder object",
                                properties: [
                                    "text": OllamaProperty.simple("string", "Reminder description"),
                                    "urgency": OllamaProperty.simple("string", "Urgency: Immediate, Today, This Week, or Later"),
                                    "timeReference": OllamaProperty.simple("string", "Specific time/date mentioned or null")
                                ],
                                required: ["text", "urgency"]
                            )
                        ),
                        "titles": OllamaProperty.array(
                            "array",
                            "Array of descriptive titles for the content",
                            items: OllamaProperty.object(
                                "object",
                                "Title object",
                                properties: [
                                    "text": OllamaProperty.simple("string", "Descriptive title (40-60 characters)"),
                                    "category": OllamaProperty.simple("string", "Category: Meeting, Personal, Technical, or General"),
                                    "confidence": OllamaProperty.simple("number", "Confidence score (0.0-1.0)")
                                ],
                                required: ["text", "category", "confidence"]
                            )
                        ),
                        "contentType": OllamaProperty.simple(
                            "string",
                            "Content classification: Meeting, Personal, Technical, or General"
                        )
                    ],
                    required: ["summary", "tasks", "reminders", "titles", "contentType"]
                )
            )
        )
    }
    
    private func createTasksAndRemindersTool() -> OllamaTool {
        return OllamaTool(
            type: "function",
            function: OllamaFunction(
                name: "extract_tasks_reminders",
                description: "Extract actionable tasks and time-sensitive reminders from the transcript",
                parameters: OllamaFunctionParameters(
                    type: "object",
                    properties: [
                        "tasks": OllamaProperty.array(
                            "array",
                            "Array of actionable tasks",
                            items: OllamaProperty.object(
                                "object",
                                "Task object",
                                properties: [
                                    "text": OllamaProperty.simple("string", "Task description"),
                                    "priority": OllamaProperty.simple("string", "Priority: High, Medium, or Low"),
                                    "category": OllamaProperty.simple("string", "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General"),
                                    "timeReference": OllamaProperty.simple("string", "Time reference or null")
                                ],
                                required: ["text", "priority", "category"]
                            )
                        ),
                        "reminders": OllamaProperty.array(
                            "array",
                            "Array of time-sensitive reminders",
                            items: OllamaProperty.object(
                                "object",
                                "Reminder object",
                                properties: [
                                    "text": OllamaProperty.simple("string", "Reminder description"),
                                    "urgency": OllamaProperty.simple("string", "Urgency: Immediate, Today, This Week, or Later"),
                                    "timeReference": OllamaProperty.simple("string", "Specific time/date or null")
                                ],
                                required: ["text", "urgency"]
                            )
                        )
                    ],
                    required: ["tasks", "reminders"]
                )
            )
        )
    }
    
    private func createTitlesTool() -> OllamaTool {
        return OllamaTool(
            type: "function",
            function: OllamaFunction(
                name: "generate_titles",
                description: "Generate descriptive titles for the transcript content",
                parameters: OllamaFunctionParameters(
                    type: "object",
                    properties: [
                        "titles": OllamaProperty.array(
                            "array",
                            "Array of 3-4 descriptive titles",
                            items: OllamaProperty.object(
                                "object",
                                "Title object",
                                properties: [
                                    "text": OllamaProperty.simple("string", "Title text (40-60 characters)"),
                                    "category": OllamaProperty.simple("string", "Category: Meeting, Personal, Technical, or General"),
                                    "confidence": OllamaProperty.simple("number", "Confidence score (0.0-1.0)")
                                ],
                                required: ["text", "category", "confidence"]
                            )
                        )
                    ],
                    required: ["titles"]
                )
            )
        )
    }
    
    // MARK: - Robust Prompt Generation
    
    private func createRobustSummaryPrompt(from text: String) -> String {
        return """
        <INSTRUCTIONS>
        You are a professional AI assistant specialized in analyzing and summarizing conversations, meetings, and transcripts. Your goal is to create comprehensive, well-structured summaries that capture the essential information.

        CRITICAL REQUIREMENTS:
        1. Create a summary that is 15-20% of the original transcript length
        2. Focus on main points, key decisions, important information, and actionable items
        3. Use proper Markdown formatting throughout your response
        4. Structure your response logically with clear sections
        5. Be comprehensive yet concise
        6. Maintain professional, clear language

        MARKDOWN FORMATTING RULES:
        - Use ## for main section headers (e.g., ## Key Points, ## Decisions Made)
        - Use **bold text** for emphasis on important information
        - Use *italic text* for secondary emphasis or highlights
        - Use • bullet points for lists and key takeaways
        - Use > blockquotes for important statements or direct quotes
        - Use --- for section dividers if needed
        - Ensure proper spacing between sections

        STRUCTURE YOUR SUMMARY WITH THESE SECTIONS (use only relevant sections):
        - ## Overview (brief context and main topic)
        - ## Key Points (main discussion points and topics)
        - ## Decisions Made (any decisions, conclusions, or resolutions)
        - ## Action Items (tasks, follow-ups, or next steps mentioned)
        - ## Important Details (specific information, dates, names, numbers)
        - ## Outcomes (results, agreements, or conclusions reached)

        QUALITY STANDARDS:
        - Extract the most important information first
        - Include specific details when relevant (names, dates, numbers)
        - Maintain the original meaning and context
        - Avoid unnecessary repetition
        - Use active voice when possible
        - Be specific rather than vague
        </INSTRUCTIONS>

        <TRANSCRIPT>
        \(text)
        </TRANSCRIPT>

        <OUTPUT>
        Please provide your comprehensive, well-formatted summary below:
        """
    }
    
    private func createRobustCompleteProcessingPrompt(from text: String) -> String {
        return """
        You MUST return ONLY valid JSON in the EXACT format specified below. Do not include any other text, explanations, or additional fields.

        REQUIRED JSON SCHEMA - You must use these exact field names and structure:
        {
          "summary": "string with markdown formatting",
          "tasks": [array of task objects],
          "reminders": [array of reminder objects],
          "titles": [array of title objects],
          "contentType": "string value"
        }

        CRITICAL INSTRUCTIONS:
        1. Use ONLY the field names: summary, tasks, reminders, titles, contentType
        2. Do NOT use fields like: transcript, key_points, participants, topics_discussed, next_steps
        3. Return ONLY the JSON object, no additional text
        4. Ensure all required fields are present (use empty arrays if no content)

        TASK OBJECTS FORMAT:
        {
          "text": "actionable task description",
          "priority": "High" or "Medium" or "Low",
          "category": "Call" or "Email" or "Meeting" or "Purchase" or "Research" or "Travel" or "Health" or "General",
          "timeReference": "specific time mentioned" or null
        }

        REMINDER OBJECTS FORMAT:
        {
          "text": "reminder description",
          "urgency": "Immediate" or "Today" or "This Week" or "Later",
          "timeReference": "specific time/date mentioned" or null
        }

        TITLE OBJECTS FORMAT:
        {
          "text": "Descriptive Title (40-60 chars)",
          "category": "Meeting" or "Personal" or "Technical" or "General",
          "confidence": 0.85
        }

        SUMMARY FORMAT:
        Create a markdown-formatted summary using:
        - ## for headers
        - **bold** for emphasis
        - • for bullet points
        - \\n for line breaks in the JSON string
        - Aim for 15-20% of original length

        CONTENT TYPE: Choose one: "Meeting", "Personal", "Technical", or "General"

        Now analyze this transcript and return the JSON:
        \(text)
        """
    }
    
    func generateTitle(from text: String) async throws -> String {
        let prompt = RecordingNameGenerator.generateStandardizedTitlePrompt(from: text)
        
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        // Clean up the response and ensure it's a good title
        let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(response)
        
        return cleanedTitle
    }
    
    func extractTasksAndReminders(from text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        // Try structured outputs first for better reliability
        do {
            let structuredPrompt = """
            Analyze the following transcript and extract actionable tasks and time-sensitive reminders.
            
            Focus on:
            - Tasks that require specific action or follow-up
            - Reminders for deadlines, appointments, or time-sensitive items
            - Proper categorization and priority assessment
            
            Transcript:
            \(text)
            """
            
            let response = try await generateStructuredResponse(
                prompt: structuredPrompt,
                model: config.modelName,
                schema: OllamaJSONSchemas.tasksRemindersSchema
            )
            
            return try parseStructuredTasksReminders(response)
            
        } catch {
            print("⚠️ OllamaService: Structured outputs failed for tasks/reminders, falling back: \(error)")
        }
        
        // Fallback to traditional prompting
        let prompt = """
        Extract tasks and reminders from the transcript. Return ONLY valid JSON:

        {
          "tasks": [
            {
              "text": "specific task description",
              "priority": "High|Medium|Low",
              "category": "Call|Email|Meeting|Purchase|Research|Travel|Health|General",
              "timeReference": "specific time mentioned or null"
            }
          ],
          "reminders": [
            {
              "text": "specific reminder description", 
              "urgency": "Immediate|Today|This Week|Later",
              "timeReference": "specific time mentioned or null"
            }
          ]
        }

        Transcript:
        \(text)
        """
        
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        // Debug logging
        print("🔍 OllamaService: Raw response for tasks/reminders:")
        print("📝 Response: '\(response)'")
        print("📏 Response length: \(response.count) characters")
        
        // Check if response is empty
        guard !response.isEmpty else {
            print("❌ OllamaService: Received empty response")
            throw OllamaError.parsingError("Received empty response from Ollama server")
        }
        
        // Parse JSON response
        guard let data = response.data(using: .utf8) else {
            print("❌ OllamaService: Failed to convert response to UTF-8 data")
            throw OllamaError.parsingError("Failed to convert response to data")
        }
        
        print("📊 OllamaService: Data size: \(data.count) bytes")
        
        do {
            let rawResult = try JSONDecoder().decode(RawTaskReminderResult.self, from: data)
            
            // Convert raw results to proper TaskItem and ReminderItem objects
            let tasks = rawResult.tasks.map { rawTask in
                TaskItem(
                    text: rawTask.text,
                    priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                    timeReference: rawTask.timeReference,
                    category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                    confidence: 0.8 // Default confidence for Ollama results
                )
            }
            
            let reminders = rawResult.reminders.map { rawReminder in
                ReminderItem(
                    text: rawReminder.text,
                    timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                    urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                    confidence: 0.8 // Default confidence for Ollama results
                )
            }
            
            print("✅ OllamaService: Successfully parsed \(tasks.count) tasks and \(reminders.count) reminders")
            return (tasks, reminders)
        } catch {
            print("❌ OllamaService: JSON parsing failed for tasks/reminders: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            print("❌ OllamaService: Raw response that failed to parse: '\(response)'")
            
            // Try to extract JSON from the response if it's embedded in other text
            let cleanedResponse = extractJSONFromResponse(response)
            if cleanedResponse != response {
                print("🔄 OllamaService: Attempting to parse cleaned JSON: '\(cleanedResponse)'")
                
                guard let cleanedData = cleanedResponse.data(using: .utf8) else {
                    throw OllamaError.parsingError("Failed to convert cleaned response to data")
                }
                
                do {
                    let rawResult = try JSONDecoder().decode(RawTaskReminderResult.self, from: cleanedData)
                    
                    let tasks = rawResult.tasks.map { rawTask in
                        TaskItem(
                            text: rawTask.text,
                            priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                            timeReference: rawTask.timeReference,
                            category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                            confidence: 0.8
                        )
                    }
                    
                    let reminders = rawResult.reminders.map { rawReminder in
                        ReminderItem(
                            text: rawReminder.text,
                            timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                            urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                            confidence: 0.8
                        )
                    }
                    
                    print("✅ OllamaService: Successfully parsed cleaned JSON with \(tasks.count) tasks and \(reminders.count) reminders")
                    return (tasks, reminders)
                } catch {
                    print("❌ OllamaService: Cleaned JSON parsing also failed: \(error)")
                }
            }
            
            // If all parsing attempts fail, return empty results instead of throwing
            print("⚠️ OllamaService: Returning empty results due to parsing failure")
            return (tasks: [], reminders: [])
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        let prompt = """
        Generate 4 descriptive titles from the transcript. Return ONLY valid JSON:

        {
          "titles": [
            {
              "text": "descriptive title (40-60 characters)",
              "category": "Meeting|Personal|Technical|General",
              "confidence": 0.85
            }
          ]
        }

        Transcript:
        \(text)
        """
        
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        // Debug logging
        print("🔍 OllamaService: Raw response for titles:")
        print("📝 Response: '\(response)'")
        print("📏 Response length: \(response.count) characters")
        
        // Check if response is empty
        guard !response.isEmpty else {
            print("❌ OllamaService: Received empty response for titles")
            return []
        }
        
        // Parse JSON response
        guard let data = response.data(using: .utf8) else {
            print("❌ OllamaService: Failed to convert titles response to UTF-8 data")
            return []
        }
        
        print("📊 OllamaService: Titles data size: \(data.count) bytes")
        
        do {
            let rawResult = try JSONDecoder().decode(RawTitleResult.self, from: data)
            
            // Convert raw results to proper TitleItem objects
            let titles = rawResult.titles.map { rawTitle in
                TitleItem(
                    text: rawTitle.text,
                    confidence: rawTitle.confidence,
                    category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                )
            }
            
            print("✅ OllamaService: Successfully parsed \(titles.count) titles")
            return titles
        } catch {
            print("❌ OllamaService: JSON parsing failed for titles: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            print("❌ OllamaService: Raw response that failed to parse: '\(response)'")
            
            // Try to extract JSON from the response if it's embedded in other text
            let cleanedResponse = extractJSONFromResponse(response)
            if cleanedResponse != response {
                print("🔄 OllamaService: Attempting to parse cleaned JSON for titles: '\(cleanedResponse)'")
                
                guard let cleanedData = cleanedResponse.data(using: .utf8) else {
                    print("❌ OllamaService: Failed to convert cleaned titles response to data")
                    return []
                }
                
                do {
                    let rawResult = try JSONDecoder().decode(RawTitleResult.self, from: cleanedData)
                    
                    let titles = rawResult.titles.map { rawTitle in
                        TitleItem(
                            text: rawTitle.text,
                            confidence: rawTitle.confidence,
                            category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                        )
                    }
                    
                    print("✅ OllamaService: Successfully parsed cleaned JSON with \(titles.count) titles")
                    return titles
                } catch {
                    print("❌ OllamaService: Cleaned JSON parsing also failed for titles: \(error)")
                }
            }
            
            // If all parsing attempts fail, return empty results instead of throwing
            print("⚠️ OllamaService: Returning empty titles due to parsing failure")
            return []
        }
    }
    
    private func processCompleteWithTools(from text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)? {
        // Check model type and use appropriate tool calling method
        if isQwenModel(config.modelName) {
            return try await processCompleteWithQwenTools(from: text)
        } else if isGPTOSSModel(config.modelName) {
            return try await processCompleteWithGPTOSSTools(from: text)
        } else if isMagistralModel(config.modelName) {
            return try await processCompleteWithMagistralTools(from: text)
        }
        
        // Standard Ollama tool calling
        let tools = [createCompleteAnalysisTool()]
        let prompt = "Please analyze the following transcript and provide a complete analysis using the complete_analysis function:\n\n\(text)"
        
        do {
            let response = try await generateResponseWithTools(prompt: prompt, model: config.modelName, tools: tools)
            
            // Check if we got a tool call response
            if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                let toolCall = toolCalls[0]
                if toolCall.function.name == "complete_analysis" {
                    // Parse the JSON arguments
                    if let data = toolCall.function.arguments.data(using: .utf8) {
                        return try parseCompleteAnalysisResult(data: data)
                    }
                }
            }
            
            print("⚠️ OllamaService: No tool calls in complete processing response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: Standard tool calling failed for complete processing: \(error)")
            return nil
        }
    }
    
    private func parseCompleteAnalysisResult(data: Data) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        do {
            let rawResult = try JSONDecoder().decode(RawCompleteResult.self, from: data)
            
            // Convert raw results to proper objects
            let tasks = rawResult.tasks.map { rawTask in
                TaskItem(
                    text: rawTask.text,
                    priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                    timeReference: rawTask.timeReference,
                    category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                    confidence: 0.9 // Higher confidence for tool calling results
                )
            }
            
            let reminders = rawResult.reminders.map { rawReminder in
                ReminderItem(
                    text: rawReminder.text,
                    timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                    urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                    confidence: 0.9 // Higher confidence for tool calling results
                )
            }
            
            let titles = rawResult.titles.map { rawTitle in
                TitleItem(
                    text: rawTitle.text,
                    confidence: rawTitle.confidence,
                    category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                )
            }
            
            let contentType = ContentType(rawValue: rawResult.contentType) ?? .general
            
            print("✅ OllamaService: Successfully parsed complete analysis from tool calling")
            return (rawResult.summary, tasks, reminders, titles, contentType)
            
        } catch {
            print("❌ OllamaService: Failed to parse tool calling result: \(error)")
            throw OllamaError.parsingError("Failed to parse tool calling response: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Qwen-Specific Tool Calling
    
    private func isQwenModel(_ modelName: String) -> Bool {
        return modelName.lowercased().contains("qwen")
    }
    
    private func isGPTOSSModel(_ modelName: String) -> Bool {
        return modelName.lowercased().contains("gpt-oss")
    }
    
    private func isMagistralModel(_ modelName: String) -> Bool {
        return modelName.lowercased().contains("magistral")
    }
    
    private func supportsThinking(_ modelName: String) -> Bool {
        let lowerModel = modelName.lowercased()
        return lowerModel.contains("qwen") || 
               lowerModel.contains("deepseek") || 
               lowerModel.contains("r1") ||
               lowerModel.contains("gpt-oss") ||
               lowerModel.contains("magistral")
    }
    
    private func generateSummaryWithQwenTools(from text: String) async throws -> String? {
        let prompt = createQwenToolPrompt(for: "summary", text: text)
        
        do {
            let response = try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
            
            // Check if we got a tool call response
            if let toolCallResult = parseQwenToolCall(response) {
                if toolCallResult.name == "create_summary",
                   let arguments = toolCallResult.arguments,
                   let summary = arguments["summary"] as? String {
                    print("✅ OllamaService: Successfully generated summary using Qwen tool calling")
                    return summary
                }
            }
            
            print("⚠️ OllamaService: No valid Qwen tool calls in response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: Qwen tool calling failed, falling back: \(error)")
            return nil
        }
    }
    
    private func processCompleteWithQwenTools(from text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)? {
        let prompt = createQwenToolPrompt(for: "complete", text: text)
        
        do {
            let response = try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
            
            // Check if we got a tool call response
            if let toolCallResult = parseQwenToolCall(response) {
                if toolCallResult.name == "complete_analysis",
                   let arguments = toolCallResult.arguments {
                    return try parseQwenCompleteAnalysisResult(arguments: arguments)
                }
                
                // IMPORTANT: Also handle high-quality summary responses
                if toolCallResult.name == "create_summary",
                   let arguments = toolCallResult.arguments,
                   let summary = arguments["summary"] as? String {
                    
                    print("🔍 OllamaService: Found create_summary with \(summary.count) characters")
                    
                    // If we have substantial content (lower threshold to catch more good content)
                    if summary.count > 2000 {
                        print("✅ OllamaService: Using high-quality Qwen summary for complete processing")
                        
                        // Use the excellent summary and extract basic tasks/reminders from it
                        do {
                            let (tasks, reminders) = try await extractTasksAndReminders(from: summary)
                            let titles = try await generateTitlesFromSummary(summary)
                            let contentType = ContentAnalyzer.classifyContent(text)
                            
                            print("✅ OllamaService: Successfully created complete result from high-quality summary")
                            print("📊 Final result: Summary: \(summary.count) chars, Tasks: \(tasks.count), Reminders: \(reminders.count), Titles: \(titles.count)")
                            return (summary, tasks, reminders, titles, contentType)
                        } catch {
                            print("⚠️ OllamaService: Failed to extract tasks/reminders from excellent summary: \(error)")
                            // Still return just the excellent summary with minimal metadata
                            return (summary, [], [], [], .general)
                        }
                    } else {
                        print("⚠️ OllamaService: Summary too short (\(summary.count) chars), falling back")
                    }
                }
            }
            
            print("⚠️ OllamaService: No valid Qwen tool calls in complete processing response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: Qwen tool calling failed for complete processing: \(error)")
            return nil
        }
    }
    
    private func createQwenToolPrompt(for type: String, text: String) -> String {
        switch type {
        case "summary":
            return """
            <|im_start|>system
            You are a helpful assistant. You have access to the following functions and MUST use them to respond.
            
            <tools>
            [
              {
                "type": "function",
                "function": {
                  "name": "create_summary",
                  "description": "Create a comprehensive summary of the transcript with proper Markdown formatting",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "summary": {
                        "type": "string",
                        "description": "A comprehensive markdown-formatted summary (15-20% of original length) with ## headers, **bold** text, • bullet points, and proper structure"
                      }
                    },
                    "required": ["summary"]
                  }
                }
              }
            ]
            </tools>
            
            IMPORTANT: You MUST respond by calling the create_summary function using this exact format:
            <tool_call>
            {"name": "create_summary", "arguments": {"summary": "your markdown summary here"}}
            </tool_call>
            
            Do not provide a direct response. Use the tool call format.<|im_end|>
            <|im_start|>user
            Please summarize this transcript:
            
            \(text)<|im_end|>
            <|im_start|>assistant
            """
            
        case "complete":
            return """
            <|im_start|>system
            You are a helpful assistant. You have access to the following functions and MUST use them to respond.
            
            <tools>
            [
              {
                "type": "function",
                "function": {
                  "name": "complete_analysis",
                  "description": "Perform complete analysis extracting summary, tasks, reminders, titles, and content type",
                  "parameters": {
                    "type": "object",
                    "properties": {
                      "summary": {
                        "type": "string",
                        "description": "Comprehensive markdown-formatted summary with ## headers, **bold** text, • bullets"
                      },
                      "tasks": {
                        "type": "array",
                        "description": "Array of actionable tasks extracted from the content",
                        "items": {
                          "type": "object",
                          "properties": {
                            "text": {"type": "string", "description": "Task description"},
                            "priority": {"type": "string", "description": "Priority: High, Medium, or Low"},
                            "category": {"type": "string", "description": "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General"},
                            "timeReference": {"type": "string", "description": "Time reference mentioned or null"}
                          },
                          "required": ["text", "priority", "category"]
                        }
                      },
                      "reminders": {
                        "type": "array",
                        "description": "Array of time-sensitive reminders",
                        "items": {
                          "type": "object",
                          "properties": {
                            "text": {"type": "string", "description": "Reminder description"},
                            "urgency": {"type": "string", "description": "Urgency: Immediate, Today, This Week, or Later"},
                            "timeReference": {"type": "string", "description": "Specific time/date mentioned or null"}
                          },
                          "required": ["text", "urgency"]
                        }
                      },
                      "titles": {
                        "type": "array",
                        "description": "Array of descriptive titles for the content",
                        "items": {
                          "type": "object",
                          "properties": {
                            "text": {"type": "string", "description": "Descriptive title (40-60 characters)"},
                            "category": {"type": "string", "description": "Category: Meeting, Personal, Technical, or General"},
                            "confidence": {"type": "number", "description": "Confidence score (0.0-1.0)"}
                          },
                          "required": ["text", "category", "confidence"]
                        }
                      },
                      "contentType": {
                        "type": "string",
                        "description": "Content classification: Meeting, Personal, Technical, or General"
                      }
                    },
                    "required": ["summary", "tasks", "reminders", "titles", "contentType"]
                  }
                }
              }
            ]
            </tools>
            
            IMPORTANT: You MUST respond by calling the complete_analysis function using this exact format:
            <tool_call>
            {"name": "complete_analysis", "arguments": {"summary": "...", "tasks": [...], "reminders": [...], "titles": [...], "contentType": "..."}}
            </tool_call>
            
            Do not provide a direct response. Use the tool call format.<|im_end|>
            <|im_start|>user
            Please analyze this transcript comprehensively:
            
            \(text)<|im_end|>
            <|im_start|>assistant
            """
            
        default:
            return ""
        }
    }
    
    private func parseQwenToolCall(_ response: String) -> (name: String, arguments: [String: Any]?)? {
        // First, look for proper <tool_call> tags
        let toolCallPattern = #"<tool_call>\s*(.*?)\s*</tool_call>"#
        
        if let match = response.range(of: toolCallPattern, options: .regularExpression) {
            let toolCallContent = String(response[match])
                .replacingOccurrences(of: "<tool_call>", with: "")
                .replacingOccurrences(of: "</tool_call>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            print("🔍 OllamaService: Found Qwen tool call: '\(toolCallContent.prefix(200))...'")
            
            // Parse JSON inside tool_call
            if let data = toolCallContent.data(using: .utf8) {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let name = json["name"] as? String {
                        let arguments = json["arguments"] as? [String: Any]
                        print("✅ OllamaService: Successfully parsed Qwen tool call: \(name)")
                        return (name, arguments)
                    }
                } catch {
                    print("❌ OllamaService: Failed to parse Qwen tool call JSON: \(error)")
                }
            }
        }
        
        // Fallback: Look for structured markdown content that we can use as a summary
        if response.contains("###") || response.contains("##") {
            print("🔍 OllamaService: Found structured Qwen content, using as fallback summary")
            
            // Extract content after <think> blocks
            let cleanedResponse = response.replacingOccurrences(
                of: #"<think>[\s\S]*?</think>"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // If we have good structured content, treat it as a summary
            if !cleanedResponse.isEmpty && cleanedResponse.count > 100 {
                print("✅ OllamaService: Using Qwen structured response as summary fallback")
                print("📊 OllamaService: Summary content length: \(cleanedResponse.count) characters")
                print("🔍 OllamaService: Summary preview: '\(cleanedResponse.prefix(200))...'")
                return ("create_summary", ["summary": cleanedResponse])
            }
        }
        
        print("⚠️ OllamaService: No Qwen tool call found in response")
        return nil
    }
    
    private func parseQwenCompleteAnalysisResult(arguments: [String: Any]) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        
        let summary = arguments["summary"] as? String ?? ""
        
        // Parse tasks
        let tasks = (arguments["tasks"] as? [[String: Any]] ?? []).compactMap { taskData -> TaskItem? in
            guard let text = taskData["text"] as? String else { return nil }
            let priorityString = taskData["priority"] as? String ?? "Medium"
            let categoryString = taskData["category"] as? String ?? "General"
            let timeReference = taskData["timeReference"] as? String
            
            return TaskItem(
                text: text,
                priority: TaskItem.Priority(rawValue: priorityString) ?? .medium,
                timeReference: timeReference,
                category: TaskItem.TaskCategory(rawValue: categoryString) ?? .general,
                confidence: 0.95 // Very high confidence for Qwen tool calling results
            )
        }
        
        // Parse reminders
        let reminders = (arguments["reminders"] as? [[String: Any]] ?? []).compactMap { reminderData -> ReminderItem? in
            guard let text = reminderData["text"] as? String else { return nil }
            let urgencyString = reminderData["urgency"] as? String ?? "Later"
            let timeReference = reminderData["timeReference"] as? String
            
            return ReminderItem(
                text: text,
                timeReference: ReminderItem.TimeReference(originalText: timeReference ?? ""),
                urgency: ReminderItem.Urgency(rawValue: urgencyString) ?? .later,
                confidence: 0.95 // Very high confidence for Qwen tool calling results
            )
        }
        
        // Parse titles
        let titles = (arguments["titles"] as? [[String: Any]] ?? []).compactMap { titleData -> TitleItem? in
            guard let text = titleData["text"] as? String else { return nil }
            let categoryString = titleData["category"] as? String ?? "General"
            let confidence = titleData["confidence"] as? Double ?? 0.85
            
            return TitleItem(
                text: text,
                confidence: confidence,
                category: TitleItem.TitleCategory(rawValue: categoryString) ?? .general
            )
        }
        
        let contentTypeString = arguments["contentType"] as? String ?? "General"
        let contentType = ContentType(rawValue: contentTypeString) ?? .general
        
        print("✅ OllamaService: Successfully parsed Qwen complete analysis")
        return (summary, tasks, reminders, titles, contentType)
    }
    
    // MARK: - Helper Methods for High-Quality Summary Processing
    
    private func generateTitlesFromSummary(_ summary: String) async throws -> [TitleItem] {
        // Extract titles from the excellent summary content
        // Look for headers and key themes
        var titles: [TitleItem] = []
        
        // Use regex to find markdown headers
        let headerPattern = #"^#+\s*([^#\n]+)"#
        let regex = try NSRegularExpression(pattern: headerPattern, options: [.anchorsMatchLines])
        let range = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        
        regex.enumerateMatches(in: summary, options: [], range: range) { match, _, _ in
            if let match = match,
               let headerRange = Range(match.range(at: 1), in: summary) {
                let headerText = String(summary[headerRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "*", with: "")  // Remove markdown formatting
                    .replacingOccurrences(of: "🔑", with: "")  // Remove emojis
                    .replacingOccurrences(of: "🛠️", with: "")
                    .replacingOccurrences(of: "💡", with: "")
                    .replacingOccurrences(of: "✅", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if headerText.count > 10 && headerText.count < 80 {
                    // Apply standardized title cleaning
                    let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(headerText)
                    if cleanedTitle != "Untitled Conversation" {
                        titles.append(TitleItem(
                            text: cleanedTitle,
                            confidence: 0.90, // High confidence from structured content
                            category: .general
                        ))
                    }
                }
            }
        }
        
        // If we don't have enough titles from headers, add a main title
        if titles.isEmpty {
            // Create a title from the first meaningful sentence
            let sentences = summary.components(separatedBy: .newlines)
            for sentence in sentences {
                let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "*", with: "")
                    .replacingOccurrences(of: "#", with: "")
                if cleaned.count > 20 && cleaned.count < 80 && !cleaned.contains("transcript") {
                    titles.append(TitleItem(
                        text: String(cleaned.prefix(60)),
                        confidence: 0.80,
                        category: .general
                    ))
                    break
                }
            }
        }
        
        return Array(titles.prefix(4)) // Return up to 4 titles
    }
    
    // MARK: - GPT-OSS Specific Tool Calling
    
    private func generateSummaryWithGPTOSSTools(from text: String) async throws -> String? {
        let prompt = createGPTOSSToolPrompt(for: "summary", text: text)
        
        do {
            let response = try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
            
            // Check if we got a tool call response with channel routing
            if let toolCallResult = parseGPTOSSToolCall(response) {
                if toolCallResult.function == "create_summary",
                   let arguments = toolCallResult.arguments,
                   let summary = arguments["summary"] as? String {
                    print("✅ OllamaService: Successfully generated summary using GPT-OSS tool calling")
                    return summary
                }
            }
            
            print("⚠️ OllamaService: No valid GPT-OSS tool calls in response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: GPT-OSS tool calling failed, falling back: \(error)")
            return nil
        }
    }
    
    private func processCompleteWithGPTOSSTools(from text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)? {
        let prompt = createGPTOSSToolPrompt(for: "complete", text: text)
        
        do {
            let response = try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
            
            // Check if we got a tool call response
            if let toolCallResult = parseGPTOSSToolCall(response) {
                if toolCallResult.function == "complete_analysis",
                   let arguments = toolCallResult.arguments {
                    return try parseGPTOSSCompleteAnalysisResult(arguments: arguments)
                }
            }
            
            print("⚠️ OllamaService: No valid GPT-OSS tool calls in complete processing response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: GPT-OSS tool calling failed for complete processing: \(error)")
            return nil
        }
    }
    
    private func createGPTOSSToolPrompt(for type: String, text: String) -> String {
        switch type {
        case "summary":
            return """
            You have access to custom analysis tools via the commentary channel.
            
            Available function: create_summary
            Description: Create a comprehensive summary of the transcript with proper Markdown formatting
            Parameters: 
            - summary (string): A comprehensive markdown-formatted summary (15-20% of original length) with ## headers, **bold** text, • bullet points, and proper structure
            
            Please analyze the following transcript and use the create_summary function to generate a well-structured summary:
            
            \(text)
            
            Use the commentary channel to call the create_summary function with the appropriate parameters.
            """
            
        case "complete":
            return """
            You have access to custom analysis tools via the commentary channel.
            
            Available function: complete_analysis
            Description: Perform complete analysis extracting summary, tasks, reminders, titles, and content type
            Parameters:
            - summary (string): Comprehensive markdown-formatted summary with ## headers, **bold** text, • bullets
            - tasks (array): Array of task objects with text, priority (High/Medium/Low), category (Call/Email/Meeting/Purchase/Research/Travel/Health/General), timeReference
            - reminders (array): Array of reminder objects with text, urgency (Immediate/Today/This Week/Later), timeReference
            - titles (array): Array of title objects with text (40-60 chars), category (Meeting/Personal/Technical/General), confidence (0.0-1.0)
            - contentType (string): Classification as Meeting/Personal/Technical/General
            
            Please analyze the following transcript and use the complete_analysis function to provide comprehensive analysis:
            
            \(text)
            
            Use the commentary channel to call the complete_analysis function with all required parameters.
            """
            
        default:
            return ""
        }
    }
    
    private func parseGPTOSSToolCall(_ response: String) -> (function: String, arguments: [String: Any]?)? {
        // Look for commentary channel function calls - GPT-OSS uses JSON format in commentary channel
        // Pattern: function calls typically appear as JSON objects with function name and arguments
        
        // Try to find JSON function call pattern
        let jsonPattern = #"\{[\s\S]*?"function"\s*:\s*"(create_summary|complete_analysis)"[\s\S]*?\}"#
        
        if let match = response.range(of: jsonPattern, options: .regularExpression) {
            let jsonContent = String(response[match])
            print("🔍 OllamaService: Found GPT-OSS function call: '\(jsonContent)'")
            
            if let data = jsonContent.data(using: .utf8) {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let functionName = json["function"] as? String {
                        let arguments = json["arguments"] as? [String: Any] ?? json // Sometimes args are at root level
                        print("✅ OllamaService: Successfully parsed GPT-OSS function call: \(functionName)")
                        return (functionName, arguments)
                    }
                } catch {
                    print("❌ OllamaService: Failed to parse GPT-OSS function call JSON: \(error)")
                }
            }
        }
        
        // Alternative: look for direct function calls with parameters
        if response.contains("create_summary") || response.contains("complete_analysis") {
            let lines = response.components(separatedBy: .newlines)
            for line in lines {
                if line.contains("create_summary") {
                    // Try to extract summary content
                    if let summaryMatch = line.range(of: #""summary"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                        let summaryContent = String(line[summaryMatch])
                        print("🔍 OllamaService: Found direct GPT-OSS summary call")
                        return ("create_summary", ["summary": summaryContent])
                    }
                }
            }
        }
        
        print("⚠️ OllamaService: No GPT-OSS function call found in response")
        return nil
    }
    
    private func parseGPTOSSCompleteAnalysisResult(arguments: [String: Any]) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Same parsing logic as Qwen but with different confidence levels
        let summary = arguments["summary"] as? String ?? ""
        
        // Parse tasks
        let tasks = (arguments["tasks"] as? [[String: Any]] ?? []).compactMap { taskData -> TaskItem? in
            guard let text = taskData["text"] as? String else { return nil }
            let priorityString = taskData["priority"] as? String ?? "Medium"
            let categoryString = taskData["category"] as? String ?? "General"
            let timeReference = taskData["timeReference"] as? String
            
            return TaskItem(
                text: text,
                priority: TaskItem.Priority(rawValue: priorityString) ?? .medium,
                timeReference: timeReference,
                category: TaskItem.TaskCategory(rawValue: categoryString) ?? .general,
                confidence: 0.92 // High confidence for GPT-OSS tool calling results
            )
        }
        
        // Parse reminders
        let reminders = (arguments["reminders"] as? [[String: Any]] ?? []).compactMap { reminderData -> ReminderItem? in
            guard let text = reminderData["text"] as? String else { return nil }
            let urgencyString = reminderData["urgency"] as? String ?? "Later"
            let timeReference = reminderData["timeReference"] as? String
            
            return ReminderItem(
                text: text,
                timeReference: ReminderItem.TimeReference(originalText: timeReference ?? ""),
                urgency: ReminderItem.Urgency(rawValue: urgencyString) ?? .later,
                confidence: 0.92 // High confidence for GPT-OSS tool calling results
            )
        }
        
        // Parse titles
        let titles = (arguments["titles"] as? [[String: Any]] ?? []).compactMap { titleData -> TitleItem? in
            guard let text = titleData["text"] as? String else { return nil }
            let categoryString = titleData["category"] as? String ?? "General"
            let confidence = titleData["confidence"] as? Double ?? 0.85
            
            return TitleItem(
                text: text,
                confidence: confidence,
                category: TitleItem.TitleCategory(rawValue: categoryString) ?? .general
            )
        }
        
        let contentTypeString = arguments["contentType"] as? String ?? "General"
        let contentType = ContentType(rawValue: contentTypeString) ?? .general
        
        print("✅ OllamaService: Successfully parsed GPT-OSS complete analysis")
        return (summary, tasks, reminders, titles, contentType)
    }
    
    // MARK: - Magistral Specific Tool Calling
    
    private func generateSummaryWithMagistralTools(from text: String) async throws -> String? {
        let prompt = createMagistralToolPrompt(for: "summary", text: text)
        
        do {
            let response = try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
            
            // Check if we got a tool call response with [TOOL_CALLS] format
            if let toolCallResult = parseMagistralToolCall(response) {
                if toolCallResult.function == "create_summary",
                   let arguments = toolCallResult.arguments,
                   let summary = arguments["summary"] as? String {
                    print("✅ OllamaService: Successfully generated summary using Magistral tool calling")
                    return summary
                }
            }
            
            print("⚠️ OllamaService: No valid Magistral tool calls in response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: Magistral tool calling failed, falling back: \(error)")
            return nil
        }
    }
    
    private func processCompleteWithMagistralTools(from text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)? {
        let prompt = createMagistralToolPrompt(for: "complete", text: text)
        
        do {
            let response = try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
            
            // Check if we got a tool call response
            if let toolCallResult = parseMagistralToolCall(response) {
                if toolCallResult.function == "complete_analysis",
                   let arguments = toolCallResult.arguments {
                    return try parseMagistralCompleteAnalysisResult(arguments: arguments)
                }
            }
            
            print("⚠️ OllamaService: No valid Magistral tool calls in complete processing response, falling back")
            return nil
            
        } catch {
            print("⚠️ OllamaService: Magistral tool calling failed for complete processing: \(error)")
            return nil
        }
    }
    
    private func createMagistralToolPrompt(for type: String, text: String) -> String {
        switch type {
        case "summary":
            return """
            [SYSTEM_PROMPT]
            You are a helpful assistant that can use tools to analyze content.
            
            [AVAILABLE_TOOLS]
            [
              {
                "name": "create_summary",
                "description": "Create a comprehensive summary of the transcript with proper Markdown formatting",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "summary": {
                      "type": "string",
                      "description": "A comprehensive markdown-formatted summary (15-20% of original length) with ## headers, **bold** text, • bullet points, and proper structure"
                    }
                  },
                  "required": ["summary"]
                }
              }
            ]
            
            [INST]Please analyze the following transcript and use the create_summary tool to generate a well-structured summary:
            
            \(text)[/INST]
            
            <think>
            I need to analyze this transcript and create a comprehensive summary using the create_summary tool. Let me process the content and structure it properly.
            </think>
            
            """
            
        case "complete":
            return """
            [SYSTEM_PROMPT]
            You are a helpful assistant that can use tools to perform comprehensive content analysis.
            
            [AVAILABLE_TOOLS]
            [
              {
                "name": "complete_analysis",
                "description": "Perform complete analysis extracting summary, tasks, reminders, titles, and content type",
                "parameters": {
                  "type": "object",
                  "properties": {
                    "summary": {
                      "type": "string",
                      "description": "Comprehensive markdown-formatted summary with ## headers, **bold** text, • bullets"
                    },
                    "tasks": {
                      "type": "array",
                      "items": {
                        "type": "object",
                        "properties": {
                          "text": {"type": "string", "description": "Task description"},
                          "priority": {"type": "string", "description": "Priority: High, Medium, or Low"},
                          "category": {"type": "string", "description": "Category: Call, Email, Meeting, Purchase, Research, Travel, Health, or General"},
                          "timeReference": {"type": "string", "description": "Time reference mentioned or null"}
                        }
                      }
                    },
                    "reminders": {
                      "type": "array",
                      "items": {
                        "type": "object",
                        "properties": {
                          "text": {"type": "string", "description": "Reminder description"},
                          "urgency": {"type": "string", "description": "Urgency: Immediate, Today, This Week, or Later"},
                          "timeReference": {"type": "string", "description": "Specific time/date mentioned or null"}
                        }
                      }
                    },
                    "titles": {
                      "type": "array",
                      "items": {
                        "type": "object",
                        "properties": {
                          "text": {"type": "string", "description": "Descriptive title (40-60 characters)"},
                          "category": {"type": "string", "description": "Category: Meeting, Personal, Technical, or General"},
                          "confidence": {"type": "number", "description": "Confidence score (0.0-1.0)"}
                        }
                      }
                    },
                    "contentType": {
                      "type": "string",
                      "description": "Content classification: Meeting, Personal, Technical, or General"
                    }
                  },
                  "required": ["summary", "tasks", "reminders", "titles", "contentType"]
                }
              }
            ]
            
            [INST]Please analyze the following transcript and use the complete_analysis tool to provide comprehensive analysis:
            
            \(text)[/INST]
            
            <think>
            I need to perform a complete analysis of this transcript, extracting summary, tasks, reminders, titles, and content type. Let me use the complete_analysis tool with all required parameters.
            </think>
            
            """
            
        default:
            return ""
        }
    }
    
    private func parseMagistralToolCall(_ response: String) -> (function: String, arguments: [String: Any]?)? {
        // Look for [TOOL_CALLS] format: [TOOL_CALLS]{function_name}[CALL_ID]{index}[ARGS]{arguments}
        let toolCallPattern = #"\[TOOL_CALLS\]\{([^}]+)\}\[CALL_ID\]\{[^}]*\}\[ARGS\]\{(.*)\}"#
        
        if let match = response.range(of: toolCallPattern, options: .regularExpression) {
            let matchStr = String(response[match])
            print("🔍 OllamaService: Found Magistral tool call pattern: '\(matchStr)'")
            
            // Extract components using regex groups
            let regex = try? NSRegularExpression(pattern: toolCallPattern)
            let nsRange = NSRange(matchStr.startIndex..., in: matchStr)
            
            if let result = regex?.firstMatch(in: matchStr, options: [], range: nsRange) {
                if result.numberOfRanges >= 3 {
                    let functionRange = Range(result.range(at: 1), in: matchStr)!
                    let argsRange = Range(result.range(at: 2), in: matchStr)!
                    
                    let functionName = String(matchStr[functionRange])
                    let argsString = String(matchStr[argsRange])
                    
                    print("🔍 OllamaService: Parsed Magistral function: \(functionName), args: \(argsString)")
                    
                    // Parse arguments as JSON
                    if let data = argsString.data(using: .utf8) {
                        do {
                            if let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                print("✅ OllamaService: Successfully parsed Magistral tool call: \(functionName)")
                                return (functionName, arguments)
                            }
                        } catch {
                            print("❌ OllamaService: Failed to parse Magistral arguments JSON: \(error)")
                        }
                    }
                }
            }
        }
        
        // Alternative: Look for simpler function calls in the response
        if response.contains("create_summary") || response.contains("complete_analysis") {
            // Try to find JSON-like structures in the response
            let jsonPattern = #"\{[\s\S]*?"summary"[\s\S]*?\}"#
            if let jsonMatch = response.range(of: jsonPattern, options: .regularExpression) {
                let jsonStr = String(response[jsonMatch])
                if let data = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("🔍 OllamaService: Found alternative Magistral JSON response")
                    return ("create_summary", json)
                }
            }
        }
        
        print("⚠️ OllamaService: No Magistral tool call found in response")
        return nil
    }
    
    private func parseMagistralCompleteAnalysisResult(arguments: [String: Any]) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Same parsing logic as other models but with Magistral-specific confidence levels
        let summary = arguments["summary"] as? String ?? ""
        
        // Parse tasks
        let tasks = (arguments["tasks"] as? [[String: Any]] ?? []).compactMap { taskData -> TaskItem? in
            guard let text = taskData["text"] as? String else { return nil }
            let priorityString = taskData["priority"] as? String ?? "Medium"
            let categoryString = taskData["category"] as? String ?? "General"
            let timeReference = taskData["timeReference"] as? String
            
            return TaskItem(
                text: text,
                priority: TaskItem.Priority(rawValue: priorityString) ?? .medium,
                timeReference: timeReference,
                category: TaskItem.TaskCategory(rawValue: categoryString) ?? .general,
                confidence: 0.93 // Very high confidence for Magistral tool calling results
            )
        }
        
        // Parse reminders
        let reminders = (arguments["reminders"] as? [[String: Any]] ?? []).compactMap { reminderData -> ReminderItem? in
            guard let text = reminderData["text"] as? String else { return nil }
            let urgencyString = reminderData["urgency"] as? String ?? "Later"
            let timeReference = reminderData["timeReference"] as? String
            
            return ReminderItem(
                text: text,
                timeReference: ReminderItem.TimeReference(originalText: timeReference ?? ""),
                urgency: ReminderItem.Urgency(rawValue: urgencyString) ?? .later,
                confidence: 0.93 // Very high confidence for Magistral tool calling results
            )
        }
        
        // Parse titles
        let titles = (arguments["titles"] as? [[String: Any]] ?? []).compactMap { titleData -> TitleItem? in
            guard let text = titleData["text"] as? String else { return nil }
            let categoryString = titleData["category"] as? String ?? "General"
            let confidence = titleData["confidence"] as? Double ?? 0.85
            
            return TitleItem(
                text: text,
                confidence: confidence,
                category: TitleItem.TitleCategory(rawValue: categoryString) ?? .general
            )
        }
        
        let contentTypeString = arguments["contentType"] as? String ?? "General"
        let contentType = ContentType(rawValue: contentTypeString) ?? .general
        
        print("✅ OllamaService: Successfully parsed Magistral complete analysis")
        return (summary, tasks, reminders, titles, contentType)
    }
    
    // MARK: - Tool Calling Core Method
    
    private func generateResponseWithTools(prompt: String, model: String, tools: [OllamaTool]) async throws -> OllamaGenerateResponse {
        guard isConnected else {
            throw OllamaError.notConnected
        }
        
        let url = URL(string: "\(config.baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let generateRequest = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: nil,  // Don't force JSON format when using tools
            options: OllamaOptions(
                num_predict: config.maxTokens,
                temperature: 0.1,  // Lower temperature for more consistent tool calling
                top_p: 0.8,
                top_k: 20
            ),
            tools: tools,
            think: false  // Disable thinking for tool calling to get direct responses
        )
        
        request.httpBody = try generateRequest.toJSONData()
        
        Self.requestCounter += 1
        print("🔧 OllamaService: Sending tool calling request with \(tools.count) tools")
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("❌ OllamaService: Tool calling network request failed: \(error.localizedDescription)")
            throw OllamaError.serverError("Network request failed: \(error.localizedDescription)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ OllamaService: Invalid HTTP response type")
            throw OllamaError.serverError("Invalid HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            print("❌ OllamaService: HTTP error - Status: \(httpResponse.statusCode)")
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ OllamaService: Error response body: \(errorData)")
            }
            throw OllamaError.serverError("Server returned status code \(httpResponse.statusCode)")
        }
        
        // Check if we have valid data first
        guard !data.isEmpty else {
            print("❌ OllamaService: Received empty response data")
            throw OllamaError.parsingError("Received empty response from server")
        }
        
        print("📊 OllamaService: Received tool calling response data of \(data.count) bytes")
        
        do {
            let generateResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            
            print("✅ OllamaService: Successfully decoded tool calling response")
            if let toolCalls = generateResponse.tool_calls {
                print("🔧 OllamaService: Received \(toolCalls.count) tool calls")
            } else {
                print("⚠️ OllamaService: No tool calls in response")
            }
            
            return generateResponse
        } catch {
            print("❌ OllamaService: Tool calling JSON parsing failed: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            
            // Try to decode raw response for better error diagnostics
            if let rawResponse = String(data: data, encoding: .utf8) {
                print("❌ OllamaService: Raw response that failed to parse: \(rawResponse)")
            }
            
            throw OllamaError.parsingError("Failed to parse tool calling JSON response: \(error.localizedDescription)")
        }
    }
    
    private func generateResponse(prompt: String, model: String, cleanForJSON: Bool = true) async throws -> String {
        guard isConnected else {
            throw OllamaError.notConnected
        }
        
        let url = URL(string: "\(config.baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let shouldUseThinking = supportsThinking(model) && !cleanForJSON
        
        let generateRequest = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: cleanForJSON ? .json : nil,
            options: OllamaOptions(
                num_predict: config.maxTokens,
                temperature: cleanForJSON ? 0.0 : 0.3,  // Use 0.0 for deterministic structured outputs
                top_p: cleanForJSON ? 0.8 : 0.95,       // Higher top_p for more diverse summaries
                top_k: cleanForJSON ? 20 : 50           // More token choices for summaries
            ),
            tools: nil,  // No tools for traditional prompting
            think: shouldUseThinking  // Enable thinking for supported models when not generating JSON
        )
        
        request.httpBody = try generateRequest.toJSONData()
        
        Self.requestCounter += 1
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("❌ OllamaService: Network request failed: \(error.localizedDescription)")
            throw OllamaError.serverError("Network request failed: \(error.localizedDescription)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ OllamaService: Invalid HTTP response type")
            throw OllamaError.serverError("Invalid HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            print("❌ OllamaService: HTTP error - Status: \(httpResponse.statusCode)")
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ OllamaService: Error response body: \(errorData)")
            }
            throw OllamaError.serverError("Server returned status code \(httpResponse.statusCode)")
        }
        
        
        // Check if we have valid data first
        guard !data.isEmpty else {
            print("❌ OllamaService: Received empty response data")
            throw OllamaError.parsingError("Received empty response from server")
        }
        
        print("📊 OllamaService: Received response data of \(data.count) bytes")
        
        do {
            let generateResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            
            print("✅ OllamaService: Successfully decoded Ollama response")
            print("📝 OllamaService: Raw response content: '\(generateResponse.response)'")
            print("🏁 OllamaService: Response done: \(generateResponse.done)")
            
            // Clean up the response based on the expected format
            let cleanedResponse = cleanForJSON ? cleanOllamaResponse(generateResponse.response) : cleanSummaryResponse(generateResponse.response)
            
            print("🧹 OllamaService: Cleaned response: '\(cleanedResponse)'")
            
            return cleanedResponse
        } catch {
            print("❌ OllamaService: JSON parsing failed: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            
            // Try to decode raw response for better error diagnostics
            if let rawResponse = String(data: data, encoding: .utf8) {
                print("❌ OllamaService: Raw response that failed to parse: \(rawResponse)")
                
                // Check if this looks like a streaming response that wasn't properly handled
                if rawResponse.contains("\"done\":false") {
                    print("⚠️ OllamaService: Detected streaming response - this might be the issue")
                }
            }
            
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription). Raw response: \(String(data: data, encoding: .utf8) ?? "Unable to decode raw response")")
        }
    }
    
    // MARK: - Structured Output Generation
    
    private func generateStructuredResponse(prompt: String, model: String, schema: [String: Any]) async throws -> String {
        guard isConnected else {
            throw OllamaError.notConnected
        }
        
        let url = URL(string: "\(config.baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let generateRequest = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            format: .schema(schema),
            options: OllamaOptions(
                num_predict: config.maxTokens,
                temperature: 0.0,  // Deterministic output for structured responses
                top_p: 0.8,        // Lower top_p for more focused responses
                top_k: 20          // Fewer choices for more consistent output
            ),
            tools: nil,  // No tools when using structured outputs
            think: false  // Disable thinking for structured outputs to ensure clean JSON
        )
        
        request.httpBody = try generateRequest.toJSONData()
        
        Self.requestCounter += 1
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            print("❌ OllamaService: Structured output network request failed: \(error.localizedDescription)")
            throw OllamaError.serverError("Network request failed: \(error.localizedDescription)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ OllamaService: Invalid HTTP response type")
            throw OllamaError.serverError("Invalid HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            print("❌ OllamaService: HTTP error - Status: \(httpResponse.statusCode)")
            if let errorData = String(data: data, encoding: .utf8) {
                print("❌ OllamaService: Error response body: \(errorData)")
            }
            throw OllamaError.serverError("Server returned status code \(httpResponse.statusCode)")
        }
        
        guard !data.isEmpty else {
            print("❌ OllamaService: Received empty response data")
            throw OllamaError.parsingError("Received empty response from server")
        }
        
        print("📊 OllamaService: Received structured response data of \(data.count) bytes")
        
        do {
            let generateResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            
            print("✅ OllamaService: Successfully decoded structured Ollama response")
            print("📝 OllamaService: Structured response content: '\(generateResponse.response.prefix(200))...'")
            print("🏁 OllamaService: Response done: \(generateResponse.done)")
            
            // For structured outputs, we expect valid JSON without need for cleaning
            return generateResponse.response
            
        } catch {
            print("❌ OllamaService: Structured output JSON parsing failed: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            
            if let rawResponse = String(data: data, encoding: .utf8) {
                print("❌ OllamaService: Raw structured response that failed to parse: \(rawResponse)")
            }
            
            throw OllamaError.parsingError("Failed to parse structured JSON response: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Structured Output Helper Methods
    
    private func createStructuredCompleteProcessingPrompt(from text: String) -> String {
        return """
        You are an AI assistant that analyzes transcripts and extracts structured information. Analyze the following transcript and provide a comprehensive response.
        
        **CRITICAL FIELD INSTRUCTIONS:**
        
        **summary**: This should contain the MAIN COMPREHENSIVE SUMMARY of the entire transcript. This is the most important field and should be 15-20% of the original transcript length. Include:
        - Complete overview of the discussion/content
        - Key points, insights, and takeaways  
        - Main themes and conclusions
        - Use proper Markdown formatting (## headers, **bold**, • bullets)
        - This should be substantial and detailed, not just a brief overview
        
        **tasks**: Extract ONLY specific, actionable tasks that require follow-up. These should be:
        - Concrete action items mentioned in the transcript
        - Things someone needs to do or complete
        - NOT general statements or observations
        - Keep each task description concise and specific
        
        **reminders**: Extract ONLY time-sensitive items like:
        - Deadlines, appointments, scheduled events
        - Things that need to be remembered at specific times
        - NOT general information without time constraints
        
        **titles**: Generate 3-4 descriptive titles that capture main topics (40-60 characters each)
        
        **contentType**: Classify as Meeting, Personal, Technical, or General
        
        **REMEMBER**: The summary field should contain the bulk of the detailed content, not the tasks field.
        
        Transcript to analyze:
        \(text)
        """
    }
    
    private func parseStructuredCompleteResponse(_ response: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        guard let data = response.data(using: .utf8) else {
            throw OllamaError.parsingError("Failed to convert structured response to data")
        }
        
        do {
            let rawResult = try JSONDecoder().decode(RawCompleteResult.self, from: data)
            
            // Convert raw results to proper objects with higher confidence for structured outputs
            let tasks = rawResult.tasks.map { rawTask in
                TaskItem(
                    text: rawTask.text,
                    priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                    timeReference: rawTask.timeReference,
                    category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                    confidence: 0.95  // Higher confidence for structured outputs
                )
            }
            
            let reminders = rawResult.reminders.map { rawReminder in
                ReminderItem(
                    text: rawReminder.text,
                    timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                    urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                    confidence: 0.95  // Higher confidence for structured outputs
                )
            }
            
            let titles = rawResult.titles.map { rawTitle in
                TitleItem(
                    text: rawTitle.text,
                    confidence: rawTitle.confidence,
                    category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                )
            }
            
            let contentType = ContentType(rawValue: rawResult.contentType) ?? .general
            
            print("✅ OllamaService: Successfully parsed structured complete result")
            print("📊 Summary: \(rawResult.summary.count) chars, Tasks: \(tasks.count), Reminders: \(reminders.count), Titles: \(titles.count)")
            
            return (rawResult.summary, tasks, reminders, titles, contentType)
            
        } catch {
            print("❌ OllamaService: Structured JSON parsing failed: \(error)")
            throw OllamaError.parsingError("Failed to parse structured JSON response: \(error.localizedDescription)")
        }
    }
    
    private func parseStructuredTasksReminders(_ response: String) throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        guard let data = response.data(using: .utf8) else {
            throw OllamaError.parsingError("Failed to convert structured tasks/reminders response to data")
        }
        
        do {
            let rawResult = try JSONDecoder().decode(RawTaskReminderResult.self, from: data)
            
            let tasks = rawResult.tasks.map { rawTask in
                TaskItem(
                    text: rawTask.text,
                    priority: TaskItem.Priority(rawValue: rawTask.priority) ?? .medium,
                    timeReference: rawTask.timeReference,
                    category: TaskItem.TaskCategory(rawValue: rawTask.category) ?? .general,
                    confidence: 0.95  // Higher confidence for structured outputs
                )
            }
            
            let reminders = rawResult.reminders.map { rawReminder in
                ReminderItem(
                    text: rawReminder.text,
                    timeReference: ReminderItem.TimeReference(originalText: rawReminder.timeReference ?? ""),
                    urgency: ReminderItem.Urgency(rawValue: rawReminder.urgency) ?? .later,
                    confidence: 0.95  // Higher confidence for structured outputs
                )
            }
            
            print("✅ OllamaService: Successfully parsed structured tasks/reminders")
            return (tasks, reminders)
            
        } catch {
            print("❌ OllamaService: Structured tasks/reminders parsing failed: \(error)")
            throw OllamaError.parsingError("Failed to parse structured tasks/reminders: \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting Structures

struct RawTaskReminderResult: Codable {
    let tasks: [RawTaskItem]
    let reminders: [RawReminderItem]
}

struct RawTitleResult: Codable {
    let titles: [RawTitleItem]
}

struct RawCompleteResult: Codable {
    let summary: String
    let tasks: [RawTaskItem]
    let reminders: [RawReminderItem]
    let titles: [RawTitleItem]
    let contentType: String
}

struct RawTaskItem: Codable {
    let text: String
    let priority: String
    let category: String
    let timeReference: String?
}

struct RawReminderItem: Codable {
    let text: String
    let urgency: String
    let timeReference: String?
}

struct RawTitleItem: Codable {
    let text: String
    let category: String
    let confidence: Double
}

// MARK: - Errors

enum OllamaError: Error, LocalizedError {
    case notConnected
    case serverError(String)
    case parsingError(String)
    case modelNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Ollama server"
        case .serverError(let message):
            return "Server error: \(message)"
        case .parsingError(let message):
            return "Parsing error: \(message)"
        case .modelNotFound(let model):
            return "Model '\(model)' not found on server"
        }
    }
} 