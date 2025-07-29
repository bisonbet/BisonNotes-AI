//
//  OpenAISummarizationService.swift
//  Audio Journal
//
//  OpenAI Chat Completions API service for AI summarization
//

import Foundation

// MARK: - OpenAI Models for Summarization

enum OpenAISummarizationModel: String, CaseIterable {
    case gpt4 = "gpt-4"
    case gpt4Turbo = "gpt-4-turbo"
    case gpt35Turbo = "gpt-3.5-turbo"
    case gpt41 = "gpt-4.1"
    case gpt41Mini = "gpt-4.1-mini"
    case gpt41Nano = "gpt-4.1-nano"
    
    var displayName: String {
        switch self {
        case .gpt4:
            return "GPT-4"
        case .gpt4Turbo:
            return "GPT-4 Turbo"
        case .gpt35Turbo:
            return "GPT-3.5 Turbo"
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
        case .gpt4:
            return "Most powerful model with advanced reasoning capabilities"
        case .gpt4Turbo:
            return "Fast and efficient with good reasoning capabilities"
        case .gpt35Turbo:
            return "Fast and cost-effective for most tasks"
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
        case .gpt4:
            return 8192
        case .gpt4Turbo:
            return 4096
        case .gpt35Turbo:
            return 4096
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
        case .gpt4:
            return "Premium"
        case .gpt4Turbo:
            return "Premium"
        case .gpt35Turbo:
            return "Standard"
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

// OpenAIErrorResponse is defined in OpenAITranscribeService.swift

// MARK: - OpenAI Summarization Service

class OpenAISummarizationService {
    private let config: OpenAISummarizationConfig
    private let session: URLSession
    
    init(config: OpenAISummarizationConfig) {
        self.config = config
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = config.timeout
        configuration.timeoutIntervalForResource = config.timeout * 2
        configuration.waitsForConnectivity = true
        configuration.networkServiceType = .responsiveData
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldUsePipelining = false
        
        self.session = URLSession(configuration: configuration)
    }
    
    deinit {
        // Properly invalidate the session when the service is deallocated
        session.invalidateAndCancel()
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
        Please provide a comprehensive summary of the following content using proper Markdown formatting:

        Use the following Markdown elements as appropriate:
        - **Bold text** for key points and important information
        - *Italic text* for emphasis
        - ## Headers for main sections
        - ### Subheaders for subsections
        - • Bullet points for lists
        - 1. Numbered lists for sequential items
        - > Blockquotes for important quotes or statements
        - `Code formatting` for technical terms or specific names

        Content to summarize:
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
    
    // MARK: - Title Extraction
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        let systemPrompt = createSystemPrompt(for: .titles, contentType: .general)
        let userPrompt = """
        Please extract potential titles or headlines from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "title text",
                "category": "meeting|personal|technical|general",
                "confidence": 0.85
            }
        ]

        Focus on:
        - Main topics or themes discussed
        - Key decisions or outcomes
        - Important events or milestones
        - Central questions or problems addressed

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
        
        return try parseTitlesFromJSON(choice.message.content)
    }

    // MARK: - Complete Processing
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // First classify the content
        let contentType = try await classifyContent(text)
        
        // Create a comprehensive prompt for all tasks
        let systemPrompt = createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = """
        Please analyze the following content and provide a comprehensive response in VALID JSON format only. Do not include any text before or after the JSON. The response must be a single, well-formed JSON object with this exact structure:

        {
            "summary": "A detailed summary using Markdown formatting with **bold**, *italic*, ## headers, • bullet points, etc.",
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
            ],
            "titles": [
                {
                    "text": "title text",
                    "category": "meeting|personal|technical|general",
                    "confidence": 0.85
                }
            ]
        }

        IMPORTANT: 
        - Return ONLY valid JSON, no additional text or explanations
        - The "summary" field must use Markdown formatting: **bold**, *italic*, ## headers, • bullets, etc.
        - If no tasks are found, use an empty array: "tasks": []
        - If no reminders are found, use an empty array: "reminders": []
        - If no titles are found, use an empty array: "titles": []
        - Ensure all strings are properly quoted and escaped (especially for Markdown characters)
        - Do not include trailing commas
        - Escape special characters in JSON strings (quotes, backslashes, newlines)

        Content to analyze:
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
        return (result.summary, result.tasks, result.reminders, result.titles, contentType)
    }
    
    // MARK: - Private Helper Methods
    
    private func makeAPICall(request: OpenAIChatCompletionRequest) async throws -> OpenAIChatCompletionResponse {
        // Validate configuration before making API call
        guard !config.apiKey.isEmpty else {
            print("❌ OpenAI API key is empty")
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API key not configured")
        }
        
        guard config.apiKey.hasPrefix("sk-") else {
            print("❌ OpenAI API key format is invalid (should start with 'sk-')")
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API key format is invalid")
        }
        
        print("🔧 OpenAI API Configuration - Model: \(config.model.rawValue), BaseURL: \(config.baseURL)")
        print("🔑 API Key: \(String(config.apiKey.prefix(7)))...")
        
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid OpenAI base URL: \(config.baseURL)")
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("Audio Journal iOS App", forHTTPHeaderField: "User-Agent")
        
        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)
            
            // Log the request details for debugging
            if let requestBody = String(data: urlRequest.httpBody!, encoding: .utf8) {
                print("📤 OpenAI API Request Body: \(requestBody)")
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to encode request: \(error.localizedDescription)")
        }
        
        do {
            print("🌐 Making OpenAI API request...")
            let (data, response) = try await session.data(for: urlRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from OpenAI")
            }
            
            // Log the raw response for debugging
            let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("🌐 OpenAI API Response - Status: \(httpResponse.statusCode)")
            print("📝 Raw response: \(responseString)")
            print("📊 Response data length: \(data.count) bytes")
            
            if httpResponse.statusCode != 200 {
                // Try to parse error response
                if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                    print("❌ OpenAI API Error: \(errorResponse.error.message)")
                    throw SummarizationError.aiServiceUnavailable(service: "OpenAI API Error: \(errorResponse.error.message)")
                } else {
                    print("❌ OpenAI API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                    throw SummarizationError.aiServiceUnavailable(service: "OpenAI API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                }
            }
            
            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(OpenAIChatCompletionResponse.self, from: data)
            
            // Log the parsed response for debugging
            if let firstChoice = apiResponse.choices.first {
                let tokenCount = apiResponse.usage?.totalTokens ?? 0
                print("✅ OpenAI API Success - Model: \(apiResponse.model), Tokens: \(tokenCount)")
                print("📝 Response content length: \(firstChoice.message.content.count) characters")
            } else {
                print("⚠️ OpenAI API returned no choices")
            }
            
            return apiResponse
            
        } catch {
            print("🌐 Network error details: \(error)")
            if error is SummarizationError {
                throw error
            } else {
                throw SummarizationError.aiServiceUnavailable(service: "Network error: \(error.localizedDescription)")
            }
        }
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
            "Provide a comprehensive, well-structured summary using proper Markdown formatting. Use **bold** for key points, *italic* for emphasis, ## headers for sections, • bullet points for lists, and > blockquotes for important statements."
        case .tasks:
            "Focus on identifying actionable items, tasks, and things that need to be done. Be specific about priorities and timeframes."
        case .reminders:
            "Focus on time-sensitive items, deadlines, appointments, and things to remember. Pay attention to dates and urgency."
        case .titles:
            "Focus on identifying potential titles, headlines, or main themes from the content. Look for key topics, decisions, outcomes, or central themes that could serve as titles."
        case .complete:
            "Provide a comprehensive analysis including summary, tasks, reminders, and titles. The summary field must use Markdown formatting (**bold**, *italic*, ## headers, • bullets). You must respond with ONLY valid JSON format - no additional text, explanations, or formatting. Ensure proper JSON syntax with no trailing commas or syntax errors."
        }
        
        return "\(basePrompt) \(contentContext) \(taskSpecific)"
    }
    
