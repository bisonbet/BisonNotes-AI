//
//  OnDeviceLLMService.swift
//  BisonNotes AI
//
//  Service for running inference on locally downloaded LLM models using LocalLLMClient
//

import Foundation
import os.log

// Note: LocalLLMClient must be added as a Swift Package dependency
// Package URL: https://github.com/tattn/LocalLLMClient.git
// Version: 0.4.6

#if canImport(LocalLLMClient)
import LocalLLMClient
import LocalLLMClientLlama
#endif

// MARK: - On-Device LLM Service

@MainActor
class OnDeviceLLMService: ObservableObject {
    static let shared = OnDeviceLLMService()

    // MARK: - Published Properties

    @Published private(set) var isModelLoaded: Bool = false
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var currentModelID: String?
    @Published private(set) var lastError: String?

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.bisonnotes.ai", category: "OnDeviceLLM")
    private let downloadManager = ModelDownloadManager.shared

    #if canImport(LocalLLMClient)
    private var llmSession: LLMSession?
    #endif

    // MARK: - Initialization

    private init() {}

    // MARK: - Model Loading

    /// Load a model for inference
    func loadModel(modelID: String, quantization: OnDeviceLLMQuantization) async throws {
        guard let model = OnDeviceLLMModel.model(byID: modelID) else {
            throw OnDeviceLLMError.modelNotFound(modelID)
        }

        guard let modelPath = downloadManager.modelFilePath(for: model, quantization: quantization) else {
            throw OnDeviceLLMError.modelNotDownloaded
        }

        logger.info("Loading model: \(modelID) at \(modelPath.path)")

        #if canImport(LocalLLMClient)
        do {
            // Create LLM session with the downloaded model
            llmSession = LLMSession(model: .llama(localPath: modelPath.path))
            isModelLoaded = true
            currentModelID = modelID
            lastError = nil
            logger.info("Model loaded successfully: \(modelID)")
        } catch {
            isModelLoaded = false
            currentModelID = nil
            lastError = error.localizedDescription
            logger.error("Failed to load model: \(error.localizedDescription)")
            throw OnDeviceLLMError.modelLoadFailed(error.localizedDescription)
        }
        #else
        // Placeholder for when LocalLLMClient is not available
        logger.warning("LocalLLMClient not available - model loading simulated")
        isModelLoaded = true
        currentModelID = modelID
        #endif
    }

    /// Unload the current model to free memory
    func unloadModel() {
        #if canImport(LocalLLMClient)
        llmSession = nil
        #endif
        isModelLoaded = false
        currentModelID = nil
        logger.info("Model unloaded")
    }

    // MARK: - Text Generation

    /// Generate text from a prompt
    func generate(prompt: String, config: OnDeviceLLMConfig) async throws -> String {
        guard isModelLoaded else {
            throw OnDeviceLLMError.modelNotDownloaded
        }

        isProcessing = true
        defer { isProcessing = false }

        logger.info("Starting generation with prompt length: \(prompt.count)")

        #if canImport(LocalLLMClient)
        guard let session = llmSession else {
            throw OnDeviceLLMError.modelNotDownloaded
        }

        do {
            let response = try await session.respond(to: prompt)
            logger.info("Generation completed, response length: \(response.count)")
            return response
        } catch {
            logger.error("Generation failed: \(error.localizedDescription)")
            throw OnDeviceLLMError.inferenceError(error.localizedDescription)
        }
        #else
        // Placeholder response for testing without LocalLLMClient
        try await Task.sleep(nanoseconds: 1_000_000_000) // Simulate processing
        return "LocalLLMClient package not installed. Please add the package to enable on-device inference."
        #endif
    }

    /// Generate text with streaming
    func generateStreaming(prompt: String, config: OnDeviceLLMConfig) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                guard self.isModelLoaded else {
                    continuation.finish(throwing: OnDeviceLLMError.modelNotDownloaded)
                    return
                }

                await MainActor.run {
                    self.isProcessing = true
                }

                #if canImport(LocalLLMClient)
                guard let session = self.llmSession else {
                    continuation.finish(throwing: OnDeviceLLMError.modelNotDownloaded)
                    return
                }

                do {
                    for try await text in session.streamResponse(to: prompt) {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OnDeviceLLMError.inferenceError(error.localizedDescription))
                }
                #else
                // Placeholder streaming for testing
                let words = ["This", " ", "is", " ", "a", " ", "placeholder", " ", "response."]
                for word in words {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continuation.yield(word)
                }
                continuation.finish()
                #endif

