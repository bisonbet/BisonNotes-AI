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
        // Use LFM-specific system prompt for LFM models to prevent hallucinated tokens
        let systemPrompt = config.modelInfo.templateType == .lfm ?
            LLMTemplate.lfmSummarizationSystemPrompt :
            LLMTemplate.summarizationSystemPrompt
        let template = config.modelInfo.templateType.template(systemPrompt: systemPrompt)

        // Use device-appropriate context size based on RAM
        // 8k for devices with <8GB RAM, 16k for devices with >=8GB RAM
        let deviceContextSize = DeviceCapabilities.onDeviceLLMContextSize
        let contextSize = Int32(min(config.modelInfo.contextWindow, deviceContextSize))

        llm = OnDeviceLLM(
            from: modelURL,
            template: template,
            topK: config.topK,
            topP: config.topP,
            minP: config.minP,
            temp: config.temperature,
            repeatPenalty: config.repeatPenalty,
            maxTokenCount: contextSize,
            maxOutputTokens: 2700  // Hard limit to prevent infinite generation (~2,000 words)
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

    // MARK: - Token Counting

    /// Get accurate token count using the actual model tokenizer
    /// Requires model to be loaded
    public func getAccurateTokenCount(_ text: String) throws -> Int {
        guard let llm = llm else {
            throw OnDeviceLLMError.modelNotLoaded
        }
        let tokens = llm.encode(text)
        return tokens.count
    }

    // MARK: - Summarization

    /// Generate a summary from transcript text
    func generateSummary(from text: String, contentType: ContentType = .general) async throws -> String {
        try ensureModelLoaded()
        guard let llm = llm else { throw OnDeviceLLMError.modelNotLoaded }

        // Create summarization prompt
        let prompt = createSummarizationPrompt(text: text, contentType: contentType)

        // Update template with summarization system prompt
        // Use LFM-specific system prompt for LFM models to prevent hallucinated tokens
        let systemPrompt = config.modelInfo.templateType == .lfm ?
            LLMTemplate.lfmSummarizationSystemPrompt :
            LLMTemplate.summarizationSystemPrompt
        llm.template = config.modelInfo.templateType.template(systemPrompt: systemPrompt)

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

        // Clear model history before processing to ensure clean state
        // This is especially important when re-running on transcripts
        await llm.clearHistory()

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

    /// Ensure the model is loaded. Public for use in chunking operations.
    public func ensureModelLoaded() throws {
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
        // Include Gemma3-specific tokens
        let tokensToRemove = [
            "<|im_end|>", "<|im_start|>", "<|end|>", 
            "<|assistant|>", "<|user|>", "<|system|>",
            "<end_of_turn>", "<start_of_turn>", "<eos>",
            "<start_of_turn>user", "<start_of_turn>model"
        ]
        for token in tokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
        }

        // Sanitize encoding issues (Unicode replacement chars, smart quotes, etc.)
        cleaned = cleaned.sanitizedForDisplay()

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt Creation

    private func createSummarizationPrompt(text: String, contentType: ContentType) -> String {
        // Calculate approx 15% target length in words (min 200 words) to encourage longer output
        let wordCount = text.split(separator: " ").count
        let targetWords = max(200, Int(Double(wordCount) * 0.15))
        
        return """
        Please analyze the following \(contentType.rawValue) transcript and create a DETAILED STRUCTURED OUTLINE.
        
        CRITICAL REQUIREMENTS:
        - The summary MUST be approximately \(targetWords) words long.
        - Use a hierarchical outline format with clear sections.
        - Do NOT be concise. Capture all important details, facts, and nuances.

        REQUIRED SECTIONS:
        ## 1. Overview
        (A comprehensive high-level summary of the main topic)

        ## 2. Key Facts & Details
        (Detailed bullet points capturing specific facts, numbers, dates, and names)
        - Point 1...
        - Point 2...

        ## 3. Important Notes
        (Any specific context, observations, or important nuances mentioned)

        ## 4. Action Items & Conclusions
        (What needs to be done, decisions made, or final thoughts)

        Transcript:
        \(text)

        Structured Outline:
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
        // Calculate approx 15% target length in words (min 200 words) to encourage longer output
        let wordCount = text.split(separator: " ").count
        let targetWords = max(200, Int(Double(wordCount) * 0.15))

        return """
        Analyze the following transcript and provide:

        1. A STRUCTURED OUTLINE SUMMARY
           - CRITICAL: The summary must be approximately \(targetWords) words long.
           - Use sections: Overview, Key Facts, Important Notes, Conclusions.
           - Expand on details using nested bullet points.
        2. A list of actionable tasks (personal items only)
        3. Time-sensitive reminders and deadlines
        4. 3-5 suggested titles

        Format your response with clear sections:

        ## Summary
        ### 1. Overview
        [Detailed overview paragraph]
        ### 2. Key Facts & Details
        - [Fact 1]
        - [Fact 2]
        ### 3. Important Notes
        - [Note 1]
        ### 4. Conclusions
        [Final thoughts]

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
                let taskText = RecordingNameGenerator.cleanAIOutput(trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText())
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
                let reminderText = RecordingNameGenerator.cleanAIOutput(trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText())
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
                // Use standardized cleaning
                let titleText = RecordingNameGenerator.cleanStandardizedTitleResponse(trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForTitle())
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
        // Sanitize the entire response first, including Gemma3 tokens
        var sanitizedResponse = response.sanitizedForDisplay()
        
        // Remove Gemma3-specific tokens that might interfere with parsing
        let gemmaTokens = ["<end_of_turn>", "<start_of_turn>", "<eos>"]
        for token in gemmaTokens {
            sanitizedResponse = sanitizedResponse.replacingOccurrences(of: token, with: "")
        }
        
        let lines = sanitizedResponse.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()

            // Detect section headers - be more flexible with variations
            if lowercased.contains("## summary") || lowercased.hasPrefix("summary:") || 
               (lowercased.contains("summary") && lowercased.contains("##")) {
                currentSection = "summary"
                continue
            } else if lowercased.contains("## tasks") || lowercased.hasPrefix("tasks:") ||
                      (lowercased.contains("task") && (lowercased.contains("##") || lowercased.hasPrefix("task"))) {
                currentSection = "tasks"
                continue
            } else if lowercased.contains("## reminders") || lowercased.hasPrefix("reminders:") ||
                      (lowercased.contains("reminder") && (lowercased.contains("##") || lowercased.hasPrefix("reminder"))) {
                currentSection = "reminders"
                continue
            } else if lowercased.contains("## suggested titles") || lowercased.contains("## titles") || 
                      lowercased.hasPrefix("titles:") || lowercased.hasPrefix("suggested titles:") ||
                      (lowercased.contains("title") && (lowercased.contains("##") || lowercased.hasPrefix("title"))) {
                currentSection = "titles"
                continue
            }

            // Process based on current section
            switch currentSection {
            case "summary":
                if !trimmed.isEmpty && !trimmed.hasPrefix("##") && !lowercased.contains("task") && 
                   !lowercased.contains("reminder") && !lowercased.contains("title") {
                    summary += (summary.isEmpty ? "" : "\n") + trimmed
                }
            case "tasks":
                // More flexible parsing - accept lines starting with bullet points or numbers
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    let text = RecordingNameGenerator.cleanAIOutput(trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText())
                    if !text.isEmpty && text.count > 3 {
                        tasks.append(TaskItem(text: text, priority: .medium, confidence: 0.8))
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(".") {
                    // Handle numbered lists (e.g., "1. Task description")
                    let parts = trimmed.components(separatedBy: ".")
                    if parts.count > 1 {
                        let text = RecordingNameGenerator.cleanAIOutput(parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText())
                        if !text.isEmpty && text.count > 3 {
                            tasks.append(TaskItem(text: text, priority: .medium, confidence: 0.8))
                        }
                    }
                }
            case "reminders":
                // More flexible parsing - accept lines starting with bullet points or numbers
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    let text = RecordingNameGenerator.cleanAIOutput(trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText())
                    if !text.isEmpty && text.count > 3 {
                        let timeRef = ReminderItem.TimeReference.fromReminderText(text)
                        reminders.append(ReminderItem(text: text, timeReference: timeRef, urgency: .later, confidence: 0.8))
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(".") {
                    // Handle numbered lists (e.g., "1. Reminder description")
                    let parts = trimmed.components(separatedBy: ".")
                    if parts.count > 1 {
                        let text = RecordingNameGenerator.cleanAIOutput(parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines).sanitizedPlainText())
                        if !text.isEmpty && text.count > 3 {
                            let timeRef = ReminderItem.TimeReference.fromReminderText(text)
                            reminders.append(ReminderItem(text: text, timeReference: timeRef, urgency: .later, confidence: 0.8))
                        }
                    }
                }
            case "titles":
                // More flexible parsing - accept lines starting with bullet points or numbers
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    // Use standardized cleaning
                    let text = RecordingNameGenerator.cleanStandardizedTitleResponse(trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForTitle())
                    if !text.isEmpty && text.count > 3 && text.count < 100 {
                        titles.append(TitleItem(text: text, confidence: 0.8))
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(".") {
                    // Handle numbered lists (e.g., "1. Title suggestion")
                    let parts = trimmed.components(separatedBy: ".")
                    if parts.count > 1 {
                        let text = RecordingNameGenerator.cleanStandardizedTitleResponse(parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines).sanitizedForTitle())
                        if !text.isEmpty && text.count > 3 && text.count < 100 {
                            titles.append(TitleItem(text: text, confidence: 0.8))
                        }
                    }
                }
            default:
                // If no section detected yet, assume it's summary
                if !trimmed.isEmpty && !trimmed.hasPrefix("##") && !lowercased.contains("task") && 
                   !lowercased.contains("reminder") && !lowercased.contains("title") {
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
