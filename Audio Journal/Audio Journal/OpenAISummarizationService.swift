//
//  OpenAISummarizationService.swift
//  Audio Journal
//
//  OpenAI Chat Completions API service for AI summarization
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
            return "Most capable model with advanced reasoning and comprehensive analysis"
        case .gpt41Mini:
            return "Balanced performance and cost, suitable for most summarization tasks"
        case .gpt41Nano:
            return "Fast and cost-effective for basic summarization needs"
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

struct OpenAISummarizationConfig {
    let apiKey: String
    let model: OpenAISummarizationModel
    let baseURL: String
    let temperature: Double
    let maxTokens: Int
    let timeout: TimeInterval
    
    static let `default` = OpenAISummarizationConfig(
        apiKey: "",
        model: .gpt41Mini,
        baseURL: "https://api.openai.com/v1",
        temperature: 0.1,
        maxTokens: 2048,
        timeout: 60.0
    )
    
    init(apiKey: String, model: OpenAISummarizationModel, baseURL: String = "https://api.openai.com/v1", temperature: Double = 0.1, maxTokens: Int? = nil, timeout: TimeInterval = 60.0) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.temperature = temperature
        self.maxTokens = maxTokens ?? model.maxTokens
        self.timeout = timeout
    }
}

// MARK: - OpenAI API Request/Response Models

struct OpenAIChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxCompletionTokens: Int
    let stream: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxCompletionTokens = "max_completion_tokens"
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
    let choices: [ChatChoice]
    let usage: Usage?
    
    struct ChatChoice: Codable {
        let index: Int
        let message: ChatMessage
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case index, message
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
}

// OpenAIErrorResponse is already defined in OpenAITranscribeService.swift

// MARK: - OpenAI Summarization Service

class OpenAISummarizationService {
    private let config: OpenAISummarizationConfig
    private let session: URLSession
    
    init(config: OpenAISummarizationConfig) {
        self.config = config
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout * 2
        self.session = URLSession(configuration: configuration)
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async throws {
        let messages = [
            ChatMessage(role: "system", content: "You are a helpful assistant."),
            ChatMessage(role: "user", content: "Hello! This is a connection test.")
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 50
        )
        
        _ = try await makeAPICall(request: request)
    }
    
    // MARK: - Summary Generation
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let systemPrompt = createSystemPrompt(for: .summary, contentType: contentType)
        let userPrompt = """
        Please provide a comprehensive summary of the following content:

        \(text)
        """
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        return choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Task Extraction
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        let systemPrompt = createSystemPrompt(for: .tasks, contentType: .general)
        let userPrompt = """
        Please extract all actionable tasks from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "task description",
                "priority": "high|medium|low",
                "category": "call|meeting|purchase|research|email|travel|health|general",
                "timeReference": "today|tomorrow|this week|next week|specific date or null",
                "confidence": 0.85
            }
        ]

        Content:
        \(text)
        """
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 1024
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        return try parseTasksFromJSON(choice.message.content)
    }
    
