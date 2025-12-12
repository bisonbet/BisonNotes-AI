//
//  MistralAISummarizationService.swift
//  Audio Journal
//
//  Dedicated summarization service for Mistral's OpenAI-compatible chat API
//

import Foundation

class MistralAISummarizationService: ObservableObject {

    // MARK: - Properties

    @Published var config: MistralAIConfig
    private let session: URLSession

    // MARK: - Initialization

    init(config: MistralAIConfig) {
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
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens
        )

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Mistral - No response choices")
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
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 1024
        )

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Mistral - No response choices")
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
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxCompletionTokens: 1024
        )

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Mistral - No response choices")
        }

        return try OpenAIResponseParser.parseRemindersFromJSON(choice.message.content)
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        let result = try await processComplete(text: text)
        return result.titles
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        return ContentAnalyzer.classifyContent(text)
    }

    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let contentType = try await classifyContent(text)

        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .complete, text: text)

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]

        let useResponseFormat = config.baseURL.contains("api.mistral.ai")

        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens,
            responseFormat: useResponseFormat ? ResponseFormat.json : nil
        )

        print("🔧 Mistral Provider: \(config.baseURL)")
        print("🔧 Using response_format: \(useResponseFormat ? "json_object" : "none (flexible parsing)")")

        let response = try await makeAPICall(request: request)

        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Mistral - No response choices")
        }

        let result = try OpenAIResponseParser.parseCompleteResponseFromJSON(choice.message.content)
        return (result.summary, result.tasks, result.reminders, result.titles, contentType)
    }

    func testConnection() async -> Bool {
        do {
            let testPrompt = "Hello, this is a test message. Please respond with 'Test successful'."
            let response = try await generateSummary(from: testPrompt, contentType: .general)
            let success = response.contains("Test successful") || response.contains("test successful")
            print("✅ Mistral connection test \(success ? "successful" : "failed")")
            return success
        } catch {
            print("❌ Mistral connection test failed: \(error)")
            return false
        }
    }

    // MARK: - Private Helper Methods

    private func makeAPICall(request: OpenAIChatCompletionRequest) async throws -> OpenAIChatCompletionResponse {
        guard !config.apiKey.isEmpty else {
            print("❌ Mistral API key is empty")
            throw SummarizationError.aiServiceUnavailable(service: "Mistral API key not configured")
        }

        print("🔧 Mistral API Configuration - Model: \(config.model.rawValue), BaseURL: \(config.baseURL)")
        print("🔑 API Key: \(String(config.apiKey.prefix(7)))...")

        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid Mistral base URL: \(config.baseURL)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("BisonNotes AI iOS App", forHTTPHeaderField: "User-Agent")

        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)

            if let requestBody = String(data: urlRequest.httpBody!, encoding: .utf8) {
                print("📤 Mistral API Request Body (first 300 chars): \(requestBody.prefix(300))...")
                print("📊 Total request size: \(requestBody.count) characters")
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to encode request: \(error.localizedDescription)")
        }

        do {
            print("🌐 Making Mistral API request...")
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from Mistral")
            }

            let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("🌐 Mistral API Response - Status: \(httpResponse.statusCode)")
            print("📝 Raw response: \(responseString)")
            print("📊 Response data length: \(data.count) bytes")

            if httpResponse.statusCode != 200 {
                if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                    print("❌ Mistral API Error: \(errorResponse.error.message)")
                    throw SummarizationError.aiServiceUnavailable(service: "Mistral API Error: \(errorResponse.error.message)")
                } else {
                    print("❌ Mistral API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                    throw SummarizationError.aiServiceUnavailable(service: "Mistral API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                }
            }

            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(OpenAIChatCompletionResponse.self, from: data)

            if let usage = apiResponse.usage {
                print("📊 Usage - Prompt Tokens: \(usage.promptTokens), Completion Tokens: \(usage.completionTokens), Total: \(usage.totalTokens)")
            }

            return apiResponse
        } catch {
            print("❌ Mistral API call failed: \(error)")
            throw SummarizationError.aiServiceUnavailable(service: error.localizedDescription)
        }
    }
}

