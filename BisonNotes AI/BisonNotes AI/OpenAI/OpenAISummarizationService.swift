//
//  OpenAICompatibleService.swift
//  Audio Journal
//
//  Compatible API service with standardized title generation
//

import Foundation

// MARK: - Compatible API Service

class OpenAICompatibleService: ObservableObject {

    // MARK: - Properties

    @Published var config: OpenAICompatibleConfig
    private let session: URLSession

    // Cache the message format to avoid repeated UserDefaults reads and ensure consistency
    private let cachedMessageFormat: MessageContentFormat

    // MARK: - Initialization

    init(config: OpenAICompatibleConfig) {
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
    }

    // MARK: - Public Methods

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .summary, contentType: contentType)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .summary, text: text)

        // Use cached message format (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
        ]

        let request = ChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: effectiveTemperature(config.temperature),
            maxCompletionTokens: config.maxTokens,
            reasoningEffort: reasoningEffort(),
            enableThinking: thinkingOptions.enableThinking,
            thinkingBudget: thinkingOptions.thinkingBudget,
            chatTemplateKwargs: thinkingOptions.chatTemplateKwargs
        )

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API - No response choices")
        }

        return SummaryThinkingResponseCleaner.stripDelimitedThinking(from: choice.message.content)
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .tasks, contentType: .general)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .tasks, text: text)

        // Use cached message format (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
        ]

        let request = ChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: effectiveTemperature(0.1),
            maxCompletionTokens: 1024,
            reasoningEffort: nil,
            enableThinking: nil,
            thinkingBudget: nil,
            chatTemplateKwargs: nil
        )

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API - No response choices")
        }

        return try ChatCompletionResponseParser.parseTasksFromJSON(choice.message.content)
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .reminders, contentType: .general)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .reminders, text: text)

        // Use cached message format (determined at initialization)
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
        ]

        let request = ChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: effectiveTemperature(0.1),
            maxCompletionTokens: 1024,
            reasoningEffort: nil,
            enableThinking: nil,
            thinkingBudget: nil,
            chatTemplateKwargs: nil
        )

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API - No response choices")
        }

        return try ChatCompletionResponseParser.parseRemindersFromJSON(choice.message.content)
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

    func processComplete(text: String) async throws -> SummarizationResult {
        // First classify the content
        let contentType = try await classifyContent(text)

        // Create a comprehensive prompt for all tasks
        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .complete, text: text)

        // Use the cached message format. Compatible endpoints vary widely in
        // their support for response_format, so flexible parsing is safer.
        let messages = [
            ChatMessage(role: "system", content: systemPrompt, format: cachedMessageFormat),
            ChatMessage(role: "user", content: userPrompt, format: cachedMessageFormat)
        ]

        let request = ChatCompletionRequest(
            model: config.effectiveModelId,
            messages: messages,
            temperature: effectiveTemperature(config.temperature),
            maxCompletionTokens: config.maxTokens,
            responseFormat: nil,
            reasoningEffort: reasoningEffort(),
            enableThinking: thinkingOptions.enableThinking,
            thinkingBudget: thinkingOptions.thinkingBudget,
            chatTemplateKwargs: thinkingOptions.chatTemplateKwargs
        )

        AppLog.shared.networking("Provider: \(config.baseURL), format: \(cachedMessageFormat.displayName), response_format: none", level: .debug)

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API - No response choices")
        }

        // Parse the JSON response with flexible format handling
        // Supports: standard format, wrapped format, markdown code blocks, plain text fallback
        let cleanedContent = SummaryThinkingResponseCleaner.stripDelimitedThinking(
            from: choice.message.content
        )
        let result = try ChatCompletionResponseParser.parseCompleteResponseFromJSON(cleanedContent)
        return SummarizationResult(
            summary: SummaryThinkingResponseCleaner.stripDelimitedThinking(from: result.summary),
            tasks: result.tasks,
            reminders: result.reminders,
            titles: result.titles,
            contentType: contentType
        )
    }

    func testConnection() async -> Bool {
        do {
            let testPrompt = "Hello, this is a test message. Please respond with 'Test successful'."
            let response = try await generateSummary(from: testPrompt, contentType: .general)
            let success = response.contains("Test successful") || response.contains("test successful")
            AppLog.shared.networking("Compatible API connection test \(success ? "successful" : "failed")")
            return success
        } catch {
            AppLog.shared.networking("Compatible API connection test failed: \(error)", level: .error)
            return false
        }
    }

    // MARK: - Static Methods

    /// Fetch available models from a compatible API endpoint.
    /// Returns raw model IDs that can be used with the configured provider.
    static func fetchCompatibleModels(
        apiKey: String,
        baseURL: String,
        allowInsecurePublicEndpoints: Bool = UserDefaults.standard.bool(
            forKey: EndpointSecurityPolicy.allowInsecurePublicEndpointsKey
        )
    ) async throws -> [String] {
        guard !apiKey.isEmpty else {
            throw SummarizationError.aiServiceUnavailable(service: "API key is empty")
        }

        let normalizedBaseURL = Self.normalizedBaseURL(baseURL)

        if let message = EndpointSecurityPolicy.validationMessage(
            for: normalizedBaseURL,
            allowInsecurePublicEndpoints: allowInsecurePublicEndpoints
        ) {
            throw SummarizationError.aiServiceUnavailable(service: message)
        }

        guard let url = URL(string: "\(normalizedBaseURL)/models") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid base URL: \(baseURL)")
        }

        AppLog.shared.networking("Fetching models from: \(url.absoluteString)", level: .debug)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = OpenAICompatibleConfig.connectionTestTimeout

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid response from server")
        }

        AppLog.shared.networking("Models endpoint response status: \(httpResponse.statusCode)", level: .debug)

        guard httpResponse.statusCode == 200 else {
            // Try to parse error response
            if let errorResponse = try? JSONDecoder().decode(CompatibleAPIErrorResponse.self, from: data) {
                throw SummarizationError.aiServiceUnavailable(service: "API Error: \(errorResponse.error.message)")
            }

            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummarizationError.aiServiceUnavailable(service: "HTTP \(httpResponse.statusCode): \(responseString)")
        }

        // Parse the models response
        do {
            let modelsResponse = try JSONDecoder().decode(CompatibleModelsResponse.self, from: data)
            let modelIds = modelsResponse.data.map { $0.id }.sorted()

            AppLog.shared.networking("Fetched \(modelIds.count) models from compatible API", level: .debug)

            return modelIds
        } catch {
            AppLog.shared.networking("Failed to parse models response: \(error)", level: .error)
            throw SummarizationError.aiServiceUnavailable(service: "Failed to parse models response: \(error.localizedDescription)")
        }
    }

    /// Normalizes a provider base URL before appending an API path.
    /// This keeps model discovery and chat requests on the same endpoint.
    static func normalizedBaseURL(_ baseURL: String) -> String {
        var normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// Compatible providers commonly expose the same reasoning-model IDs as
    /// OpenAI, even when the endpoint itself is not hosted by OpenAI.
    static func isReasoningModel(_ modelID: String) -> Bool {
        let lowercasedModelID = modelID.lowercased()
        return lowercasedModelID.hasPrefix("gpt-5") || lowercasedModelID.hasPrefix("gpt5") ||
               lowercasedModelID.hasPrefix("o1") || lowercasedModelID.hasPrefix("o3") ||
               lowercasedModelID.hasPrefix("o4") || lowercasedModelID.contains("reasoning")
    }

    // MARK: - Private Helper Methods

    /// Check if the current model is a reasoning model.
    private func isReasoningModel() -> Bool {
        Self.isReasoningModel(config.effectiveModelId)
    }

    /// Returns a temperature value appropriate for the current model.
    private func effectiveTemperature(_ temperature: Double) -> Double? {
        return isReasoningModel() ? nil : temperature
    }

    /// Returns reasoning effort for reasoning models, nil for others.
    /// Values: "low" (faster, fewer tokens), "medium" (balanced), "high" (more thorough)
    private func reasoningEffort() -> String? {
        return thinkingOptions.reasoningEffort
    }

    /// Translates the shared summary preference into the request contract for
    /// the selected compatible model family. `.none` returns all nil fields.
    private var thinkingOptions: SummaryThinkingRequestOptions {
        SummaryThinkingModelCatalog.requestOptions(
            modelName: config.effectiveModelId,
            engine: .openAICompatible,
            baseURL: config.baseURL
        )
    }

    private func makeAPICall(request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        // Validate configuration before making API call
        guard !config.apiKey.isEmpty else {
            AppLog.shared.networking("Compatible API key is empty", level: .error)
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API key not configured")
        }

        let normalizedBaseURL = Self.normalizedBaseURL(config.baseURL)
        if let message = EndpointSecurityPolicy.validationMessage(for: normalizedBaseURL) {
            AppLog.shared.networking("Blocked insecure compatible API endpoint: \(normalizedBaseURL)", level: .error)
            throw SummarizationError.aiServiceUnavailable(service: message)
        }

        AppLog.shared.networking(
            "Compatible API configuration - Model: \(config.effectiveModelId), BaseURL: \(normalizedBaseURL)",
            level: .debug
        )

        guard let url = URL(string: "\(normalizedBaseURL)/chat/completions") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid compatible API base URL: \(config.baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        		urlRequest.setValue("BisonNotes AI iOS App", forHTTPHeaderField: "User-Agent")

        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)

            AppLog.shared.networking("Compatible API request size: \(urlRequest.httpBody?.count ?? 0) bytes", level: .debug)
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to encode request: \(error.localizedDescription)")
        }

        do {
            AppLog.shared.networking("Making compatible API request...", level: .debug)
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from compatible API")
            }

            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.networking("Compatible API response - Status: \(httpResponse.statusCode), size: \(data.count) bytes", level: .debug)
            }

            if httpResponse.statusCode != 200 {
                // Try to parse error response
                if let errorResponse = try? JSONDecoder().decode(CompatibleAPIErrorResponse.self, from: data) {
                    AppLog.shared.networking("Compatible API error: \(errorResponse.error.message)", level: .error)
                    throw SummarizationError.aiServiceUnavailable(service: "Compatible API error: \(errorResponse.error.message)")
                } else {
                    AppLog.shared.networking("Compatible API error: HTTP \(httpResponse.statusCode)", level: .error)
                    throw SummarizationError.aiServiceUnavailable(service: "Compatible API error: HTTP \(httpResponse.statusCode)")
                }
            }

            let decoder = JSONDecoder()
            // Pass the expected message format through userInfo for proper ChatMessage decoding
            decoder.userInfo[ChatMessage.formatKey] = cachedMessageFormat
            let apiResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

            let tokenCount = apiResponse.usage?.totalTokens ?? 0
            AppLog.shared.networking("Compatible API success - Model: \(apiResponse.model), Tokens: \(tokenCount), response: \(apiResponse.choices.first?.message.content.count ?? 0) chars", level: .debug)

            return apiResponse

        } catch {
            AppLog.shared.networking("Compatible API request failed: \(error)", level: .error)
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API request failed: \(error.localizedDescription)")
        }
    }
}