    private enum PromptTask {
        case summary, tasks, reminders, titles, complete
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
        
        do {
            // Extract JSON from markdown code blocks if present
            let jsonString = extractJSONFromResponse(jsonString)
            let jsonData = jsonString.data(using: .utf8) ?? data
            
            let taskResponses = try JSONDecoder().decode([TaskResponse].self, from: jsonData)
            
            return taskResponses.map { response in
                TaskItem(
                    text: response.text,
                    priority: TaskItem.Priority(rawValue: response.priority?.lowercased() ?? "medium") ?? .medium,
                    timeReference: response.timeReference,
                    category: TaskItem.TaskCategory(rawValue: response.category?.lowercased() ?? "general") ?? .general,
                    confidence: response.confidence ?? 0.8
                )
            }
        } catch {
            print("❌ JSON parsing error for tasks: \(error)")
            print("📝 Raw JSON: \(cleanedJSON)")
            
            // Try to extract tasks from plain text as fallback
            return extractTasksFromPlainText(jsonString)
        }
    }
    
    private func extractTasksFromPlainText(_ text: String) -> [TaskItem] {
        // Fallback: extract tasks from plain text using simple pattern matching
        let lines = text.components(separatedBy: .newlines)
        var tasks: [TaskItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip JSON structure lines
            if trimmed.contains("{") || trimmed.contains("}") || 
               trimmed.contains("[") || trimmed.contains("]") ||
               trimmed.contains("\"tasks\"") || trimmed.contains("\"reminders\"") ||
               trimmed.contains("\"summary\"") || trimmed.contains("\"text\"") ||
               trimmed.contains("\"priority\"") || trimmed.contains("\"category\"") ||
               trimmed.contains("\"urgency\"") || trimmed.contains("\"confidence\"") ||
               trimmed.contains(":") && (trimmed.contains("\"") || trimmed.contains("null")) {
                continue
            }
            
            // Look for actual task content
            if trimmed.lowercased().contains("task") || 
               trimmed.lowercased().contains("todo") ||
               trimmed.lowercased().contains("action") ||
               trimmed.contains("•") || trimmed.contains("-") {
                
                let cleanText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty && cleanText.count > 5 && 
                   !cleanText.lowercased().contains("task") && // Avoid meta references
                   !cleanText.lowercased().contains("reminder") {
                    tasks.append(TaskItem(
                        text: cleanText,
                        priority: .medium,
                        timeReference: nil,
                        category: .general,
                        confidence: 0.6
                    ))
                }
            }
        }
        
        return tasks
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
        
        do {
            // Extract JSON from markdown code blocks if present
            let jsonString = extractJSONFromResponse(jsonString)
            let jsonData = jsonString.data(using: .utf8) ?? data
            
            let reminderResponses = try JSONDecoder().decode([ReminderResponse].self, from: jsonData)
            
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
        } catch {
            print("❌ JSON parsing error for reminders: \(error)")
            print("📝 Raw JSON: \(cleanedJSON)")
            
            // Try to extract reminders from plain text as fallback
            return extractRemindersFromPlainText(jsonString)
        }
    }
    