                await MainActor.run {
                    self.isProcessing = false
                }
            }
        }
    }

    // MARK: - Summarization

    /// Generate a summary from transcript text
    func generateSummary(from text: String, contentType: ContentType, config: OnDeviceLLMConfig) async throws -> String {
        let systemPrompt = createSystemPrompt(for: .summary, contentType: contentType)
        let userPrompt = createSummaryUserPrompt(text)
        let fullPrompt = formatPromptForGemma(system: systemPrompt, user: userPrompt)

        let response = try await generate(prompt: fullPrompt, config: config)
        return cleanResponse(response)
    }

    /// Process complete analysis (summary, tasks, reminders, titles)
    func processComplete(
        text: String,
        contentType: ContentType,
        config: OnDeviceLLMConfig
    ) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        let systemPrompt = createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = createCompleteUserPrompt(text)
        let fullPrompt = formatPromptForGemma(system: systemPrompt, user: userPrompt)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseCompleteResponse(response)
    }

    /// Extract tasks from text
    func extractTasks(from text: String, config: OnDeviceLLMConfig) async throws -> [TaskItem] {
        let systemPrompt = createSystemPrompt(for: .tasks, contentType: .general)
        let userPrompt = createTasksUserPrompt(text)
        let fullPrompt = formatPromptForGemma(system: systemPrompt, user: userPrompt)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseTasksResponse(response)
    }

    /// Extract reminders from text
    func extractReminders(from text: String, config: OnDeviceLLMConfig) async throws -> [ReminderItem] {
        let systemPrompt = createSystemPrompt(for: .reminders, contentType: .general)
        let userPrompt = createRemindersUserPrompt(text)
        let fullPrompt = formatPromptForGemma(system: systemPrompt, user: userPrompt)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseRemindersResponse(response)
    }

    /// Extract titles from text
    func extractTitles(from text: String, config: OnDeviceLLMConfig) async throws -> [TitleItem] {
        let systemPrompt = createSystemPrompt(for: .titles, contentType: .general)
        let userPrompt = createTitlesUserPrompt(text)
        let fullPrompt = formatPromptForGemma(system: systemPrompt, user: userPrompt)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseTitlesResponse(response)
    }

    /// Classify content type
    func classifyContent(_ text: String, config: OnDeviceLLMConfig) async throws -> ContentType {
        let prompt = """
        Classify the following text into one of these categories: meeting, personalJournal, technical, or general.
        Return ONLY the category name, nothing else.

        Text:
        \(text.prefix(2000))
        """

        let fullPrompt = formatPromptForGemma(system: "You are a content classifier.", user: prompt)
        let response = try await generate(prompt: fullPrompt, config: config)
        let cleaned = response.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.contains("meeting") { return .meeting }
        if cleaned.contains("personal") || cleaned.contains("journal") { return .personalJournal }
        if cleaned.contains("technical") { return .technical }
        return .general
    }

    // MARK: - Prompt Formatting

    private enum PromptType {
        case summary, tasks, reminders, titles, complete
    }

    /// Format prompt for Gemma-style models
    private func formatPromptForGemma(system: String, user: String) -> String {
        return """
        <start_of_turn>user
        \(system)

        \(user)<end_of_turn>
        <start_of_turn>model
        """
    }

    private func createSystemPrompt(for type: PromptType, contentType: ContentType) -> String {
        let basePrompt = """
        You are a medical AI assistant specialized in analyzing and summarizing audio transcripts and clinical conversations. Your role is to provide clear, actionable insights from the content provided.

        Key Guidelines:
        - Focus on extracting meaningful, actionable medical information
        - Maintain accuracy and clinical relevance
        - Use clear, professional medical language
        - Structure responses logically and coherently
        - Prioritize patient safety and important clinical findings
        """

        let contentTypePrompt = createContentTypePrompt(contentType)

        switch type {
        case .summary:
            return basePrompt + "\n\n" + contentTypePrompt + "\n\n" + """
            Summary Guidelines:
            - Create a comprehensive summary using Markdown formatting
            - Use **bold** for key clinical findings
            - Use headers for main sections
            - Use bullet points for lists
            - Focus on medically relevant content
            """
        case .tasks:
            return basePrompt + "\n\n" + """
            Task Extraction Guidelines:
            - Identify actionable medical tasks and follow-ups
            - Include specific deadlines when mentioned
            - Categorize tasks appropriately
            - Assign priority based on clinical urgency
            """
        case .reminders:
            return basePrompt + "\n\n" + """
            Reminder Extraction Guidelines:
            - Identify time-sensitive medical items
            - Focus on appointments, medications, and follow-ups
            - Include specific dates and times
            """
        case .titles:
            return basePrompt + "\n\n" + """
            Title Generation Guidelines:
            - Generate concise, descriptive titles (20-50 characters)
            - Capture the main medical topic or patient concern
            - Use proper capitalization
            """
        case .complete:
            return basePrompt + "\n\n" + contentTypePrompt
        }
    }

    private func createContentTypePrompt(_ contentType: ContentType) -> String {
        switch contentType {
        case .meeting:
            return "Focus on clinical meeting outcomes, decisions, and action items."
        case .personalJournal:
            return "Focus on patient symptoms, personal health observations, and wellbeing."
        case .technical:
            return "Focus on technical medical details, procedures, and specifications."
        case .general:
            return "Provide a balanced analysis of the medical content."
        }
    }

    private func createSummaryUserPrompt(_ text: String) -> String {
        return """
        Please provide a comprehensive summary of the following medical content using Markdown formatting:

        \(text)
        """
    }

    private func createCompleteUserPrompt(_ text: String) -> String {
        return """
        Please analyze the following content and provide a comprehensive response in VALID JSON format only.

        {
            "summary": "A detailed summary using Markdown formatting",
            "tasks": [
                {
                    "text": "task description",
                    "priority": "high|medium|low",
                    "category": "call|meeting|purchase|research|email|travel|health|general",
                    "timeReference": "specific date or null",
                    "confidence": 0.85
                }
            ],
            "reminders": [
                {
                    "text": "reminder description",
                    "urgency": "immediate|today|thisWeek|later",
                    "timeReference": "specific time or date",
                    "confidence": 0.85
                }
            ],
            "titles": [
                {
                    "text": "descriptive title",
                    "category": "meeting|personal|technical|general",
                    "confidence": 0.85
                }
            ]
        }

        Return ONLY valid JSON, no additional text.

        Content:
        \(text)
        """
    }

    private func createTasksUserPrompt(_ text: String) -> String {
        return """
        Extract actionable tasks from the following content. Return as JSON array:
        [{"text": "task", "priority": "high|medium|low", "category": "general", "timeReference": null, "confidence": 0.85}]

        Content:
        \(text)
        """
    }

    private func createRemindersUserPrompt(_ text: String) -> String {
        return """
        Extract reminders from the following content. Return as JSON array:
        [{"text": "reminder", "urgency": "today|thisWeek|later", "timeReference": "date", "confidence": 0.85}]

        Content:
        \(text)
        """
    }

    private func createTitlesUserPrompt(_ text: String) -> String {
        return """
        Generate 4 descriptive titles for the following content. Return as JSON:
        {"titles": [{"text": "title", "category": "general", "confidence": 0.85}]}

        Content:
        \(text.prefix(2000))
        """
    }

    // MARK: - Response Parsing

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Remove common artifacts
        cleaned = cleaned.replacingOccurrences(of: "<end_of_turn>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "<start_of_turn>", with: "")
        cleaned = cleaned.replacingOccurrences(of: "model", with: "", options: .anchored)

        // Remove thinking blocks if present
        if let thinkStart = cleaned.range(of: "<think>"),
           let thinkEnd = cleaned.range(of: "</think>") {
            cleaned.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractJSON(from response: String) -> String? {
        let cleaned = cleanResponse(response)

        // Try to find JSON object
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }

        // Try to find JSON array
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]") {
            return String(cleaned[start...end])
        }

        return nil
    }

    private func parseCompleteResponse(_ response: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        guard let jsonString = extractJSON(from: response),
              let data = jsonString.data(using: .utf8) else {
            // Return just the cleaned response as summary if JSON parsing fails
            return (cleanResponse(response), [], [], [])
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            let summary = json?["summary"] as? String ?? cleanResponse(response)
            let tasks = try parseTasksFromJSON(json?["tasks"])
            let reminders = try parseRemindersFromJSON(json?["reminders"])
            let titles = try parseTitlesFromJSON(json?["titles"])

            return (summary, tasks, reminders, titles)
        } catch {
            logger.warning("JSON parsing failed, returning raw summary: \(error.localizedDescription)")
            return (cleanResponse(response), [], [], [])
        }
    }

    private func parseTasksResponse(_ response: String) throws -> [TaskItem] {
        guard let jsonString = extractJSON(from: response),
              let data = jsonString.data(using: .utf8) else {
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data)
        return try parseTasksFromJSON(json)
    }

    private func parseRemindersResponse(_ response: String) throws -> [ReminderItem] {
        guard let jsonString = extractJSON(from: response),
              let data = jsonString.data(using: .utf8) else {
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data)
        return try parseRemindersFromJSON(json)
    }

    private func parseTitlesResponse(_ response: String) throws -> [TitleItem] {
        guard let jsonString = extractJSON(from: response),
              let data = jsonString.data(using: .utf8) else {
            return []
        }

        let json = try JSONSerialization.jsonObject(with: data)

        // Handle both {titles: [...]} and direct array format
        if let dict = json as? [String: Any], let titles = dict["titles"] {
            return try parseTitlesFromJSON(titles)
        }
        return try parseTitlesFromJSON(json)
    }

    private func parseTasksFromJSON(_ json: Any?) throws -> [TaskItem] {
        guard let array = json as? [[String: Any]] else { return [] }

        return array.compactMap { item -> TaskItem? in
            guard let text = item["text"] as? String else { return nil }

            let priorityString = (item["priority"] as? String)?.lowercased() ?? "medium"
            let priority: TaskPriority
            switch priorityString {
            case "high": priority = .high
            case "low": priority = .low
            default: priority = .medium
            }

            let categoryString = (item["category"] as? String)?.lowercased() ?? "general"
            let category: TaskCategory
            switch categoryString {
            case "call": category = .call
            case "email": category = .email
            case "meeting": category = .meeting
            case "purchase": category = .purchase
            case "research": category = .research
            case "travel": category = .travel
            case "health": category = .health
            default: category = .general
            }

            return TaskItem(
                text: text,
                priority: priority,
                timeReference: item["timeReference"] as? String,
                category: category,
                confidence: item["confidence"] as? Double ?? 0.8
            )
        }
    }

    private func parseRemindersFromJSON(_ json: Any?) throws -> [ReminderItem] {
        guard let array = json as? [[String: Any]] else { return [] }

        return array.compactMap { item -> ReminderItem? in
            guard let text = item["text"] as? String else { return nil }

            let urgencyString = (item["urgency"] as? String)?.lowercased() ?? "later"
            let urgency: ReminderUrgency
            switch urgencyString {
            case "immediate": urgency = .immediate
            case "today": urgency = .today
            case "thisweek", "this_week": urgency = .thisWeek
            default: urgency = .later
            }

            return ReminderItem(
                text: text,
                timeReference: item["timeReference"] as? String,
                urgency: urgency,
                confidence: item["confidence"] as? Double ?? 0.8
            )
        }
    }

    private func parseTitlesFromJSON(_ json: Any?) throws -> [TitleItem] {
        guard let array = json as? [[String: Any]] else { return [] }

        return array.compactMap { item -> TitleItem? in
            guard let text = item["text"] as? String else { return nil }

            let categoryString = (item["category"] as? String)?.lowercased() ?? "general"
            let category: TitleCategory
            switch categoryString {
            case "meeting": category = .meeting
            case "personal": category = .personal
            case "technical": category = .technical
            default: category = .general
            }

            return TitleItem(
                text: text,
                confidence: item["confidence"] as? Double ?? 0.8,
                category: category
            )
        }
    }
}

// MARK: - Connection Testing

extension OnDeviceLLMService {
    /// Test if a model can be loaded and used
    func testModel(modelID: String, quantization: OnDeviceLLMQuantization) async -> Bool {
        guard let model = OnDeviceLLMModel.model(byID: modelID) else {
            return false
        }

        guard downloadManager.isModelDownloaded(model, quantization: quantization) else {
            return false
        }

        do {
            try await loadModel(modelID: modelID, quantization: quantization)
            return isModelLoaded
        } catch {
            logger.error("Model test failed: \(error.localizedDescription)")
            return false
        }
    }
}
