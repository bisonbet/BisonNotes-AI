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

    // Cache the message format to avoid repeated UserDefaults reads and ensure consistency
    private let cachedMessageFormat: MessageContentFormat
    private let cachedShouldUseResponseFormat: Bool

    // MARK: - Initialization

    init(config: OpenAISummarizationConfig) {
        self.config = config

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout * 2
        self.session = URLSession(configuration: sessionConfig)

        // Cache format detection results at initialization to avoid:
        // 1. Thread safety issues with UserDefaults access during concurrent API calls
        // 2. Performance overhead of repeated UserDefaults reads
        // 3. Inconsistent format detection mid-session if settings change
        self.cachedMessageFormat = MessageFormatDetector.detectFormat(for: config.baseURL)
        self.cachedShouldUseResponseFormat = MessageFormatDetector.shouldUseResponseFormat(for: config.baseURL)
    }
    
    // MARK: - Public Methods
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .summary, contentType: contentType)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .summary, text: text)

        // Use cached message format (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
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

        // Use cached message format (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
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

        // Use cached message format (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
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

        // Use cached message format and response format settings (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
        ]

        // IMPORTANT: For OpenAI Compatible APIs, don't use response_format
        // LiteLLM and other routers may proxy to various providers (Bedrock, Anthropic, Ollama, etc.)
        // and response_format support varies widely:
        // - Some providers don't support it at all
        // - Others interpret it differently (e.g., Bedrock wraps in {"json": {...}})
        // - Some trigger tool calling instead of direct JSON
        //
        // Best practice: Only use response_format with official OpenAI API
        // For all others, rely on explicit prompts and flexible parsing
        let request = OpenAIChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens,
            responseFormat: cachedShouldUseResponseFormat ? ResponseFormat.json : nil
        )

        #if DEBUG
        print("🔧 Provider: \(config.baseURL)")
        print("🔧 Message format: \(cachedMessageFormat.displayName)")
        print("🔧 Using response_format: \(cachedShouldUseResponseFormat ? "json_object" : "none (flexible parsing)")")
        #endif

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI - No response choices")
        }

        // Parse the JSON response with flexible format handling
        // Supports: standard format, wrapped format, markdown code blocks, plain text fallback
        let result = try OpenAIResponseParser.parseCompleteResponseFromJSON(choice.message.content)
        return (result.summary, result.tasks, result.reminders, result.titles, contentType)
    }
    
    func testConnection() async -> Bool {
        do {
            let testPrompt = "Hello, this is a test message. Please respond with 'Test successful'."
            let response = try await generateSummary(from: testPrompt, contentType: .general)
            let success = response.contains("Test successful") || response.contains("test successful")
            #if DEBUG
            print("✅ OpenAI connection test \(success ? "successful" : "failed")")
            #endif
            return success
        } catch {
            #if DEBUG
            print("❌ OpenAI connection test failed: \(error)")
            #endif
            return false
        }
    }
    
    // MARK: - Static Methods

    /// Fetch predefined OpenAI models (for official OpenAI API)
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

        // For OpenAI, return the predefined models
        // The actual API returns many models but we only support specific ones
        return OpenAISummarizationModel.allCases
    }

    /// Fetch available models from an OpenAI-compatible API (for third-party providers)
    /// Returns raw model IDs that can be used with any compatible API
    static func fetchCompatibleModels(apiKey: String, baseURL: String) async throws -> [String] {
        guard !apiKey.isEmpty else {
            throw SummarizationError.aiServiceUnavailable(service: "API key is empty")
        }

        // Normalize base URL - remove trailing slash if present
        var normalizedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedBaseURL.hasSuffix("/") {
            normalizedBaseURL.removeLast()
        }

        guard let url = URL(string: "\(normalizedBaseURL)/models") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid base URL: \(baseURL)")
        }

        #if DEBUG
        print("🔍 Fetching models from: \(url.absoluteString)")
        #endif

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = OpenAISummarizationConfig.connectionTestTimeout

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid response from server")
        }

        #if DEBUG
        print("📡 Models endpoint response status: \(httpResponse.statusCode)")
        #endif

        guard httpResponse.statusCode == 200 else {
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                throw SummarizationError.aiServiceUnavailable(service: "API Error: \(errorResponse.error.message)")
            }

            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizationError.aiServiceUnavailable(service: "HTTP \(httpResponse.statusCode): \(responseString)")
        }

        // Parse the models response
        do {
            let modelsResponse = try JSONDecoder().decode(OpenAIModelsListResponse.self, from: data)
            let modelIds = modelsResponse.data.map { $0.id }.sorted()

            #if DEBUG
            print("✅ Successfully fetched \(modelIds.count) models from OpenAI-compatible API")
            if !modelIds.isEmpty {
                print("📋 Available models: \(modelIds.prefix(10).joined(separator: ", "))\(modelIds.count > 10 ? "..." : "")")
            }
            #endif

            return modelIds
        } catch {
            #if DEBUG
            print("❌ Failed to parse models response: \(error)")
            #endif
            throw SummarizationError.aiServiceUnavailable(service: "Failed to parse models response: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Helper Methods

    /// Check if a base URL is the official OpenAI API
    /// Uses precise URL parsing to avoid false positives
    private func isOfficialOpenAI(baseURL: String) -> Bool {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            return false
        }

        // Must be exactly "api.openai.com" or a subdomain of "openai.com"
        return host == "api.openai.com" || host == "openai.com" || host.hasSuffix(".openai.com")
    }

    private func makeAPICall(request: OpenAIChatCompletionRequest) async throws -> OpenAIChatCompletionResponse {
        // Validate configuration before making API call
        guard !config.apiKey.isEmpty else {
            #if DEBUG
            print("❌ OpenAI API key is empty")
            #endif
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API key not configured")
        }

        // Only validate sk- prefix for official OpenAI API
        // Third-party providers (LiteLLM, Nebius, etc.) use different key formats
        // Use precise URL matching to avoid false positives (e.g., malicious-api.openai.com.evil.com)
        if isOfficialOpenAI(baseURL: config.baseURL) && !config.apiKey.hasPrefix("sk-") {
            #if DEBUG
            print("❌ OpenAI API key format is invalid (should start with 'sk-')")
            #endif
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API key format is invalid")
        }

        #if DEBUG
        print("🔧 OpenAI API Configuration - Model: \(config.effectiveModelId), BaseURL: \(config.baseURL)")
        print("🔑 API Key: \(String(config.apiKey.prefix(7)))...")
        #endif
        
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

            #if DEBUG
            // Log the request details for debugging
            if let requestBody = String(data: urlRequest.httpBody!, encoding: .utf8) {
                print("📤 OpenAI API Request Body (first 300 chars): \(requestBody.prefix(300))...")
                print("📊 Total request size: \(requestBody.count) characters")
            }
            #endif
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to encode request: \(error.localizedDescription)")
        }
        
        do {
            #if DEBUG
            print("🌐 Making OpenAI API request...")
            #endif
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from OpenAI")
            }

            #if DEBUG
            // Log the raw response for debugging
            let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("🌐 OpenAI API Response - Status: \(httpResponse.statusCode)")
            print("📝 Raw response: \(responseString)")
            print("📊 Response data length: \(data.count) bytes")
            #endif
            
            if httpResponse.statusCode != 200 {
                // Try to parse error response
                if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                    #if DEBUG
                    print("❌ OpenAI API Error: \(errorResponse.error.message)")
                    #endif
                    throw SummarizationError.aiServiceUnavailable(service: "OpenAI API Error: \(errorResponse.error.message)")
                } else {
                    #if DEBUG
                    let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                    print("❌ OpenAI API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                    #endif
                    throw SummarizationError.aiServiceUnavailable(service: "OpenAI API Error: HTTP \(httpResponse.statusCode)")
                }
            }

            let decoder = JSONDecoder()
            // Pass the expected message format through userInfo for proper ChatMessage decoding
            decoder.userInfo[ChatMessage.formatKey] = cachedMessageFormat
            let apiResponse = try decoder.decode(OpenAIChatCompletionResponse.self, from: data)

            #if DEBUG
            // Log the parsed response for debugging
            if let firstChoice = apiResponse.choices.first {
                let tokenCount = apiResponse.usage?.totalTokens ?? 0
                print("✅ OpenAI API Success - Model: \(apiResponse.model), Tokens: \(tokenCount)")
                print("📝 Response content length: \(firstChoice.message.content.count) characters")
            } else {
                print("⚠️ OpenAI API returned no choices")
            }
            #endif

            return apiResponse

        } catch {
            #if DEBUG
            print("❌ OpenAI API request failed: \(error)")
            #endif
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI API request failed: \(error.localizedDescription)")
        }
    }
} 