    private func extractRemindersFromPlainText(_ text: String) -> [ReminderItem] {
        // Fallback: extract reminders from plain text using simple pattern matching
        let lines = text.components(separatedBy: .newlines)
        var reminders: [ReminderItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip JSON structure lines
            if trimmed.contains("{") || trimmed.contains("}") || 
               trimmed.contains("[") || trimmed.contains("]") ||
               trimmed.contains("\"tasks\"") || trimmed.contains("\"reminders\"") ||
               trimmed.contains("\"summary\"") || trimmed.contains("\"text\"") ||
               trimmed.contains("\"priority\"") || trimmed.contains("\"category\"") ||
               trimmed.contains("\"urgency\"") || trimmed.contains("\"confidence\"") ||
               trimmed.contains(":") && (trimmed.contains("\"") || trimmed.contains("null")) {
                continue
            }
            
            // Look for actual reminder content
            if trimmed.lowercased().contains("remind") || 
               trimmed.lowercased().contains("remember") ||
               trimmed.lowercased().contains("deadline") ||
               trimmed.lowercased().contains("due") ||
               trimmed.contains("•") || trimmed.contains("-") {
                
                let cleanText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty && cleanText.count > 5 && 
                   !cleanText.lowercased().contains("reminder") && // Avoid meta references
                   !cleanText.lowercased().contains("task") {
                    let timeRef = ReminderItem.TimeReference(originalText: "No time specified")
                    reminders.append(ReminderItem(
                        text: cleanText,
                        timeReference: timeRef,
                        urgency: .later,
                        confidence: 0.6
                    ))
                }
            }
        }
        
        return reminders
    }
    