    // MARK: - Reminder Extraction
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let systemPrompt = createSystemPrompt(for: .reminders, contentType: .general)
        let userPrompt = """
        Please extract all reminders and time-sensitive items from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "reminder description",
                "urgency": "immediate|today|thisWeek|later",
                "timeReference": "specific time or date mentioned",
                "confidence": 0.85
            }
        ]

        Content:
        \(text)
        """
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 1024
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        return try parseRemindersFromJSON(choice.message.content)
    }
    
    // MARK: - Content Classification
    
    func classifyContent(_ text: String) async throws -> ContentType {
        let systemPrompt = """
        You are a content classifier. Analyze the provided text and classify it into one of these categories:
        - meeting: Meeting transcripts, discussions, team calls
        - personalJournal: Personal thoughts, diary entries, reflections
        - technical: Technical documentation, code discussions, tutorials
        - general: General content that doesn't fit other categories
        
        Respond with only the category name.
        """
        
        let userPrompt = "Classify this content:\n\n\(text.prefix(1000))"
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 10
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            return .general
        }
        
        let classification = choice.message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        switch classification {
        case "meeting":
            return .meeting
        case "personaljournal":
            return .personalJournal
        case "technical":
            return .technical
        default:
            return .general
        }
    }
    
    // MARK: - Complete Processing
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        // First classify the content
        let contentType = try await classifyContent(text)
        
        // Create a comprehensive prompt for all tasks
        let systemPrompt = createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = """
        Please analyze the following content and provide a comprehensive response in JSON format with the following structure:
        {
            "summary": "A detailed summary of the content",
            "tasks": [
                {
                    "text": "task description",
                    "priority": "high|medium|low",
                    "category": "call|meeting|purchase|research|email|travel|health|general",
                    "timeReference": "today|tomorrow|this week|next week|specific date or null",
                    "confidence": 0.85
                }
            ],
            "reminders": [
                {
                    "text": "reminder description",
                    "urgency": "immediate|today|thisWeek|later",
                    "timeReference": "specific time or date mentioned",
                    "confidence": 0.85
                }
            ]
        }

        Content:
        \(text)
        """
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        let result = try parseCompleteResponseFromJSON(choice.message.content)
        return (result.summary, result.tasks, result.reminders, contentType)
    }
    
    // MARK: - Private Helper Methods
    
    private func makeAPICall(request: OpenAIChatCompletionRequest) async throws -> OpenAIChatCompletionResponse {
        guard !config.apiKey.isEmpty else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API key not configured")
        }
        
        let url = URL(string: "\(config.baseURL)/chat/completions")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid response from OpenAI")
        }
        
        if httpResponse.statusCode != 200 {
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                throw SummarizationError.aiServiceUnavailable(service: "OpenAI API Error: \(errorResponse.error.message)")
            } else {
                throw SummarizationError.aiServiceUnavailable(service: "OpenAI API Error: HTTP \(httpResponse.statusCode)")
            }
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(OpenAIChatCompletionResponse.self, from: data)
    }
    
    private func createSystemPrompt(for task: PromptTask, contentType: ContentType) -> String {
        let basePrompt = "You are an expert AI assistant specialized in analyzing and summarizing content."
        
        let contentContext = switch contentType {
        case .meeting:
            "This content is from a meeting or discussion. Focus on decisions, action items, and key discussion points."
        case .personalJournal:
            "This content is from a personal journal or reflection. Focus on insights, emotions, and personal experiences."
        case .technical:
            "This content is technical in nature. Focus on concepts, solutions, and important technical details."
        case .general:
            "This is general content. Provide a balanced analysis of the main points."
        }
        
        let taskSpecific = switch task {
        case .summary:
            "Provide a comprehensive, well-structured summary using markdown formatting. Use bullet points, headers, and emphasis where appropriate."
        case .tasks:
            "Focus on identifying actionable items, tasks, and things that need to be done. Be specific about priorities and timeframes."
        case .reminders:
            "Focus on time-sensitive items, deadlines, appointments, and things to remember. Pay attention to dates and urgency."
        case .complete:
            "Provide a comprehensive analysis including summary, tasks, and reminders. Use clear, structured formatting."
        }
        
        return "\(basePrompt) \(contentContext) \(taskSpecific)"
    }
    
    private enum PromptTask {
        case summary, tasks, reminders, complete
    }
    
    // MARK: - JSON Parsing
    
    private func parseTasksFromJSON(_ jsonString: String) throws -> [TaskItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct TaskResponse: Codable {
            let text: String
            let priority: String?
            let category: String?
            let timeReference: String?
            let confidence: Double?
        }
        
        let taskResponses = try JSONDecoder().decode([TaskResponse].self, from: data)
        
        return taskResponses.map { response in
            TaskItem(
                text: response.text,
                priority: TaskItem.Priority(rawValue: response.priority?.lowercased() ?? "medium") ?? .medium,
                timeReference: response.timeReference,
                category: TaskItem.TaskCategory(rawValue: response.category?.lowercased() ?? "general") ?? .general,
                confidence: response.confidence ?? 0.8
            )
        }
    }
    
    private func parseRemindersFromJSON(_ jsonString: String) throws -> [ReminderItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct ReminderResponse: Codable {
            let text: String
            let urgency: String?
            let timeReference: String?
            let confidence: Double?
        }
        
        let reminderResponses = try JSONDecoder().decode([ReminderResponse].self, from: data)
        
        return reminderResponses.map { response in
            let urgency = ReminderItem.Urgency(rawValue: response.urgency?.lowercased() ?? "later") ?? .later
            let timeRef = ReminderItem.TimeReference(originalText: response.timeReference ?? "No time specified")
            
            return ReminderItem(
                text: response.text,
                timeReference: timeRef,
                urgency: urgency,
                confidence: response.confidence ?? 0.8
            )
        }
    }
    
    private func parseCompleteResponseFromJSON(_ jsonString: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem]) {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct CompleteResponse: Codable {
            let summary: String
            let tasks: [TaskResponse]
            let reminders: [ReminderResponse]
            
            struct TaskResponse: Codable {
                let text: String
                let priority: String?
                let category: String?
                let timeReference: String?
                let confidence: Double?
            }
            
            struct ReminderResponse: Codable {
                let text: String
                let urgency: String?
                let timeReference: String?
                let confidence: Double?
            }
        }
        
        let response = try JSONDecoder().decode(CompleteResponse.self, from: data)
        
        let tasks = response.tasks.map { taskResponse in
            TaskItem(
                text: taskResponse.text,
                priority: TaskItem.Priority(rawValue: taskResponse.priority?.lowercased() ?? "medium") ?? .medium,
                timeReference: taskResponse.timeReference,
                category: TaskItem.TaskCategory(rawValue: taskResponse.category?.lowercased() ?? "general") ?? .general,
                confidence: taskResponse.confidence ?? 0.8
            )
        }
        
        let reminders = response.reminders.map { reminderResponse in
            let urgency = ReminderItem.Urgency(rawValue: reminderResponse.urgency?.lowercased() ?? "later") ?? .later
            let timeRef = ReminderItem.TimeReference(originalText: reminderResponse.timeReference ?? "No time specified")
            
            return ReminderItem(
                text: reminderResponse.text,
                timeReference: timeRef,
                urgency: urgency,
                confidence: reminderResponse.confidence ?? 0.8
            )
        }
        
        return (response.summary, tasks, reminders)
    }
    
    private func extractJSONFromResponse(_ response: String) -> String {
        // Remove markdown code blocks if present
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Find JSON array or object
        if let startIndex = cleaned.firstIndex(of: "[") ?? cleaned.firstIndex(of: "{") {
            let substring = String(cleaned[startIndex...])
            return substring
        }
        
        return cleaned
    }
}