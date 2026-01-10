//
//  OnDeviceLLMService.swift
//  BisonNotes AI
//
//  Service layer for on-device LLM operations
//  Handles summarization, task extraction, and reminder extraction
//

import Foundation

// MARK: - Service Configuration

/// Configuration for the on-device LLM service
public struct OnDeviceLLMConfig {
    public let modelInfo: OnDeviceLLMModelInfo
    public let temperature: Float
    public let maxTokens: Int
    public let topK: Int32
    public let topP: Float
    public let minP: Float
    public let repeatPenalty: Float

    public init(
        modelInfo: OnDeviceLLMModelInfo = OnDeviceLLMModelInfo.selectedModel,
        temperature: Float = OnDeviceLLMModelInfo.configuredTemperature,
        maxTokens: Int = OnDeviceLLMModelInfo.configuredMaxTokens,
        topK: Int32 = OnDeviceLLMModelInfo.configuredTopK,
        topP: Float = OnDeviceLLMModelInfo.configuredTopP,
        minP: Float = OnDeviceLLMModelInfo.configuredMinP,
        repeatPenalty: Float = OnDeviceLLMModelInfo.configuredRepeatPenalty
    ) {
        self.modelInfo = modelInfo
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
    }

    /// Create config from current UserDefaults settings
    public static var current: OnDeviceLLMConfig {
        OnDeviceLLMConfig()
    }
}

// MARK: - On-Device LLM Service

/// Service class for performing on-device LLM inference
public class OnDeviceLLMService: ObservableObject {

    // MARK: - Properties

    private var llm: OnDeviceLLM?
    private var config: OnDeviceLLMConfig
    private var isLoaded = false
    @Published public var lastMetrics: InferenceMetrics?

    // MARK: - Initialization

    public init(config: OnDeviceLLMConfig = .current) {
        self.config = config
    }

    // MARK: - Model Loading

    /// Load the LLM model into memory
    public func loadModel() throws {
        guard config.modelInfo.isDownloaded else {
            throw OnDeviceLLMError.modelNotDownloaded
        }

        let modelURL = config.modelInfo.fileURL
        let template = config.modelInfo.templateType.template(
            systemPrompt: LLMTemplate.summarizationSystemPrompt
        )

        llm = OnDeviceLLM(
            from: modelURL,
            template: template,
            topK: config.topK,
            topP: config.topP,
            minP: config.minP,
            temp: config.temperature,
            repeatPenalty: config.repeatPenalty,
            maxTokenCount: Int32(config.maxTokens)
        )

        isLoaded = true
        print("[OnDeviceLLMService] Model loaded: \(config.modelInfo.displayName)")
    }

    /// Unload the model from memory
    public func unloadModel() {
        llm = nil
        isLoaded = false
        print("[OnDeviceLLMService] Model unloaded")
    }

    /// Check if a model is loaded
    public var isModelLoaded: Bool {
        isLoaded && llm != nil
    }

    // MARK: - Summarization

    /// Generate a summary from transcript text
    func generateSummary(from text: String, contentType: ContentType = .general) async throws -> String {
        try ensureModelLoaded()
        guard let llm = llm else { throw OnDeviceLLMError.modelNotLoaded }

        // Create summarization prompt
        let prompt = createSummarizationPrompt(text: text, contentType: contentType)

        // Update template with summarization system prompt
        llm.template = config.modelInfo.templateType.template(
            systemPrompt: LLMTemplate.summarizationSystemPrompt
        )

        // Generate response
        let result = await llm.generate(from: prompt)

        // Store metrics
        lastMetrics = llm.metrics

        return cleanupResponse(result)
    }

    // MARK: - Task Extraction

    /// Extract tasks from transcript text
    func extractTasks(from text: String) async throws -> [TaskItem] {
        try ensureModelLoaded()
        guard let llm = llm else { throw OnDeviceLLMError.modelNotLoaded }

        let prompt = createTaskExtractionPrompt(text: text)

        llm.template = config.modelInfo.templateType.template(
            systemPrompt: LLMTemplate.taskExtractionSystemPrompt
        )

        let result = await llm.generate(from: prompt)
        lastMetrics = llm.metrics

        return parseTasksFromResponse(result)
    }

    // MARK: - Reminder Extraction

    /// Extract reminders from transcript text
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        try ensureModelLoaded()
        guard let llm = llm else { throw OnDeviceLLMError.modelNotLoaded }