    private func parseTitlesFromJSON(_ jsonString: String) throws -> [TitleItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct TitleResponse: Codable {
            let text: String
            let category: String?
            let confidence: Double?
        }
        
        do {
            let titleResponses = try JSONDecoder().decode([TitleResponse].self, from: data)
            
            return titleResponses.map { response in
                let category = TitleItem.TitleCategory(rawValue: response.category?.lowercased() ?? "general") ?? .general
                return TitleItem(
                    text: response.text,
                    confidence: response.confidence ?? 0.8,
                    category: category
                )
            }
        } catch {
            print("❌ JSON parsing error for titles: \(error)")
            print("📝 Raw JSON: \(cleanedJSON)")
            
            // Try to extract titles from plain text as fallback
            return extractTitlesFromPlainText(jsonString)
        }
    }
    
    private func extractTitlesFromPlainText(_ text: String) -> [TitleItem] {
        // Fallback: extract titles from plain text using simple pattern matching
        let lines = text.components(separatedBy: .newlines)
        var titles: [TitleItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip JSON structure lines
            if trimmed.contains("{") || trimmed.contains("}") || 
               trimmed.contains("[") || trimmed.contains("]") ||
               trimmed.contains("\"tasks\"") || trimmed.contains("\"reminders\"") ||
               trimmed.contains("\"summary\"") || trimmed.contains("\"text\"") ||
               trimmed.contains("\"priority\"") || trimmed.contains("\"category\"") ||
               trimmed.contains("\"urgency\"") || trimmed.contains("\"confidence\"") ||
               trimmed.contains(":") && (trimmed.contains("\"") || trimmed.contains("null")) {
                continue
            }
            
            // Look for actual title content
            if trimmed.count > 10 && 
               trimmed.lowercased().contains("title") || 
               trimmed.lowercased().contains("headline") ||
               trimmed.lowercased().contains("topic") ||
               trimmed.lowercased().contains("subject") {
                
                let cleanText = trimmed
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty && cleanText.count > 5 && 
                   !cleanText.lowercased().contains("title") && // Avoid meta references
                   !cleanText.lowercased().contains("reminder") &&
                   !cleanText.lowercased().contains("task") {
                    titles.append(TitleItem(
                        text: cleanText,
                        confidence: 0.6,
                        category: .general
                    ))
                }
            }
        }
        
        return titles
    }
    
