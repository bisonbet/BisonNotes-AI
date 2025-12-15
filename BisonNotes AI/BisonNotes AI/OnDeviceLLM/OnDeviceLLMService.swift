//
//  OnDeviceLLMService.swift
//  BisonNotes AI
//
//  Service for running inference on locally downloaded LLM models using LocalLLMClient
//
//  IMPORTANT: Required Dependencies and Configuration
//  ==================================================
//
//  1. Swift Package Dependency:
//     - Package: LocalLLMClient
//     - URL: https://github.com/bisonbet/LocalLLMClient-iOS
//     - Branch: main (no version pinning)
//     - Add via: Xcode → File → Add Package Dependencies
//
//  2. Required Entitlement:
//     - com.apple.developer.kernel.increased-memory-limit = true
//     - Required for loading ~3GB models into memory
//     - May require Apple review approval for App Store distribution
//
//  3. Without LocalLLMClient package:
//     - All methods return placeholder/error responses
//     - App compiles successfully with conditional import (#if canImport)
//

import Foundation
import os.log
import UIKit

// LocalLLMClient must be added as a Swift Package dependency for on-device inference
// Without it, placeholder implementations are used (see #else blocks below)

#if canImport(LocalLLMClient)
import LocalLLMClient
import LocalLLMClientLlama
#endif

// MARK: - On-Device LLM Service

@MainActor
class OnDeviceLLMService: ObservableObject {
    static let shared = OnDeviceLLMService()

    // MARK: - Constants

    private enum Constants {
        /// Maximum characters to use for content classification to avoid excessive processing
        static let classificationTextLimit = 2000
        /// Maximum characters to use for title generation prompts
        static let titleGenerationTextLimit = 2000
        /// Maximum model file size in bytes (5GB limit for memory safety)
        static let maxModelFileSizeBytes: Int64 = 5_000_000_000
        /// Delay between chunk processing in nanoseconds to manage memory
        static let chunkProcessingDelayNs: UInt64 = 500_000_000
    }

    // MARK: - Published Properties

    @Published private(set) var isModelLoaded: Bool = false
    @Published private(set) var isProcessing: Bool = false
    @Published private(set) var currentModelID: String?
    @Published private(set) var lastError: String?
    @Published private(set) var lastParsingWarning: String?
    private var isModelLoading: Bool = false

    // MARK: - Private Properties

    private let logger = Logger(subsystem: "com.bisonnotes.ai", category: "OnDeviceLLM")
    private let downloadManager = ModelDownloadManager.shared

    #if canImport(LocalLLMClient)
    private var llmSession: LLMSession?
    #endif

    // MARK: - Initialization