        let prompt = createReminderExtractionPrompt(text: text)

        llm.template = config.modelInfo.templateType.template(
            systemPrompt: LLMTemplate.reminderExtractionSystemPrompt
        )

        let result = await llm.generate(from: prompt)
        lastMetrics = llm.metrics

        return parseRemindersFromResponse(result)
    }

    // MARK: - Title Extraction

    /// Extract suggested titles from transcript text
    func extractTitles(from text: String) async throws -> [TitleItem] {
        try ensureModelLoaded()
        guard let llm = llm else { throw OnDeviceLLMError.modelNotLoaded }

        let prompt = createTitleExtractionPrompt(text: text)

        llm.template = config.modelInfo.templateType.template(
            systemPrompt: nil
        )

        let result = await llm.generate(from: prompt)
        lastMetrics = llm.metrics

        return parseTitlesFromResponse(result)
    }

    // MARK: - Complete Processing

    /// Process transcript with all extractions in one call
    func processComplete(text: String) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        try ensureModelLoaded()
        guard let llm = llm else { throw OnDeviceLLMError.modelNotLoaded }

        // First, classify the content
        let contentType = classifyContent(text)

        // Create comprehensive prompt
        let prompt = createCompleteProcessingPrompt(text: text)

        llm.template = config.modelInfo.templateType.template(
            systemPrompt: LLMTemplate.completeProcessingSystemPrompt
        )

        let result = await llm.generate(from: prompt)
        lastMetrics = llm.metrics

        // Parse the comprehensive response
        let parsed = parseCompleteResponse(result)

        return (
            summary: parsed.summary.isEmpty ? cleanupResponse(result) : parsed.summary,
            tasks: parsed.tasks,
            reminders: parsed.reminders,
            titles: parsed.titles,
            contentType: contentType
        )
    }

    // MARK: - Private Helpers

    private func ensureModelLoaded() throws {
        if !isModelLoaded {
            try loadModel()
        }
    }

    private func classifyContent(_ text: String) -> ContentType {
        // Use keyword-based classification
        return ContentAnalyzer.classifyContent(text)
    }

    private func cleanupResponse(_ response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove any remaining template tokens that might have leaked
        let tokensToRemove = ["<|im_end|>", "<|im_start|>", "<|end|>", "<|assistant|>", "<|user|>", "<|system|>"]
        for token in tokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }

        // Sanitize encoding issues (Unicode replacement chars, smart quotes, etc.)
        cleaned = cleaned.sanitizedForDisplay()

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt Creation

    private func createSummarizationPrompt(text: String, contentType: ContentType) -> String {
        """
        Please create a comprehensive summary of the following \(contentType.rawValue) transcript using proper Markdown formatting:

        - Use **bold** for key points and important information
        - Use *italic* for emphasis
        - Use ## headers for main sections
        - Use bullet points for lists
        - Be concise but thorough

        Transcript:
        \(text)

        Summary:
        """
    }

    private func createTaskExtractionPrompt(text: String) -> String {
        """
        Extract all actionable tasks from the following transcript. Focus only on personal, actionable items that require follow-up.

        Return each task on a new line, starting with "- "

        Transcript:
        \(text)

        Tasks:
        """
    }

    private func createReminderExtractionPrompt(text: String) -> String {
        """
        Extract all time-sensitive reminders and deadlines from the following transcript. Include dates, times, and deadlines mentioned.

        Return each reminder on a new line, starting with "- "

        Transcript:
        \(text)

        Reminders:
        """
    }

    private func createTitleExtractionPrompt(text: String) -> String {
        """
        Suggest 3-5 concise, descriptive titles for the following transcript. Each title should capture the main topic or theme.

        Return each title on a new line, starting with "- "

        Transcript:
        \(text)

        Suggested titles:
        """
    }

    private func createCompleteProcessingPrompt(text: String) -> String {
        """
        Analyze the following transcript and provide:

        1. A comprehensive summary using Markdown formatting
        2. A list of actionable tasks (personal items only)
        3. Time-sensitive reminders and deadlines
        4. 3-5 suggested titles

        Format your response with clear sections:

        ## Summary
        [Your summary here]

        ## Tasks
        - [Task 1]
        - [Task 2]

        ## Reminders
        - [Reminder 1]
        - [Reminder 2]

        ## Suggested Titles
        - [Title 1]
        - [Title 2]

        Transcript:
        \(text)
        """
    }

    // MARK: - Response Parsing

    private func parseTasksFromResponse(_ response: String) -> [TaskItem] {
        let lines = response.sanitizedForDisplay().components(separatedBy: .newlines)
        var tasks: [TaskItem] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                let taskText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText()
                if !taskText.isEmpty && taskText.count > 3 {
                    tasks.append(TaskItem(text: taskText, priority: .medium, confidence: 0.8))
                }
            }
        }

        return Array(tasks.prefix(15))
    }

    private func parseRemindersFromResponse(_ response: String) -> [ReminderItem] {
        let lines = response.sanitizedForDisplay().components(separatedBy: .newlines)
        var reminders: [ReminderItem] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                let reminderText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText()
                if !reminderText.isEmpty && reminderText.count > 3 {
                    let timeRef = ReminderItem.TimeReference.fromReminderText(reminderText)
                    reminders.append(ReminderItem(text: reminderText, timeReference: timeRef, urgency: .later, confidence: 0.8))
                }
            }
        }

        return Array(reminders.prefix(15))
    }

    private func parseTitlesFromResponse(_ response: String) -> [TitleItem] {
        let lines = response.sanitizedForDisplay().components(separatedBy: .newlines)
        var titles: [TitleItem] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                // Use sanitizedForTitle() to also strip wrapping quotes
                let titleText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForTitle()
                if !titleText.isEmpty && titleText.count > 3 && titleText.count < 100 {
                    titles.append(TitleItem(text: titleText, confidence: 0.8))
                }
            }
        }

        return Array(titles.prefix(5))
    }

    private func parseCompleteResponse(_ response: String) -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        var summary = ""
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []
        var titles: [TitleItem] = []

        var currentSection = ""
        // Sanitize the entire response first
        let sanitizedResponse = response.sanitizedForDisplay()
        let lines = sanitizedResponse.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()

            // Detect section headers
            if lowercased.contains("## summary") || lowercased.hasPrefix("summary:") {
                currentSection = "summary"
                continue
            } else if lowercased.contains("## tasks") || lowercased.hasPrefix("tasks:") {
                currentSection = "tasks"
                continue
            } else if lowercased.contains("## reminders") || lowercased.hasPrefix("reminders:") {
                currentSection = "reminders"
                continue
            } else if lowercased.contains("## suggested titles") || lowercased.contains("## titles") || lowercased.hasPrefix("titles:") {
                currentSection = "titles"
                continue
            }

            // Process based on current section
            switch currentSection {
            case "summary":
                if !trimmed.isEmpty && !trimmed.hasPrefix("##") {
                    summary += (summary.isEmpty ? "" : "\n") + trimmed
                }
            case "tasks":
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") {
                    let text = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText()
                    if !text.isEmpty {
                        tasks.append(TaskItem(text: text, priority: .medium, confidence: 0.8))
                    }
                }
            case "reminders":
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") {
                    let text = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText()
                    if !text.isEmpty {
                        let timeRef = ReminderItem.TimeReference.fromReminderText(text)
                        reminders.append(ReminderItem(text: text, timeReference: timeRef, urgency: .later, confidence: 0.8))
                    }
                }
            case "titles":
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") {
                    // Use sanitizedForTitle() to also strip wrapping quotes
                    let text = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForTitle()
                    if !text.isEmpty && text.count < 100 {
                        titles.append(TitleItem(text: text, confidence: 0.8))
                    }
                }
            default:
                // If no section detected yet, assume it's summary
                if !trimmed.isEmpty && !trimmed.hasPrefix("##") {
                    summary += (summary.isEmpty ? "" : "\n") + trimmed
                }
            }
        }

        return (summary, tasks, reminders, titles)
    }
}

// MARK: - Connection Testing

extension OnDeviceLLMService {

    /// Test if the model can be loaded and run
    public func testConnection() async -> Bool {
        do {
            try ensureModelLoaded()
            guard let llm = llm else { return false }

            // Simple test prompt
            let testPrompt = "Say 'OK' if you're working."
            llm.template = config.modelInfo.templateType.template(systemPrompt: nil)

            let result = await llm.generate(from: testPrompt)
            return !result.isEmpty

        } catch {
            print("[OnDeviceLLMService] Connection test failed: \(error)")
            return false
        }
    }
}
