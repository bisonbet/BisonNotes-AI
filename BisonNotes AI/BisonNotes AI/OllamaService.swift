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

struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: OllamaOptions?
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
            let (_, response) = try await session.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                let success = httpResponse.statusCode == 200
                await MainActor.run {
                    self.isConnected = success
                    self.connectionError = success ? nil : "Server returned status code \(httpResponse.statusCode)"
                }
                return success
            }
            
            await MainActor.run {
                self.isConnected = false
                self.connectionError = "Invalid response from server"
            }
            return false
            
        } catch {
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
        // Try to find JSON object in the response
        let jsonPattern = #"\{[\s\S]*\}"#
        if let match = response.range(of: jsonPattern, options: .regularExpression) {
            let jsonString = String(response[match])
            if isValidJSON(jsonString) {
                return jsonString
            }
        }
        
        // If no valid JSON found, return empty JSON structure
        print("⚠️ OllamaService: Could not extract valid JSON from response, returning empty structure")
        
        // Determine which type of JSON structure to return based on the context
        if response.contains("titles") || response.contains("title") {
            return "{\"titles\":[]}"
        } else {
            return "{\"tasks\":[],\"reminders\":[]}"
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
    
    func generateSummary(from text: String) async throws -> String {
        let prompt = """
        Please provide a comprehensive summary of the following transcript (aim for 15-20% of the original transcript length). Focus on the main points, key decisions, and important information.

        **Format your response using markdown:**
        - Use **bold** for emphasis on key points
        - Use *italic* for secondary emphasis
        - Use ## headers for main sections
        - Use bullet points for lists
        - Use proper paragraph breaks
        - Keep formatting clean and readable
        - Balance comprehensiveness with conciseness

        Transcript:
        \(text)

        **Summary:**
        """
        
        return try await generateResponse(prompt: prompt, model: config.modelName, cleanForJSON: false)
    }
    
    func generateTitle(from text: String) async throws -> String {
        let prompt = RecordingNameGenerator.generateStandardizedTitlePrompt(from: text)
        
        print("🔧 OllamaService: Sending title generation request")
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        print("🔧 OllamaService: Generated title: \(response)")
        
        // Clean up the response and ensure it's a good title
        let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(response)
        print("🔧 OllamaService: Cleaned title: \(cleanedTitle)")
        
        return cleanedTitle
    }
    
    func extractTasksAndReminders(from text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        let prompt = """
        You are a JSON generator. Your ONLY job is to output valid JSON. Do not include any other text, explanations, or markdown formatting.

        Analyze the following transcript and extract any tasks, to-dos, or reminders mentioned. For each item found, provide:
        1. A brief description (under 50 words)
        2. Priority level (High, Medium, Low)
        3. If a date/time is mentioned, include it
        4. Categorize as either a task or reminder

        **CRITICAL: You must respond with ONLY valid JSON in this exact format:**
        {
          "tasks": [
            {
              "text": "task description",
              "priority": "High|Medium|Low",
              "category": "Call|Email|Meeting|Purchase|Research|Travel|Health|General",
              "timeReference": "time reference if mentioned, otherwise null"
            }
          ],
          "reminders": [
            {
              "text": "reminder description", 
              "urgency": "Immediate|Today|This Week|Later",
              "timeReference": "time reference if mentioned, otherwise null"
            }
          ]
        }

        Rules:
        - Output ONLY the JSON object, nothing else
        - Do not include any explanatory text
        - Do not use markdown formatting
        - Only include items with 80% or higher confidence
        - If no tasks or reminders are found, return empty arrays
        - Ensure all JSON is properly escaped

        Transcript:
        \(text)
        """
        
        print("🔧 OllamaService: Sending tasks/reminders extraction request")
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        print("🔧 OllamaService: Received response for tasks/reminders (\(response.count) chars)")
        
        // Parse JSON response
        guard let data = response.data(using: .utf8) else {
            throw OllamaError.parsingError("Failed to convert response to data")
        }
        
        do {
            print("🔧 OllamaService: Attempting to parse JSON response for tasks/reminders")
            let rawResult = try JSONDecoder().decode(RawTaskReminderResult.self, from: data)
            
            print("✅ OllamaService: Successfully parsed tasks/reminders JSON")
            print("🔧 OllamaService: Found \(rawResult.tasks.count) tasks and \(rawResult.reminders.count) reminders")
            
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
            
            return (tasks, reminders)
        } catch {
            print("❌ OllamaService: JSON parsing failed for tasks/reminders: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription)")
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        let prompt = """
        You are a JSON generator. Your ONLY job is to output valid JSON. Do not include any other text, explanations, or markdown formatting.

        Analyze the following transcript and extract 4 high-quality titles or headlines. Focus on:
        - Main topics or themes discussed
        - Key decisions or outcomes
        - Important events or milestones
        - Central questions or problems addressed

        **CRITICAL: You must respond with ONLY valid JSON in this exact format:**
        {
          "titles": [
            {
              "text": "title text",
              "category": "Meeting|Personal|Technical|General",
              "confidence": 0.85
            }
          ]
        }

        Rules:
        - Output ONLY the JSON object, nothing else
        - Do not include any explanatory text
        - Do not use markdown formatting
        - Generate exactly 4 titles with 85% or higher confidence
        - Each title should be 40-60 characters and 4-6 words
        - Focus on the most important and specific topics
        - Avoid generic or vague titles
        - If no suitable titles are found, return empty array
        - Ensure all JSON is properly escaped

        Transcript:
        \(text)
        """
        
        print("🔧 OllamaService: Sending title extraction request")
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        print("🔧 OllamaService: Received response for titles (\(response.count) chars)")
        
        // Parse JSON response
        guard let data = response.data(using: .utf8) else {
            throw OllamaError.parsingError("Failed to convert response to data")
        }
        
        do {
            print("🔧 OllamaService: Attempting to parse JSON response for titles")
            let rawResult = try JSONDecoder().decode(RawTitleResult.self, from: data)
            
            print("✅ OllamaService: Successfully parsed titles JSON")
            print("🔧 OllamaService: Found \(rawResult.titles.count) titles")
            
            // Convert raw results to proper TitleItem objects
            let titles = rawResult.titles.map { rawTitle in
                TitleItem(
                    text: rawTitle.text,
                    confidence: rawTitle.confidence,
                    category: TitleItem.TitleCategory(rawValue: rawTitle.category) ?? .general
                )
            }
            
            return titles
        } catch {
            print("❌ OllamaService: JSON parsing failed for titles: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription)")
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
        
        let generateRequest = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            stream: false,
            options: OllamaOptions(
                num_predict: config.maxTokens,
                temperature: config.temperature,
                top_p: 0.9,
                top_k: 40
            )
        )
        
        request.httpBody = try JSONEncoder().encode(generateRequest)
        
        Self.requestCounter += 1
        print("🔧 OllamaService: Sending request #\(Self.requestCounter) to \(url)")
        print("🔧 OllamaService: Request type: \(model)")
        print("🔧 OllamaService: Request body: \(String(data: request.httpBody!, encoding: .utf8) ?? "nil")")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("❌ OllamaService: HTTP error - Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            throw OllamaError.serverError("Failed to generate response")
        }
        
        print("✅ OllamaService: Received response #\(Self.requestCounter) - Status: \(httpResponse.statusCode)")
        
        do {
            let generateResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            print("✅ OllamaService: Successfully parsed response")
            
            // Clean up the response based on the expected format
            let cleanedResponse = cleanForJSON ? cleanOllamaResponse(generateResponse.response) : cleanSummaryResponse(generateResponse.response)
            print("🔧 OllamaService: Cleaned response (\(cleanedResponse.count) chars)")
            
            return cleanedResponse
        } catch {
            print("❌ OllamaService: JSON parsing failed: \(error)")
            print("❌ OllamaService: Response data length: \(data.count) bytes")
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription)")
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