    private init() {
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Memory Management

    @objc private func handleMemoryWarning() {
        logger.warning("Received memory warning")
        // Only unload if not currently processing
        if !isProcessing {
            logger.info("Unloading model due to memory pressure")
            unloadModel()
        } else {
            logger.warning("Cannot unload model - processing in progress")
        }
    }

    // MARK: - Model Loading

    /// Load a model for inference
    func loadModel(modelID: String, quantization: OnDeviceLLMQuantization) async throws {
        // Prevent concurrent model loading
        guard !isModelLoading else {
            logger.warning("Model loading already in progress, waiting...")
            // Wait for current load to complete
            while isModelLoading {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
            // Check if the requested model is now loaded
            if isModelLoaded && currentModelID == modelID {
                return
            }
            // If a different model was loaded, proceed with loading the requested one
        }

        isModelLoading = true
        defer { isModelLoading = false }

        guard let model = OnDeviceLLMModel.model(byID: modelID) else {
            throw OnDeviceLLMError.modelNotFound(modelID)
        }

        guard let modelPath = downloadManager.modelFilePath(for: model, quantization: quantization) else {
            throw OnDeviceLLMError.modelNotDownloaded
        }

        // Validate file size before loading to prevent memory issues
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: modelPath.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            logger.info("Loading model: \(modelID) (\(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)))")

            guard fileSize <= Constants.maxModelFileSizeBytes else {
                logger.error("Model file too large: \(fileSize) bytes (max: \(Constants.maxModelFileSizeBytes))")
                throw OnDeviceLLMError.modelTooLarge(fileSize)
            }
        } catch let error as OnDeviceLLMError {
            throw error
        } catch {
            logger.error("Failed to get file attributes: \(error.localizedDescription)")
            throw OnDeviceLLMError.modelLoadFailed
        }

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
            lastError = "Failed to load model"
            logger.error("Model load error: \(error.localizedDescription)")
            throw OnDeviceLLMError.modelLoadFailed
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
            throw OnDeviceLLMError.inferenceError
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
                    logger.error("Streaming generation failed: \(error.localizedDescription)")
                    continuation.finish(throwing: OnDeviceLLMError.inferenceError)
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
        let fullPrompt = formatPrompt(system: systemPrompt, user: userPrompt, config: config)

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
        let fullPrompt = formatPrompt(system: systemPrompt, user: userPrompt, config: config)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseCompleteResponse(response)
    }

    /// Extract tasks from text
    func extractTasks(from text: String, config: OnDeviceLLMConfig) async throws -> [TaskItem] {
        let systemPrompt = createSystemPrompt(for: .tasks, contentType: .general)
        let userPrompt = createTasksUserPrompt(text)
        let fullPrompt = formatPrompt(system: systemPrompt, user: userPrompt, config: config)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseTasksResponse(response)
    }

    /// Extract reminders from text
    func extractReminders(from text: String, config: OnDeviceLLMConfig) async throws -> [ReminderItem] {
        let systemPrompt = createSystemPrompt(for: .reminders, contentType: .general)
        let userPrompt = createRemindersUserPrompt(text)
        let fullPrompt = formatPrompt(system: systemPrompt, user: userPrompt, config: config)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseRemindersResponse(response)
    }

    /// Extract titles from text
    func extractTitles(from text: String, config: OnDeviceLLMConfig) async throws -> [TitleItem] {
        let systemPrompt = createSystemPrompt(for: .titles, contentType: .general)
        let userPrompt = createTitlesUserPrompt(text)
        let fullPrompt = formatPrompt(system: systemPrompt, user: userPrompt, config: config)

        let response = try await generate(prompt: fullPrompt, config: config)
        return try parseTitlesResponse(response)
    }

    /// Classify content type
    func classifyContent(_ text: String, config: OnDeviceLLMConfig) async throws -> ContentType {
        let prompt = """
        Classify the following text into one of these categories: meeting, personalJournal, technical, or general.
        Return ONLY the category name, nothing else.

        Text:
        \(text.prefix(Constants.classificationTextLimit))
        """

        let fullPrompt = formatPrompt(system: "You are a content classifier.", user: prompt, config: config)
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

    /// Format prompt based on model's prompt template
    private func formatPrompt(system: String, user: String, config: OnDeviceLLMConfig) -> String {
        guard let model = OnDeviceLLMModel.model(byID: config.modelID) else {
            // Default to Mistral format
            return formatPromptForMistral(system: system, user: user)
        }

        switch model.promptTemplate {
        case .mistral:
            return formatPromptForMistral(system: system, user: user)
        case .granite:
            return formatPromptForGranite(system: system, user: user)
        case .llama:
            return formatPromptForLlama(system: system, user: user)
        case .chatml:
            return formatPromptForChatML(system: system, user: user)
        }
    }

    /// Format prompt for Mistral-style models
    private func formatPromptForMistral(system: String, user: String) -> String {
        return """
        [INST] \(system)

        \(user) [/INST]
        """
    }

    /// Format prompt for Granite-style models
    private func formatPromptForGranite(system: String, user: String) -> String {
        return """
        <|system|>
        \(system)
        <|user|>
        \(user)
        <|assistant|>
        """
    }

    /// Format prompt for Llama-style models
    private func formatPromptForLlama(system: String, user: String) -> String {
        return """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(system)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

        """
    }

    /// Format prompt for ChatML-style models
    private func formatPromptForChatML(system: String, user: String) -> String {
        return """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant
        """
    }

    private func createSystemPrompt(for type: PromptType, contentType: ContentType) -> String {
        let basePrompt = """
        You are an AI assistant specialized in analyzing and summarizing audio transcripts and conversations. Your role is to provide clear, actionable insights from the content provided.

        Key Guidelines:
        - Focus on extracting meaningful, actionable information
        - Maintain accuracy and relevance to the source material
        - Use clear, professional language
        - Structure responses logically and coherently
        - Prioritize the most important information first
        """

        let contentTypePrompt = createContentTypePrompt(contentType)

        switch type {
        case .summary:
            return basePrompt + "\n\n" + contentTypePrompt + "\n\n" + """
            Summary Guidelines:
            - Create a comprehensive summary using Markdown formatting
            - Use **bold** for key points and important information
            - Use headers for main sections
            - Use bullet points for lists
            - Focus on the most relevant content
            """
        case .tasks:
            return basePrompt + "\n\n" + """
            Task Extraction Guidelines:
            - Identify actionable tasks and to-dos
            - Include specific deadlines when mentioned
            - Categorize tasks appropriately
            - Assign priority based on urgency and importance
            """
        case .reminders:
            return basePrompt + "\n\n" + """
            Reminder Extraction Guidelines:
            - Identify time-sensitive items and deadlines
            - Focus on appointments, meetings, and scheduled events
            - Include specific dates and times
            """
        case .titles:
            return basePrompt + "\n\n" + """
            Title Generation Guidelines:
            - Generate concise, descriptive titles (20-50 characters)
            - Capture the main topic or key subject
            - Use proper capitalization
            """
        case .complete:
            return basePrompt + "\n\n" + contentTypePrompt
        }
    }

    private func createContentTypePrompt(_ contentType: ContentType) -> String {
        switch contentType {
        case .meeting:
            return "Focus on meeting outcomes, decisions, and action items."
        case .personalJournal:
            return "Focus on personal insights, reflections, and goals."
        case .technical:
            return "Focus on technical details, specifications, and procedures."
        case .general:
            return "Provide a balanced analysis of the content."
        }
    }

    private func createSummaryUserPrompt(_ text: String) -> String {
        return """
        Please provide a comprehensive summary of the following content using Markdown formatting:

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
        \(text.prefix(Constants.titleGenerationTextLimit))
        """
    }

    // MARK: - Response Parsing

    private func cleanResponse(_ response: String) -> String {
        var cleaned = response

        // Define all artifacts to remove in a single array for efficient processing
        let artifacts = [
            "[INST]", "[/INST]",
            "<|system|>", "<|user|>", "<|assistant|>", "<|end|>",
            "<|begin_of_text|>", "<|start_header_id|>", "<|end_header_id|>", "<|eot_id|>",
            "<|im_start|>", "<|im_end|>",
            "<end_of_turn>", "<start_of_turn>"
        ]

        // Remove all artifacts in a single pass
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }

        // Remove role labels at start
        let roleLabels = ["model", "assistant", "system", "user"]
        for label in roleLabels {
            cleaned = cleaned.replacingOccurrences(of: label, with: "", options: .anchored)
        }

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
            // Set warning for user visibility
            lastParsingWarning = "Could not extract structured data. Returning summary only."
            logger.warning("JSON extraction failed from response")
            return (cleanResponse(response), [], [], [])
        }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            let summary = json?["summary"] as? String ?? cleanResponse(response)
            let tasks = try parseTasksFromJSON(json?["tasks"])
            let reminders = try parseRemindersFromJSON(json?["reminders"])
            let titles = try parseTitlesFromJSON(json?["titles"])

            // Clear warning on successful parse
            lastParsingWarning = nil
            return (summary, tasks, reminders, titles)
        } catch {
            // Set warning for user visibility
            lastParsingWarning = "Could not extract tasks and reminders. Returning summary only."
            logger.warning("JSON parsing failed: \(error.localizedDescription)")
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
