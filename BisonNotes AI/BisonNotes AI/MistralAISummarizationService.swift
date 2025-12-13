//
//  MistralAISummarizationService.swift
//  Audio Journal
//
//  Dedicated summarization service for Mistral's OpenAI-compatible chat API
//

import Foundation
import os.log

/// Service for interacting with Mistral AI's OpenAI-compatible chat completion API
///
/// This service handles all direct API communication with Mistral, including:
/// - Request construction and JSON encoding
/// - Authentication and headers
/// - Response parsing and error handling
/// - Structured output using JSON mode (when supported)
/// - Logging with appropriate privacy levels
class MistralAISummarizationService: ObservableObject {

    // MARK: - Properties

    @Published var config: MistralAIConfig
    private let session: URLSession
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "MistralAISummarizationService")

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

        let request = OpenAIChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxCompletionTokens: config.maxTokens,
            responseFormat: config.supportsJsonResponseFormat ? ResponseFormat.json : nil
        )

        logger.debug("Mistral Provider: \(config.baseURL, privacy: .public)")
        logger.debug("Using response_format: \(config.supportsJsonResponseFormat ? "json_object" : "none (flexible parsing)", privacy: .public)")

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
            logger.info("Mistral connection test \(success ? "successful" : "failed", privacy: .public)")
            return success
        } catch {
            logger.error("Mistral connection test failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private Helper Methods

    private func makeAPICall(request: OpenAIChatCompletionRequest) async throws -> OpenAIChatCompletionResponse {
        guard !config.apiKey.isEmpty else {
            logger.error("Mistral API key is empty")
            throw SummarizationError.aiServiceUnavailable(service: "Mistral API key not configured")
        }

        logger.debug("Mistral API Configuration - Model: \(config.model.rawValue, privacy: .public), BaseURL: \(config.baseURL, privacy: .public)")
        logger.debug("API Key configured: \(config.apiKey.isEmpty ? "No" : "Yes", privacy: .public)")

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

            if let requestData = urlRequest.httpBody {
                logger.debug("Request size: \(requestData.count, privacy: .public) bytes")
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to encode request: \(error.localizedDescription)")
        }

        do {
            logger.debug("Making Mistral API request")
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from Mistral")
            }

            logger.debug("Mistral API Response - Status: \(httpResponse.statusCode, privacy: .public)")
            logger.debug("Response data length: \(data.count, privacy: .public) bytes")

            if httpResponse.statusCode != 200 {
                if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
                    logger.error("Mistral API Error: \(errorResponse.error.message, privacy: .public)")
                    throw SummarizationError.aiServiceUnavailable(service: "Mistral API Error: \(errorResponse.error.message)")
                } else {
                    let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                    logger.error("Mistral API Error: HTTP \(httpResponse.statusCode, privacy: .public)")
                    throw SummarizationError.aiServiceUnavailable(service: "Mistral API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                }
            }

            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(OpenAIChatCompletionResponse.self, from: data)

            if let usage = apiResponse.usage {
                logger.info("Usage - Prompt: \(usage.promptTokens, privacy: .public), Completion: \(usage.completionTokens, privacy: .public), Total: \(usage.totalTokens, privacy: .public)")
            }

            return apiResponse
        } catch {
            logger.error("Mistral API call failed: \(error.localizedDescription, privacy: .public)")
            throw SummarizationError.aiServiceUnavailable(service: error.localizedDescription)
        }
    }
}

