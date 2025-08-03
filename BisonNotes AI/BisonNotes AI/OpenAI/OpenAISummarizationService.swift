//
//  OpenAISummarizationService.swift
//  Audio Journal
//
//  Refactored OpenAI service with standardized title generation
//

import Foundation

// MARK: - OpenAI Summarization Service

class OpenAISummarizationService: ObservableObject {
    
    // MARK: - Properties
    
    @Published var config: OpenAISummarizationConfig
    private let session: URLSession
    
    // MARK: - Initialization
    
    init(config: OpenAISummarizationConfig) {
        self.config = config
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout * 2
        self.session = URLSession(configuration: sessionConfig)
    }
    
    // MARK: - Public Methods
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .summary, contentType: contentType)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .summary, text: text)
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        return choice.message.content
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .tasks, contentType: .general)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .tasks, text: text)
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 1024
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        return try OpenAIResponseParser.parseTasksFromJSON(choice.message.content)
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .reminders, contentType: .general)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .reminders, text: text)
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 1024
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        return try OpenAIResponseParser.parseRemindersFromJSON(choice.message.content)
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        // Use the existing processComplete method to get everything in one API call
        // This is more cost-effective than making separate calls
        let result = try await processComplete(text: text)
        return result.titles
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        // Use enhanced ContentAnalyzer for classification
        return ContentAnalyzer.classifyContent(text)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // First classify the content
        let contentType = try await classifyContent(text)
        
        // Create a comprehensive prompt for all tasks
        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .complete, text: text)
        
        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]
        
        let request = OpenAIChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens,
            responseFormat: ResponseFormat.completeResponseSchema
        )
        
        let response = try await makeAPICall(request: request)
        
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }
        
        // With structured output, we get guaranteed valid JSON
        let result = try OpenAIResponseParser.parseCompleteResponseFromJSON(choice.message.content)
        return (result.summary, result.tasks, result.reminders, result.titles, contentType)
    }
    
    func testConnection() async -> Bool {
        do {
            let testPrompt = "Hello, this is a test message. Please respond with 'Test successful'."
            let response = try await generateSummary(from: testPrompt, contentType: .general)
            let success = response.contains("Test successful") || response.contains("test successful")
            print("✅ OpenAI connection test \(success ? "successful" : "failed")")
            return success
        } catch {
            print("❌ OpenAI connection test failed: \(error)")
            return false
        }
    }
    
    // MARK: - Static Methods
    
    static func fetchModels(apiKey: String, baseURL: String) async throws -> [OpenAISummarizationModel] {
        guard !apiKey.isEmpty else {
            throw SummarizationError.aiServiceUnavailable(service: "API key is empty")
        }
        
        guard let url = URL(string: "\(baseURL)/models") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid base URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let session = URLSession.shared
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw SummarizationError.aiServiceUnavailable(service: "HTTP \(httpResponse.statusCode)")
        }
        
        // For now, return the predefined models
        // In a full implementation, you would parse the actual API response
        return OpenAISummarizationModel.allCases
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
        
        print("🔧 OpenAI API Configuration - Model: \(config.effectiveModelId), BaseURL: \(config.baseURL)")
        print("🔑 API Key: \(String(config.apiKey.prefix(7)))...")
        
        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid OpenAI base URL: \(config.baseURL)")
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        		urlRequest.setValue("BisonNotes AI iOS App", forHTTPHeaderField: "User-Agent")
        
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
            print("❌ OpenAI API request failed: \(error)")
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API request failed: \(error.localizedDescription)")
        }
    }
} 