    private func parseCompleteResponseFromJSON(_ jsonString: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct CompleteResponse: Codable {
            let summary: String
            let tasks: [TaskResponse]
            let reminders: [ReminderResponse]
            let titles: [TitleResponse]
            
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
            
            struct TitleResponse: Codable {
                let text: String
                let category: String?
                let confidence: Double?
            }
        }
        
        do {
            // Extract JSON from markdown code blocks if present
            let jsonString = extractJSONFromResponse(jsonString)
            let jsonData = jsonString.data(using: .utf8) ?? data
            
            let response = try JSONDecoder().decode(CompleteResponse.self, from: jsonData)
            
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
            
            let titles = response.titles.map { titleResponse in
                let category = TitleItem.TitleCategory(rawValue: titleResponse.category?.lowercased() ?? "general") ?? .general
                return TitleItem(
                    text: titleResponse.text,
                    confidence: titleResponse.confidence ?? 0.8,
                    category: category
                )
            }
            
            return (response.summary, tasks, reminders, titles)
        } catch {
            print("❌ JSON parsing error for complete response: \(error)")
            print("📝 Raw JSON: \(cleanedJSON)")
            
            // Check if the JSON is empty or malformed
            if cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("⚠️ Empty JSON response received from OpenAI")
                throw SummarizationError.aiServiceUnavailable(service: "OpenAI returned empty response")
            }
            
            if cleanedJSON == "{}" {
                print("⚠️ OpenAI returned empty JSON object - this may indicate an API configuration issue")
                throw SummarizationError.aiServiceUnavailable(service: "OpenAI returned empty JSON - check API key and model configuration")
            }
            
            // Fallback: try to extract information from plain text
            let summary = extractSummaryFromPlainText(jsonString)
            let tasks = extractTasksFromPlainText(jsonString)
            let reminders = extractRemindersFromPlainText(jsonString)
            let titles = extractTitlesFromPlainText(jsonString)
            
            return (summary, tasks, reminders, titles)
        }
    }
    
    private func extractSummaryFromPlainText(_ text: String) -> String {
        // First, try to extract JSON summary field if present
        if let jsonSummary = extractSummaryFromJSON(text) {
            return jsonSummary
        }
        
        // Try to find a summary in the text
        let lines = text.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && 
               !trimmed.lowercased().contains("task") &&
               !trimmed.lowercased().contains("reminder") &&
               !trimmed.contains("{") && !trimmed.contains("}") &&
               !trimmed.contains("[") && !trimmed.contains("]") &&
               !trimmed.contains("\"summary\"") && // Skip JSON structure lines
               trimmed.count > 20 {
                summaryLines.append(trimmed)
            }
        }
        
        let summary = summaryLines.joined(separator: "\n\n")
        
        // Add basic markdown formatting to the fallback summary
        if summary.isEmpty {
            return "## Summary\n\n*Unable to generate summary from the provided content.*"
        } else {
            // Add a header and format as markdown
            let formattedSummary = "## Summary\n\n" + summary
                .replacingOccurrences(of: ". ", with: ".\n\n• ")
                .replacingOccurrences(of: "• • ", with: "• ")
            return formattedSummary
        }
    }
    
    private func extractSummaryFromJSON(_ text: String) -> String? {
        // Try to extract the summary field from JSON
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for "summary": "..." pattern
            if trimmed.contains("\"summary\"") && trimmed.contains(":") {
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    let afterColon = String(trimmed[trimmed.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    
                    // Remove quotes if present
                    if afterColon.hasPrefix("\"") && afterColon.hasSuffix("\"") {
                        let startIndex = afterColon.index(after: afterColon.startIndex)
                        let endIndex = afterColon.index(before: afterColon.endIndex)
                        return String(afterColon[startIndex..<endIndex])
                    } else if afterColon.hasPrefix("\"") {
                        // Handle multi-line summary
                        let startIndex = afterColon.index(after: afterColon.startIndex)
                        var summaryContent = String(afterColon[startIndex...])
                        
                        // Find the closing quote
                        if let closingQuoteIndex = summaryContent.firstIndex(of: "\"") {
                            summaryContent = String(summaryContent[..<closingQuoteIndex])
                        }
                        
                        return summaryContent
                    }
                }
            }
        }
        
        return nil
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
            
            // Try to find the end of the JSON object/array to avoid trailing content
            var braceCount = 0
            var bracketCount = 0
            var inString = false
            var escapeNext = false
            var endIndex = substring.startIndex
            
            for (index, char) in substring.enumerated() {
                let currentIndex = substring.index(substring.startIndex, offsetBy: index)
                
                if escapeNext {
                    escapeNext = false
                    continue
                }
                
                if char == "\\" {
                    escapeNext = true
                    continue
                }
                
                if char == "\"" {
                    inString.toggle()
                    continue
                }
                
                if !inString {
                    switch char {
                    case "{":
                        braceCount += 1
                    case "}":
                        braceCount -= 1
                    case "[":
                        bracketCount += 1
                    case "]":
                        bracketCount -= 1
                    default:
                        break
                    }
                    
                    // If we've closed all braces and brackets, we've found the end
                    if braceCount == 0 && bracketCount == 0 && index > 0 {
                        endIndex = substring.index(currentIndex, offsetBy: 1)
                        break
                    }
                }
            }
            
            let extractedJSON = String(substring[..<endIndex])
            
            // Additional validation: ensure it looks like valid JSON
            if extractedJSON.contains("\"summary\"") || 
               extractedJSON.contains("\"tasks\"") || 
               extractedJSON.contains("\"reminders\"") ||
               extractedJSON.contains("\"titles\"") {
                return extractedJSON
            } else {
                // If it doesn't look like our expected JSON structure, return empty
                return "{}"
            }
        }
        
        return cleaned
    }
}