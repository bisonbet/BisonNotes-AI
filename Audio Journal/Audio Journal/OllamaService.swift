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
    
    var baseURL: String {
        return "\(serverURL):\(port)"
    }
    
    static let `default` = OllamaConfig(
        serverURL: "http://localhost",
        port: 11434,
        modelName: "llama2:7b",
        maxTokens: 2048,
        temperature: 0.1
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
    
    @Published var isConnected: Bool = false
    @Published var availableModels: [OllamaModel] = []
    @Published var connectionError: String?
    
    init(config: OllamaConfig = .default) {
        self.config = config
        
        // Create a custom URLSession with longer timeout for Ollama requests
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120.0  // 2 minutes
        config.timeoutIntervalForResource = 300.0 // 5 minutes
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
        
        // Trim whitespace and newlines
        return cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Remove <think> tags and their content
        let thinkPattern = #"<think>[\s\S]*?</think>"#
        var cleanedTitle = response.replacingOccurrences(
            of: thinkPattern,
            with: "",
            options: .regularExpression
        )
        
        // Remove quotes if present
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "'", with: "")
        
        // Remove common prefixes/suffixes that might be added
        let unwantedPrefixes = ["Title:", "Name:", "Generated Title:", "Conversation Title:", "The title is:", "Here's the title:", "Title is:"]
        for prefix in unwantedPrefixes {
            if cleanedTitle.lowercased().hasPrefix(prefix.lowercased()) {
                cleanedTitle = String(cleanedTitle.dropFirst(prefix.count))
            }
        }
        
        // Remove word count patterns
        let wordCountPattern = #"\s*\(\d+\s+words?\)\s*$"#
        cleanedTitle = cleanedTitle.replacingOccurrences(
            of: wordCountPattern,
            with: "",
            options: .regularExpression
        )
        
        // Remove markdown formatting
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "**", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "*", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "#", with: "")
        
        // Remove extra punctuation at the end
        cleanedTitle = cleanedTitle.replacingOccurrences(of: #"\.+$"#, with: "", options: .regularExpression)
        cleanedTitle = cleanedTitle.replacingOccurrences(of: #"!+$"#, with: "", options: .regularExpression)
        cleanedTitle = cleanedTitle.replacingOccurrences(of: #"\?+$"#, with: "", options: .regularExpression)
        
        // Trim whitespace and newlines
        cleanedTitle = cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Ensure title is not too long (max 50 characters)
        if cleanedTitle.count > 50 {
            cleanedTitle = String(cleanedTitle.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Validate that the title makes sense (not just random characters or repeated words)
        let words = cleanedTitle.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.count < 2 || words.count > 6 {
            // If too few or too many words, it might be nonsensical
            cleanedTitle = "Untitled Conversation"
        }
        
        // Check for repeated words or nonsensical patterns
        let uniqueWords = Set(words.map { $0.lowercased() })
        if uniqueWords.count < Int(Double(words.count) * 0.7) { // If more than 30% of words are repeated
            cleanedTitle = "Untitled Conversation"
        }
        
        // Ensure title is not empty
        if cleanedTitle.isEmpty {
            cleanedTitle = "Untitled Conversation"
        }
        
        return cleanedTitle
    }
    
    // MARK: - AI Processing
    
    func generateSummary(from text: String) async throws -> String {
        let prompt = """
        Please provide a concise summary of the following transcript. Focus on the main points, key decisions, and important information. Keep the summary under 200 words.

        **Format your response using markdown:**
        - Use **bold** for emphasis on key points
        - Use bullet points for lists
        - Use proper paragraph breaks
        - Keep formatting clean and readable

        Transcript:
        \(text)

        **Summary:**
        """
        
        return try await generateResponse(prompt: prompt, model: config.modelName)
    }
    
    func generateTitle(from text: String) async throws -> String {
        let prompt = """
        Generate a concise, descriptive title for this conversation/transcript. The title should:
        1. Be 2-5 words maximum
        2. Capture the main topic or purpose
        3. Be specific and meaningful
        4. Work well as a file name or conversation title
        5. Avoid generic terms like "Meeting" or "Conversation" unless truly appropriate
        6. Focus on the most important subject or action mentioned

        Examples of good titles:
        - "Trump Scotland Visit"
        - "Hong Kong Arrest Warrants" 
        - "Texas Redistricting Debate"
        - "Walmart Stabbing Investigation"
        - "Harvard Funding Deal"
        - "Project Budget Review"
        - "Client Presentation Prep"
        - "Team Strategy Meeting"

        **IMPORTANT: Return ONLY the title, nothing else. No quotes, no explanation, no markdown formatting, no extra text.**

        Transcript:
        \(text)
        """
        
        print("🔧 OllamaService: Sending title generation request")
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        print("🔧 OllamaService: Generated title: \(response)")
        
        // Clean up the response and ensure it's a good title
        let cleanedTitle = cleanTitleResponse(response)
        print("🔧 OllamaService: Cleaned title: \(cleanedTitle)")
        
        return cleanedTitle
    }
    
    func extractTasksAndReminders(from text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        let prompt = """
        Analyze the following transcript and extract any tasks, to-dos, or reminders mentioned. For each item found, provide:
        1. A brief description (under 50 words)
        2. Priority level (High, Medium, Low)
        3. If a date/time is mentioned, include it
        4. Categorize as either a task or reminder

        **Return the results in this exact JSON format (no markdown, just pure JSON):**
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

        Only include items with 80% or higher confidence. If no tasks or reminders are found, return empty arrays.

        Transcript:
        \(text)
        """
        
        print("🔧 OllamaService: Sending tasks/reminders extraction request")
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        print("🔧 OllamaService: Received response for tasks/reminders: \(response)")
        
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
            print("❌ OllamaService: Raw response data: \(String(data: data, encoding: .utf8) ?? "nil")")
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription)")
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        let prompt = """
        Analyze the following transcript and extract potential titles or headlines. Focus on:
        - Main topics or themes discussed
        - Key decisions or outcomes
        - Important events or milestones
        - Central questions or problems addressed

        **Return the results in this exact JSON format (no markdown, just pure JSON):**
        {
          "titles": [
            {
              "text": "title text",
              "category": "Meeting|Personal|Technical|General",
              "confidence": 0.85
            }
          ]
        }

        Only include titles with 80% or higher confidence. If no titles are found, return empty array.

        Transcript:
        \(text)
        """
        
        print("🔧 OllamaService: Sending title extraction request")
        let response = try await generateResponse(prompt: prompt, model: config.modelName)
        
        print("🔧 OllamaService: Received response for titles: \(response)")
        
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
            print("❌ OllamaService: Raw response data: \(String(data: data, encoding: .utf8) ?? "nil")")
            throw OllamaError.parsingError("Failed to parse JSON response: \(error.localizedDescription)")
        }
    }
    
    private func generateResponse(prompt: String, model: String) async throws -> String {
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
        
        print("🔧 OllamaService: Sending request to \(url)")
        print("🔧 OllamaService: Request body: \(String(data: request.httpBody!, encoding: .utf8) ?? "nil")")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("❌ OllamaService: HTTP error - Status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            print("❌ OllamaService: Response data: \(String(data: data, encoding: .utf8) ?? "nil")")
            throw OllamaError.serverError("Failed to generate response")
        }
        
        print("✅ OllamaService: Received response - Status: \(httpResponse.statusCode)")
        print("🔧 OllamaService: Response data: \(String(data: data, encoding: .utf8) ?? "nil")")
        
        do {
            let generateResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            print("✅ OllamaService: Successfully parsed response")
            print("🔧 OllamaService: Raw response: \(generateResponse.response)")
            
            // Clean up the response by removing <think> tags and their content
            let cleanedResponse = cleanOllamaResponse(generateResponse.response)
            print("🔧 OllamaService: Cleaned response: \(cleanedResponse)")
            
            return cleanedResponse
        } catch {
            print("❌ OllamaService: JSON parsing failed: \(error)")
            print("❌ OllamaService: Raw response data: \(String(data: data, encoding: .utf8) ?? "nil")")
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