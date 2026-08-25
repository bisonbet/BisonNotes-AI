//
//  MistralAISummarizationService.swift
//  Audio Journal
//
//  Dedicated summarization service for Mistral's compatible chat API
//

import Foundation
import os.log

/// Service for interacting with Mistral AI's compatible chat-completion API
///
/// This service handles all direct API communication with Mistral, including:
/// - Request construction and JSON encoding
/// - Authentication and headers
/// - Response parsing and error handling
/// - Structured output using JSON mode (when supported)
/// - Logging with appropriate privacy levels
///
/// **Thread Safety:**
/// This service is designed to be used from async contexts. The config is immutable after initialization,
/// ensuring thread-safe access across multiple concurrent operations.
@MainActor
class MistralAISummarizationService {

    // MARK: - Properties

    private let config: MistralAIConfig
    private let session: URLSession
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.app", category: "MistralAISummarizationService")

    private var thinkingOptions: SummaryThinkingRequestOptions {
        SummaryThinkingModelCatalog.requestOptions(
            modelName: config.model.rawValue,
            engine: .mistralAI,
            baseURL: config.baseURL
        )
    }

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
        // Validate input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.aiServiceUnavailable(service: "Mistral AI - Empty text provided")
        }

        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .summary, contentType: contentType)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .summary, text: text)

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]

        let request = MistralChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxTokens: completionTokenBudget,
            responseFormat: nil,
            reasoningEffort: thinkingOptions.reasoningEffort
        )

        let choice = try await requestCompletion(request)

        return SummaryThinkingResponseCleaner.stripDelimitedThinking(from: choice.message.content)
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .tasks, contentType: .general)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .tasks, text: text)

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]

        let request = MistralChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxTokens: metadataTokenBudget,
            responseFormat: nil,
            reasoningEffort: nil
        )

        let choice = try await requestCompletion(request)

        return try ChatCompletionResponseParser.parseTasksFromJSON(choice.message.content)
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .reminders, contentType: .general)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .reminders, text: text)

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]

        let request = MistralChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: 0.1,
            maxTokens: metadataTokenBudget,
            responseFormat: nil,
            reasoningEffort: nil
        )

        let choice = try await requestCompletion(request)

        return try ChatCompletionResponseParser.parseRemindersFromJSON(choice.message.content)
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        let result = try await processComplete(text: text)
        return result.titles
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        return ContentAnalyzer.classifyContent(text)
    }

    func processComplete(text: String) async throws -> SummarizationResult {
        let contentType = try await classifyContent(text)

        let systemPrompt = ChatCompletionPromptGenerator.createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = ChatCompletionPromptGenerator.createUserPrompt(for: .complete, text: text)

        let messages = [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userPrompt)
        ]

        let request = MistralChatCompletionRequest(
            model: config.model.rawValue,
            messages: messages,
            temperature: config.temperature,
            maxTokens: completionTokenBudget,
            responseFormat: config.supportsJsonResponseFormat ? ResponseFormat.json : nil,
            reasoningEffort: thinkingOptions.reasoningEffort
        )

        logger.debug("Mistral AI Provider: \(self.config.baseURL, privacy: .public)")
        logger.debug("Using response_format: \(self.config.supportsJsonResponseFormat ? "json_object" : "none (flexible parsing)", privacy: .public)")

        let choice = try await requestCompletion(request)

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

    // MARK: - Private Helper Methods

    /// Answer budget for metadata-only calls. Extraction needs far less room
    /// than a summary, but a reasoning model still thinks before answering.
    private static let metadataAnswerTokens = 1_024

    /// The output budget to request. `max_tokens` covers the reasoning pass as
    /// well as the answer, so reasoning models such as Magistral need headroom
    /// above the configured answer size or the summary comes back cut off.
    private var completionTokenBudget: Int {
        SummaryThinkingModelCatalog.completionTokenBudget(
            configured: config.maxTokens,
            modelName: config.model.rawValue,
            engine: .mistralAI,
            baseURL: config.baseURL
        )
    }

    private var metadataTokenBudget: Int {
        SummaryThinkingModelCatalog.completionTokenBudget(
            configured: Self.metadataAnswerTokens,
            modelName: config.model.rawValue,
            engine: .mistralAI,
            baseURL: config.baseURL
        )
    }

    /// Sends a request and returns the first choice, growing the output budget
    /// once when the provider stopped at the limit instead of at the end of the
    /// answer. A truncated response is never handed to the parsers: partial JSON
    /// surfaces as a malformed structured response, which hides the real cause.
    private func requestCompletion(_ request: MistralChatCompletionRequest) async throws -> Choice {
        var attemptedBudget = request.maxTokens ?? config.maxTokens
        var response = try await makeAPICall(request: request)
        var choice = try firstChoice(of: response)

        if choice.wasTruncatedByTokenLimit {
            let grownBudget = min(
                attemptedBudget * 2,
                SummaryThinkingModelCatalog.maximumCompletionTokenBudget
            )

            if grownBudget > attemptedBudget {
                let reasoningDescription = response.usage?.reasoningTokens.map { "\($0)" } ?? "unreported"
                logger.error("""
                    Mistral AI stopped at the \(attemptedBudget, privacy: .public)-token output limit                     (reasoning tokens: \(reasoningDescription, privacy: .public));                     retrying once with \(grownBudget, privacy: .public)
                    """)

                attemptedBudget = grownBudget
                response = try await makeAPICall(request: request.withMaxTokens(grownBudget))
                choice = try firstChoice(of: response)
            }
        }

        guard !choice.wasTruncatedByTokenLimit else {
            throw SummarizationError.responseTruncated(
                service: "Mistral AI (\(config.model.rawValue))",
                tokenLimit: attemptedBudget,
                reasoningTokens: response.usage?.reasoningTokens
            )
        }

        return choice
    }

    private func firstChoice(of response: ChatCompletionResponse) throws -> Choice {
        guard let choice = response.choices.first else {
            throw SummarizationError.aiServiceUnavailable(service: "Mistral AI - No response choices")
        }
        return choice
    }

    private func makeAPICall(request: MistralChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard !config.apiKey.isEmpty else {
            logger.error("Mistral AI API key is empty")
            throw SummarizationError.aiServiceUnavailable(service: "Mistral AI API key not configured")
        }

        logger.debug("Mistral AI API Configuration - Model: \(self.config.model.rawValue, privacy: .public), BaseURL: \(self.config.baseURL, privacy: .public)")
        logger.debug("API Key configured: \(self.config.apiKey.isEmpty ? "No" : "Yes", privacy: .public)")

        guard let url = URL(string: "\(config.baseURL)/chat/completions") else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid Mistral AI base URL: \(config.baseURL)")
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
            logger.debug("Making Mistral AI API request")
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from Mistral AI")
            }

            logger.debug("Mistral AI API Response - Status: \(httpResponse.statusCode, privacy: .public)")
            logger.debug("Response data length: \(data.count, privacy: .public) bytes")

            // Handle rate limiting with retry information
            if httpResponse.statusCode == 429 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "unknown"
                let rateLimitReset = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset") ?? "unknown"

                logger.warning("Mistral API rate limit exceeded - Retry-After: \(retryAfter, privacy: .public), Reset: \(rateLimitReset, privacy: .public)")

                // Provide helpful error message with retry timing
                var errorMessage = "Mistral API rate limit exceeded."
                if let retrySeconds = Int(retryAfter) {
                    errorMessage += " Please retry after \(retrySeconds) seconds."
                } else if rateLimitReset != "unknown" {
                    errorMessage += " Rate limit resets at: \(rateLimitReset)."
                }

                throw SummarizationError.aiServiceUnavailable(service: errorMessage)
            }

            if httpResponse.statusCode != 200 {
                if let errorResponse = try? JSONDecoder().decode(CompatibleAPIErrorResponse.self, from: data) {
                    logger.error("Mistral API Error: \(errorResponse.error.message, privacy: .public)")
                    throw SummarizationError.aiServiceUnavailable(service: "Mistral API Error: \(errorResponse.error.message)")
                } else {
                    logger.error("Mistral API Error: HTTP \(httpResponse.statusCode, privacy: .public), response size: \(data.count, privacy: .public) bytes")
                    throw SummarizationError.aiServiceUnavailable(service: "Mistral API Error: HTTP \(httpResponse.statusCode)")
                }
            }

            let decoder = JSONDecoder()
            let apiResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

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
