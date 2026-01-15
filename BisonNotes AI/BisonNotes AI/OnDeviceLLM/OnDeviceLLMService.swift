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
        let systemPrompt: String?
        if config.modelInfo.templateType == .lfm {
            systemPrompt = LLMTemplate.lfmSummarizationSystemPrompt
        } else {
            systemPrompt = LLMTemplate.summarizationSystemPrompt
        }
        let template = config.modelInfo.templateType.template(systemPrompt: systemPrompt)

        // Use device-appropriate context size based on RAM
        // 8k for devices with <8GB RAM, 16k for devices with >=8GB RAM
        let deviceContextSize = DeviceCapabilities.onDeviceLLMContextSize
        let contextSize = Int32(min(config.modelInfo.contextWindow, deviceContextSize))
        
        // Small models (LFM, Qwen3-1.7B) use lower max output tokens
        let isSmallModel = config.modelInfo.id == "lfm-2.5-1.2b" || config.modelInfo.id == "qwen3-1.7b"
        let maxOutputTokens: Int32 = isSmallModel ? 1500 : 2700

        llm = OnDeviceLLM(
            from: modelURL,
            template: template,
            topK: config.topK,
            topP: config.topP,
            minP: config.minP,
            temp: config.temperature,
            repeatPenalty: config.repeatPenalty,
            penaltyLastN: Int32(config.modelInfo.defaultSettings.penaltyLastN),
            frequencyPenalty: config.modelInfo.defaultSettings.frequencyPenalty,
            presencePenalty: config.modelInfo.defaultSettings.presencePenalty,
            maxTokenCount: contextSize,
            maxOutputTokens: maxOutputTokens
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
        var prompt = createSummarizationPrompt(text: text, contentType: contentType)
        
        // For Qwen3 models, add /no_think to disable thinking mode (must be in user message)
        // Note: Placed at the end of the prompt to ensure it's processed correctly
        if config.modelInfo.id == "qwen3-1.7b" {
            prompt = prompt + "\n\n/no_think"
        }

        // Update template with summarization system prompt
        // Use LFM-specific system prompt for LFM models to prevent hallucinated tokens
        let systemPrompt: String?
        if config.modelInfo.templateType == .lfm {
            systemPrompt = LLMTemplate.lfmSummarizationSystemPrompt
        } else {
            systemPrompt = LLMTemplate.summarizationSystemPrompt
        }
        llm.template = config.modelInfo.templateType.template(systemPrompt: systemPrompt)

        // Generate response
        var result = await llm.generate(from: prompt)

        // Store metrics
        lastMetrics = llm.metrics

        // For LFM models, check if response is just stop tokens before cleanup
        if config.modelInfo.templateType == .lfm {
            let rawCheck = result.trimmingCharacters(in: .whitespacesAndNewlines)
            let stopTokenPatterns = ["<|im_end|>", "</|im_end|>", "<|endoftext|>", "</|endoftext|>"]
            let isOnlyStopTokens = stopTokenPatterns.contains { pattern in
                let test = rawCheck.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
                return test.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || test.count < 3
            }
            
            if isOnlyStopTokens {
                print("⚠️ [OnDeviceLLMService] LFM model generated only stop tokens, attempting retry with adjusted parameters...")
                // Try once more with slightly different prompt format
                let retryPrompt = createLFMSummarizationPrompt(text: text, contentType: contentType)
                result = await llm.generate(from: retryPrompt)
                lastMetrics = llm.metrics
            }
        }

        let cleaned = cleanupResponse(result)
        
        // Validate response - if it's essentially empty or just stop tokens, return error message
        if cleaned.isEmpty || cleaned.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
            print("⚠️ [OnDeviceLLMService] LFM model generated empty or minimal response after cleanup")
            return "Summary generation encountered an issue. The model produced an empty response. Please try again or use a different model."
        }
        
        return cleaned
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

        // Check if this is one of the small experimental models (LFM, Qwen3-1.7B)
        // These models only generate summary and one title (no tasks/reminders)
        // For small models, we use a two-step approach: summary first, then title from summary
        let isSmallModel = config.modelInfo.id == "lfm-2.5-1.2b" || 
                          config.modelInfo.id == "qwen3-1.7b"

        if isSmallModel {
            // Two-step approach for small models: summary first, then title
            return try await processSmallModelTwoStep(text: text, contentType: contentType)
        }

        // For larger models, use single-step complete processing
        let prompt = createCompleteProcessingPrompt(text: text)
        
        llm.template = config.modelInfo.templateType.template(
            systemPrompt: LLMTemplate.completeProcessingSystemPrompt
        )

        let result = await llm.generate(from: prompt)
        lastMetrics = llm.metrics

        // Parse the response
        let parsed = parseCompleteResponse(result)
        
        // For non-small models, return full results
        return (
            summary: parsed.summary.isEmpty ? cleanupResponse(result) : parsed.summary,
            tasks: parsed.tasks,
            reminders: parsed.reminders,
            titles: parsed.titles,
            contentType: contentType
        )
    }

    // MARK: - Small Model Two-Step Processing
    
    /// Two-step processing for small models: generate summary first, then title from summary
    private func processSmallModelTwoStep(text: String, contentType: ContentType) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        guard let llm = llm else {
            throw OnDeviceLLMError.modelNotLoaded
        }
        
        // This function is only called for small models (LFM, Qwen3-1.7B)
        let isSmallModel = config.modelInfo.id == "lfm-2.5-1.2b" || config.modelInfo.id == "qwen3-1.7b"
        
        // Step 1: Generate summary only
        let summaryPrompt = createSmallModelSummarizationPrompt(text: text, contentType: contentType)

        // For Qwen3 models, add /no_think to disable thinking mode
        // Place it at the end of the prompt to ensure it's processed correctly
        let finalSummaryPrompt: String
        if config.modelInfo.id == "qwen3-1.7b" {
            finalSummaryPrompt = summaryPrompt + "\n\n/no_think"
        } else {
            finalSummaryPrompt = summaryPrompt
        }

        // Use a minimal system prompt to guide the model
        let systemPrompt = "You are a helpful assistant that creates clear, structured summaries."
        llm.template = config.modelInfo.templateType.template(systemPrompt: systemPrompt)
        
        let summaryResult = await llm.generate(from: finalSummaryPrompt)
        lastMetrics = llm.metrics
        
        // Debug: Log raw response before cleanup
        if OnDeviceLLMFeatureFlags.verboseLogging {
            print("📝 [OnDeviceLLMService] Raw summary response (first 500 chars): \(String(summaryResult.prefix(500)))")
        }
        
        // Clean and parse summary
        var cleanedSummary = cleanupResponse(summaryResult)
        
        // Debug: Log cleaned response
        if OnDeviceLLMFeatureFlags.verboseLogging {
            print("📝 [OnDeviceLLMService] Cleaned summary (first 500 chars): \(String(cleanedSummary.prefix(500)))")
        }
        
        // For small models (LFM, Qwen3-1.7B), truncate if we detect repetitive content or if it's too long
        // This helps prevent hitting the max token limit
        if isSmallModel {
            // If the response is very long, try to find where the summary actually ends
            // Look for patterns that suggest the summary is complete
            if cleanedSummary.count > 2000 {
                // Try to find the end of the summary section
                if let summaryEnd = cleanedSummary.range(of: #"\n\n\n"#, options: []) {
                    cleanedSummary = String(cleanedSummary[..<summaryEnd.upperBound])
                } else if let summaryEnd = cleanedSummary.range(of: #"\n\n##"#, options: []) {
                    // If there's another section header, stop before it
                    cleanedSummary = String(cleanedSummary[..<summaryEnd.lowerBound])
                } else {
                    // Otherwise, just take the first 2000 characters
                    cleanedSummary = String(cleanedSummary.prefix(2000))
                }
                print("⚠️ [OnDeviceLLMService] Summary generation was too long, truncated for \(config.modelInfo.displayName)")
            }
        }
        
        // For small experimental models, validate the response isn't just stop tokens
        if isSmallModel {
            if cleanedSummary.isEmpty || cleanedSummary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).count < 20 {
                print("⚠️ [OnDeviceLLMService] Small experimental model (\(config.modelInfo.displayName)) generated empty or minimal summary")
                return (
                    summary: "⚠️ This experimental model (\(config.modelInfo.displayName)) failed to generate a valid summary. Small models (1-2B parameters) are unreliable for summarization tasks. Please try a larger model like Gemma, Qwen 4B, or Ministral in Settings.",
                    tasks: [],
                    reminders: [],
                    titles: [],
                    contentType: contentType
                )
            }
        }
        
        // Extract summary from response (look for ## Summary section or use cleaned response)
        var finalSummary = cleanedSummary
        
        // First check if the cleaned summary is just placeholder or minimal content
        let placeholderPatterns = ["...", "[", "]", "placeholder", "example", "your title", "descriptive title"]
        let isPlaceholder = placeholderPatterns.contains { pattern in
            cleanedSummary.lowercased().contains(pattern.lowercased())
        } && cleanedSummary.count < 50
        
        if isPlaceholder {
            print("⚠️ [OnDeviceLLMService] Detected placeholder content in summary, using full cleaned response")
            // Don't try to extract, just use what we have
        } else {
            // Try to extract summary section
            if let regex = try? NSRegularExpression(pattern: #"## Summary\s*\n(.*?)(?=\n##|$)"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let range = NSRange(cleanedSummary.startIndex..., in: cleanedSummary)
                if let match = regex.firstMatch(in: cleanedSummary, options: [], range: range), match.numberOfRanges > 1 {
                    let summaryRange = Range(match.range(at: 1), in: cleanedSummary)
                    if let summaryRange = summaryRange {
                        let summaryContent = String(cleanedSummary[summaryRange])
                        if !summaryContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty && summaryContent.count > 10 {
                            finalSummary = summaryContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                        }
                    }
                }
            }
        }
        
        // Validate final summary isn't just placeholder or too short
        // If the extracted summary is invalid, fall back to the full cleaned response
        if finalSummary.count < 10 || 
           finalSummary == "..." || 
           finalSummary.lowercased().contains("[your") || 
           finalSummary.lowercased().contains("descriptive title") ||
           finalSummary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            print("⚠️ [OnDeviceLLMService] Extracted summary is invalid (length: \(finalSummary.count)), using full cleaned response")
            // Use the full cleaned response instead of the extracted portion
            if cleanedSummary.count > 10 && !cleanedSummary.lowercased().contains("[your") {
                finalSummary = cleanedSummary
            } else {
                // If even the cleaned response is bad, we have a problem
                print("⚠️ [OnDeviceLLMService] Even cleaned response appears invalid, summary may be empty")
                
                // For small experimental models, provide a helpful error message
                let isSmallModel = config.modelInfo.id == "lfm-2.5-1.2b" || config.modelInfo.id == "qwen3-1.7b"
                if isSmallModel {
                    return (
                        summary: "⚠️ This experimental model (\(config.modelInfo.displayName)) failed to generate a valid summary. Small models (1-2B parameters) are unreliable for summarization tasks. Please try a larger model like Gemma, Qwen 4B, or Ministral in Settings.",
                        tasks: [],
                        reminders: [],
                        titles: [],
                        contentType: contentType
                    )
                }
            }
        }
        
        // Step 2: Generate title from the summary
        let titlePrompt = createTitleFromSummaryPrompt(summary: finalSummary, originalTranscript: text)

        // For Qwen3 models, add /no_think to disable thinking mode
        let finalTitlePrompt: String
        if config.modelInfo.id == "qwen3-1.7b" {
            finalTitlePrompt = titlePrompt + "\n\n/no_think"
        } else {
            finalTitlePrompt = titlePrompt
        }

        // Clear history before title generation to ensure clean context
        await llm.clearHistory()

        // Re-apply system prompt after clearing history
        let titleSystemPrompt = "You are a helpful assistant that creates clear, concise titles."
        
        // Create a custom template with additional stop sequences for title generation
        // This helps prevent the model from generating too much text
        let baseTemplate = config.modelInfo.templateType.template(systemPrompt: titleSystemPrompt)
        var titleStopSequences = baseTemplate.stopSequences
        
        // Add additional stop sequences to stop after the title
        // Stop after double newline, or if it starts generating another section
        let additionalStops = ["\n\n\n", "\n\n##", "\n##", "## Summary", "## Title", "\n\nSummary", "\n\nTitle"]
        for stop in additionalStops {
            if !titleStopSequences.contains(stop) {
                titleStopSequences.append(stop)
            }
        }
        
        // Create custom template with extended stop sequences
        let titleTemplate = LLMTemplate(
            prefix: baseTemplate.prefix,
            system: baseTemplate.system,
            user: baseTemplate.user,
            bot: baseTemplate.bot,
            stopSequences: titleStopSequences,
            systemPrompt: titleSystemPrompt,
            shouldDropLast: baseTemplate.shouldDropLast
        )
        
        llm.template = titleTemplate
        
        let titleResult = await llm.generate(from: finalTitlePrompt)
        lastMetrics = llm.metrics
        
        // Debug: Log raw title response
        if OnDeviceLLMFeatureFlags.verboseLogging {
            print("📝 [OnDeviceLLMService] Raw title response (first 500 chars): \(String(titleResult.prefix(500)))")
        }
        
        // Parse title from response
        var cleanedTitleResult = cleanupResponse(titleResult)
        
        // Check if response was likely truncated (hit max tokens)
        let wasTruncated = lastMetrics?.inferenceTokenCount ?? 0 >= 1400  // Close to 1500 limit
        if wasTruncated {
            print("⚠️ [OnDeviceLLMService] Title generation may have been truncated (output tokens: \(lastMetrics?.inferenceTokenCount ?? 0))")
        }
        
        // Debug: Log cleaned title response
        if OnDeviceLLMFeatureFlags.verboseLogging {
            print("📝 [OnDeviceLLMService] Cleaned title response (first 500 chars): \(String(cleanedTitleResult.prefix(500)))")
            if wasTruncated {
                print("⚠️ [OnDeviceLLMService] Response was truncated, attempting to extract title from partial response")
            }
        }
        
        // For small models (LFM, Qwen3-1.7B), truncate if title generation goes on too long
        // Title should be very short, so if it's long, it's likely repetitive or off-track
        if isSmallModel {
            // If the response is longer than 500 characters, it's likely generating too much
            if cleanedTitleResult.count > 500 {
                // Try to find where the title actually ends
                if let titleEnd = cleanedTitleResult.range(of: #"\n\n\n"#, options: []) {
                    cleanedTitleResult = String(cleanedTitleResult[..<titleEnd.upperBound])
                } else if let titleEnd = cleanedTitleResult.range(of: #"\n\n##"#, options: []) {
                    // If there's another section header, stop before it
                    cleanedTitleResult = String(cleanedTitleResult[..<titleEnd.lowerBound])
                } else {
                    // Look for the first occurrence of "## Title" and take everything up to the next major break
                    if let titleStart = cleanedTitleResult.range(of: "## Title", options: .caseInsensitive) {
                        let afterTitle = String(cleanedTitleResult[titleStart.upperBound...])
                        // Take up to 300 characters after "## Title" or until double newline
                        if let endBreak = afterTitle.range(of: "\n\n", options: []) {
                            cleanedTitleResult = String(cleanedTitleResult[..<titleStart.upperBound]) + String(afterTitle[..<endBreak.lowerBound])
                        } else {
                            cleanedTitleResult = String(cleanedTitleResult[..<titleStart.upperBound]) + String(afterTitle.prefix(300))
                        }
                    } else {
                        // Just take the first 500 characters
                        cleanedTitleResult = String(cleanedTitleResult.prefix(500))
                    }
                }
                print("⚠️ [OnDeviceLLMService] Title generation was too long (\(cleanedTitleResult.count) chars), truncated for \(config.modelInfo.displayName)")
            }
        }
        
        var finalTitles = parseTitlesFromResponse(cleanedTitleResult)
        
        // Filter out placeholder titles
        finalTitles = finalTitles.filter { titleItem in
            let text = titleItem.text.lowercased()
            let isPlaceholder = text.contains("[your") || 
                               text.contains("descriptive title") || 
                               text.contains("[a descriptive") ||
                               text == "..." ||
                               text.count < 5
            if isPlaceholder {
                print("⚠️ [OnDeviceLLMService] Filtered out placeholder title: '\(titleItem.text)'")
            }
            return !isPlaceholder
        }
        
        // If no title found, try to extract from the title section more aggressively
        if finalTitles.isEmpty {
            // Try multiple patterns to find the title using NSRegularExpression
            let patterns = [
                #"## Title\s*\n\s*-\s*(.+?)(?=\n|$)"#,  // ## Title\n- Title text
                #"## Title\s*\n\s*(.+?)(?=\n##|\n\n|$)"#,  // ## Title\nTitle text (no bullet)
                #"## Title\s*\n(.+?)(?=\n##|$)"#,  // ## Title\n... (multiline)
                #"Title:\s*\n\s*-\s*(.+?)(?=\n|$)"#,  // Title:\n- Title text
                #"^-\s*(.+?)(?=\n|$)"#,  // Just a bullet point at the start
                #"^(.+?)(?=\n##|\n\n|$)"#  // Just plain text at the start (no header)
            ]
            
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines, .dotMatchesLineSeparators]) {
                    let range = NSRange(cleanedTitleResult.startIndex..., in: cleanedTitleResult)
                    if let match = regex.firstMatch(in: cleanedTitleResult, options: [], range: range), match.numberOfRanges > 1 {
                        let titleRange = Range(match.range(at: 1), in: cleanedTitleResult)
                        if let titleRange = titleRange {
                            var matchedText = String(cleanedTitleResult[titleRange])
                            // Clean up the matched text
                            matchedText = matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            // Remove leading bullet if present
                            if matchedText.hasPrefix("- ") {
                                matchedText = String(matchedText.dropFirst(2))
                            } else if matchedText.hasPrefix("• ") {
                                matchedText = String(matchedText.dropFirst(2))
                            }
                            matchedText = matchedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Validate it's a reasonable title
                            if matchedText.count >= 5 && matchedText.count < 100 {
                                let cleaned = RecordingNameGenerator.cleanStandardizedTitleResponse(matchedText.sanitizedForTitle())
                                if !cleaned.isEmpty && !cleaned.lowercased().contains("[your") && !cleaned.lowercased().contains("descriptive title") {
                                    finalTitles = [TitleItem(text: cleaned, confidence: 0.8)]
                                    print("✅ [OnDeviceLLMService] Extracted title using pattern: '\(cleaned)'")
                                    break
                                }
                            }
                        }
                    }
                }
            }
            
            // If still no title and response was truncated (hit max tokens), try to extract from what we have
            // Look for any text after "## Title" even if it's incomplete
            if finalTitles.isEmpty && cleanedTitleResult.contains("## Title") {
                if let titleStart = cleanedTitleResult.range(of: "## Title", options: .caseInsensitive) {
                    let afterTitle = String(cleanedTitleResult[titleStart.upperBound...])
                    let lines = afterTitle.components(separatedBy: .newlines)
                    for line in lines {
                        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.hasPrefix("- ") {
                            cleaned = String(cleaned.dropFirst(2))
                        } else if cleaned.hasPrefix("• ") {
                            cleaned = String(cleaned.dropFirst(2))
                        }
                        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Take the first meaningful line that's not empty and not too short
                        if cleaned.count >= 5 && cleaned.count < 100 && !cleaned.isEmpty {
                            let title = RecordingNameGenerator.cleanStandardizedTitleResponse(cleaned.sanitizedForTitle())
                            if !title.isEmpty && !title.lowercased().contains("[your") && !title.lowercased().contains("descriptive title") {
                                finalTitles = [TitleItem(text: title, confidence: 0.7)]
                                print("✅ [OnDeviceLLMService] Extracted title from truncated response: '\(title)'")
                                break
                            }
                        }
                    }
                }
            }
        }
        
        // If still no title, create a fallback from summary
        if finalTitles.isEmpty && !finalSummary.isEmpty {
            // Extract first meaningful line from summary as fallback
            let summaryLines = finalSummary.components(separatedBy: CharacterSet.newlines)
            for line in summaryLines.prefix(5) {
                let cleaned = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "• ", with: "")
                
                if cleaned.count > 10 && cleaned.count < 80 {
                    let title = RecordingNameGenerator.cleanStandardizedTitleResponse(cleaned.sanitizedForTitle())
                    if !title.isEmpty {
                        finalTitles = [TitleItem(text: title, confidence: 0.6)]
                        break
                    }
                }
            }
        }
        
        return (
            summary: finalSummary.isEmpty ? cleanedSummary : finalSummary,
            tasks: [],  // Small models don't extract tasks
            reminders: [],  // Small models don't extract reminders
            titles: Array(finalTitles.prefix(1)),  // Only one title for small models
            contentType: contentType
        )
    }
    
    /// Create a prompt to generate a title from a summary
    private func createTitleFromSummaryPrompt(summary: String, originalTranscript: String) -> String {
        // For Qwen3-1.7B, use a direct prompt without instruction text that might be echoed
        // Make it very explicit that we want ONLY the title, nothing else
        return """
        Summary:
        \(summary)

        Generate ONE title (5-10 words) for this summary. Write only the title, nothing else.

        ## Title
        - 
        """
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
        // Include Gemma3-specific tokens, LFM-specific tokens, and Qwen3 thinking tags
        // Handle both correct and malformed variations
        let tokensToRemove = [
            "<|im_end|>", "<|im_start|>", "<|end|>", 
            "<|assistant|>", "<|user|>", "<|system|>",
            "<end_of_turn>", "<start_of_turn>", "<eos>",
            "<start_of_turn>user", "<start_of_turn>model",
            "</lim_end>", "<lim_end>", "</im_end>", "<im_end>",
            "</|im_end|>", "</|im_start|>", "</|end|>",  // Malformed variations
            "<|endoftext|>", "<|startoftext|>",
            "<|tool_call_start|>", "<|tool_call_end|>",
            "</|endoftext|>", "</|startoftext|>",  // Malformed variations
            "<think>", "</think>", "<think/>"  // Qwen3 thinking tags (should be disabled but clean up if present)
        ]
        for token in tokensToRemove {
            cleaned = cleaned.replacingOccurrences(of: token, with: "")
            // Also try case-insensitive and with different spacing
            cleaned = cleaned.replacingOccurrences(of: token.lowercased(), with: "", options: .caseInsensitive)
        }
        
        // Remove any remaining patterns that look like stop tokens (more aggressive cleanup)
        // Match patterns like "</|...|>" or "<|...|>" anywhere in the text
        if let regex = try? NSRegularExpression(pattern: "</?\\|[^|]*\\|>", options: []) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove thinking blocks <think>...</think> if they appear (Qwen3, etc.)
        // Use a more aggressive pattern that handles multiline thinking content
        if let thinkRegex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = thinkRegex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        // Also remove any standalone <think> or </think> tags that might remain
        cleaned = cleaned.replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        cleaned = cleaned.replacingOccurrences(of: "<think/>", with: "", options: .caseInsensitive)
        
        // Remove common introductory phrases and thinking-style content that models sometimes add
        let introPhrases = [
            "and here's the analysis:",
            "here's the analysis:",
            "here is the analysis:",
            "and here is the analysis:",
            "here's my analysis:",
            "here is my analysis:",
            "analysis:",
            "summary:",
            "here's the summary:",
            "here is the summary:",
            "alright, let me",
            "let me break down",
            "let me analyze",
            "i should",
            "i need to",
            "now, putting it together:",
            "putting it together:",
            "okay, let me try",
            "okay, let me",
            "let me try to",
            "the user wants",
            "i need to make sure"
        ]
        for phrase in introPhrases {
            if cleaned.lowercased().hasPrefix(phrase.lowercased()) {
                cleaned = String(cleaned.dropFirst(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Remove reasoning paragraphs that start with "Okay, let me try" or similar
        // Pattern: Paragraphs that contain meta-commentary about the task
        if let reasoningPattern = try? NSRegularExpression(pattern: #"(?i)^(okay, let me try|let me try to|the user wants|i need to make sure|let me check).*?(?=\n\n##|## Summary|$)"#, options: [.dotMatchesLineSeparators, .anchorsMatchLines]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = reasoningPattern.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove thinking-style paragraphs that start with meta-commentary
        // Pattern: "Alright, let me..." or "Let me break down..." followed by reasoning
        // This catches the entire thinking paragraph before the actual content
        if let thinkingPattern = try? NSRegularExpression(pattern: #"^(Alright, |Let me |I should |I need to |Now, putting it together: |Putting it together: ).*?(?=\n\n##|## Summary|## Title|$)"#, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = thinkingPattern.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Remove sentences that mention avoiding markdown or formatting (model confusion)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)i should avoid any markdown.*?instructions?\."#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)as per instructions.*?markdown.*?\."#,
            with: "",
            options: .regularExpression
        )

        // Sanitize encoding issues (Unicode replacement chars, smart quotes, etc.)
        cleaned = cleaned.sanitizedForDisplay()

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt Creation

    private func createSummarizationPrompt(text: String, contentType: ContentType) -> String {
        // Use LFM-specific prompts for better performance on small models
        if config.modelInfo.templateType == .lfm {
            return createLFMSummarizationPrompt(text: text, contentType: contentType)
        }
        
        // Qwen3-1.7B uses simpler prompts
        if config.modelInfo.id == "qwen3-1.7b" {
            return createSmallModelSummarizationPrompt(text: text, contentType: contentType)
        }
        
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
    
    /// Prompt for small models (Qwen3-1.7B) with simplified structure
    private func createSmallModelSummarizationPrompt(text: String, contentType: ContentType) -> String {
        let wordCount = text.split(separator: " ").count
        let minTargetWords = max(100, Int(Double(wordCount) * 0.05)) // 5% minimum
        let maxTargetWords = Int(Double(wordCount) * 0.10) // 10% maximum

        // For Qwen3-1.7B, use a direct prompt that doesn't include instruction text the model might echo
        return """
        Transcript:
        \(text)

        Create a summary with 3-5 bullet points in \(minTargetWords)-\(maxTargetWords) words.

        ## Summary
        """
    }
    
    /// LFM-specific summarization prompt with chain-of-thought and few-shot examples
    private func createLFMSummarizationPrompt(text: String, contentType: ContentType) -> String {
        let wordCount = text.split(separator: " ").count
        let minTargetWords = max(50, Int(Double(wordCount) * 0.05)) // 5% minimum
        let maxTargetWords = Int(Double(wordCount) * 0.10) // 10% maximum
        
        // For small models, place transcript first for better attention
        return """
        Transcript:
        \(text)

        You are a precise transcript analyst. Follow these steps:

        Step 1: Identify 3-5 main topics from the transcript.
        Step 2: Extract 2-3 key points for each topic.
        Step 3: Write a concise summary in \(minTargetWords)-\(maxTargetWords) words with 3-5 bullet points.

        CRITICAL: Start directly with the summary content. Do NOT add phrases like "and here's the analysis" or "here's the summary". Just write the bullet points.

        Example:
        Transcript: "I need to review the quarterly report by Friday. The team meeting is scheduled for next Tuesday at 2pm. We discussed the new product launch timeline."
        Summary: - Quarterly report review needed by Friday. - Team meeting on Tuesday at 2pm. - Product launch timeline discussed.

        Now analyze the transcript above and provide:

        ## Summary
        (\(minTargetWords)-\(maxTargetWords) words, 3-5 bullet points of key ideas)
        - [Key point 1]
        - [Key point 2]
        - [Key point 3]

        ## Key Details
        (Specific facts, numbers, dates, names mentioned)
        - [Detail 1]
        - [Detail 2]

        ## Action Items
        (Tasks or things to do)
        - [Action 1]
        - [Action 2]
        """
    }

    private func createTaskExtractionPrompt(text: String) -> String {
        // Use LFM-specific prompts for better performance on small models
        if config.modelInfo.templateType == .lfm {
            return createLFMTaskExtractionPrompt(text: text)
        }
        
        return """
        Extract all actionable tasks from the following transcript. Focus only on personal, actionable items that require follow-up.

        IMPORTANT: Return each task on a new line, starting with "- " followed directly by the task text. Do NOT use prefixes like [Task 1] or [Task 2].

        Transcript:
        \(text)

        Tasks:
        """
    }
    
    /// LFM-specific task extraction prompt with chain-of-thought and examples
    private func createLFMTaskExtractionPrompt(text: String) -> String {
        return """
        Transcript:
        \(text)

        Extract tasks from the transcript above.

        Step 1: Find action words (review, call, send, complete, follow up).
        Step 2: Identify what needs to be done.
        Step 3: Note any deadlines or timeframes mentioned.

        CRITICAL: Return each task starting with "- " followed directly by the task text. Do NOT use prefixes like [Task 1] or [Task 2].

        IMPORTANT: Only extract tasks that are ACTUALLY mentioned in the transcript. Do not generate placeholder or example tasks. If no tasks are mentioned, return nothing.

        Now extract tasks from the transcript above. Return each task on a new line starting with "- ":
        """
    }

    private func createReminderExtractionPrompt(text: String) -> String {
        // Use LFM-specific prompts for better performance on small models
        if config.modelInfo.templateType == .lfm {
            return createLFMReminderExtractionPrompt(text: text)
        }
        
        return """
        Extract all time-sensitive reminders and deadlines from the following transcript. Include dates, times, and deadlines mentioned.

        IMPORTANT: Return each reminder on a new line, starting with "- " followed directly by the reminder text. Do NOT use prefixes like [Reminder 1] or [Reminder 2].

        Transcript:
        \(text)

        Reminders:
        """
    }
    
    /// LFM-specific reminder extraction prompt with chain-of-thought and examples
    private func createLFMReminderExtractionPrompt(text: String) -> String {
        return """
        Transcript:
        \(text)

        Extract time-sensitive reminders and deadlines from the transcript above.

        Step 1: Look for dates (Monday, Friday, next week, tomorrow).
        Step 2: Look for times (2pm, morning, evening).
        Step 3: Look for deadlines or appointments.

        CRITICAL: Return each reminder starting with "- " followed directly by the reminder text. Do NOT use prefixes like [Reminder 1] or [Reminder 2].

        IMPORTANT: Only extract reminders that are ACTUALLY mentioned in the transcript. Do not generate placeholder or example reminders. If no reminders are mentioned, return nothing.

        Now extract reminders from the transcript above. Return each reminder on a new line starting with "- ":
        """
    }

    private func createTitleExtractionPrompt(text: String) -> String {
        """
        Suggest 3-5 concise, descriptive titles for the following transcript. Each title should capture the main topic or theme.

        IMPORTANT: Return each title on a new line, starting with "- " followed directly by the title text. Do NOT use prefixes like [Title 1] or [Title 2].

        Transcript:
        \(text)

        Suggested titles:
        """
    }

    private func createCompleteProcessingPrompt(text: String) -> String {
        // Use LFM-specific prompts for better performance on small models
        if config.modelInfo.templateType == .lfm {
            return createLFMCompleteProcessingPrompt(text: text)
        }
        
        // Qwen3-1.7B uses simpler prompts
        if config.modelInfo.id == "qwen3-1.7b" {
            return createSmallModelCompleteProcessingPrompt(text: text)
        }
        
        // Calculate approx 15% target length in words (min 200 words) to encourage longer output
        let wordCount = text.split(separator: " ").count
        let targetWords = max(200, Int(Double(wordCount) * 0.15))

        return """
        Analyze the following transcript and extract the actual content discussed. Base your response ONLY on what is actually mentioned in the transcript.

        1. A STRUCTURED OUTLINE SUMMARY
           - CRITICAL: The summary must be approximately \(targetWords) words long.
           - Use sections: Overview, Key Facts, Important Notes, Conclusions.
           - Expand on details using nested bullet points.
           - Write about what was ACTUALLY discussed in the transcript, not generic examples.
        2. A list of actionable tasks (personal items only) - ONLY include tasks that are actually mentioned
        3. Time-sensitive reminders and deadlines - ONLY include reminders that are actually mentioned
        4. 3-5 suggested titles - Based on the ACTUAL topics discussed

        IMPORTANT FORMATTING RULES:
        - For tasks, reminders, and titles: Start each line with "- " followed directly by the text
        - Do NOT use prefixes like [Task 1], [Reminder 1], or [Title 1]
        - Do NOT include placeholder or example text - only extract what is actually in the transcript
        - If no tasks are mentioned, leave the Tasks section empty
        - If no reminders are mentioned, leave the Reminders section empty

        Format your response with clear sections:

        ## Summary
        ### 1. Overview
        [Write a detailed overview based on what was actually discussed]

        ### 2. Key Facts & Details
        - [Extract specific facts, numbers, dates, and names that were mentioned]
        - [Only include information that appears in the transcript]

        ### 3. Important Notes
        - [Extract important context or observations from the transcript]

        ### 4. Conclusions
        [Summarize conclusions or decisions that were actually made]

        ## Tasks
        [Only include tasks that are explicitly mentioned in the transcript. If none, leave empty.]

        ## Reminders
        [Only include reminders with dates/times that are explicitly mentioned. If none, leave empty.]

        ## Suggested Titles
        [Generate titles based on the actual main topics discussed in the transcript]

        Transcript:
        \(text)
        """
    }
    
        /// LFM-specific complete processing prompt with chain-of-thought and examples
    private func createLFMCompleteProcessingPrompt(text: String) -> String {
        let wordCount = text.split(separator: " ").count
        let minTargetWords = max(50, Int(Double(wordCount) * 0.05)) // 5% minimum
        let maxTargetWords = Int(Double(wordCount) * 0.10) // 10% maximum
        
        return """
        Transcript:
        \(text)

        Your task: Analyze the transcript above and provide a complete summary with tasks, reminders, and titles.

        Instructions:
        1. Read the transcript carefully
        2. Identify 3-5 main topics discussed
        3. Write a summary with \(minTargetWords)-\(maxTargetWords) words using bullet points
        4. Extract any tasks mentioned (things to do)
        5. Extract any reminders (dates, times, deadlines)
        6. Suggest 3-5 descriptive titles

        IMPORTANT: You must write actual content. Start your response with "## Summary" followed by bullet points. Do not output just tags or empty responses.

        CRITICAL: Only extract information that is ACTUALLY mentioned in the transcript. Do not generate placeholder text, examples, or generic content. If no tasks are mentioned, leave the Tasks section empty. If no reminders are mentioned, leave the Reminders section empty.

        Format your response like this:

        ## Summary
        - [Extract the first main point that was actually discussed]
        - [Extract the second important point that was actually discussed]
        - [Extract the third key detail that was actually discussed]

        ## Tasks
        [Only include tasks that are explicitly mentioned. If none, leave empty.]

        ## Reminders
        [Only include reminders that are explicitly mentioned. If none, leave empty.]

        ## Suggested Titles
        [Generate titles based on the actual main topics discussed]

        Now analyze the transcript and provide your response based ONLY on what is actually mentioned:
        """
    }
    
    /// Complete processing prompt for small models (Qwen3-1.7B, LFM 2.5)
    /// Simplified to only generate summary and one title (no tasks/reminders)
    private func createSmallModelCompleteProcessingPrompt(text: String) -> String {
        let wordCount = text.split(separator: " ").count
        let minTargetWords = max(100, Int(Double(wordCount) * 0.05)) // 5% minimum
        let maxTargetWords = Int(Double(wordCount) * 0.10) // 10% maximum
        
        return """
        Analyze this transcript and provide a summary and one title.

        Transcript:
        \(text)

        Instructions:
        1. Write a summary (\(minTargetWords)-\(maxTargetWords) words) with bullet points using markdown formatting
        2. Provide ONE descriptive title for this transcript

        CRITICAL RULES:
        - Use markdown formatting: ## for headers, - for bullet points
        - Start each summary point with "- "
        - Provide only ONE title
        - Do NOT include tasks or reminders
        - Do NOT use <think> tags or show reasoning steps
        - Do NOT include meta-commentary like "let me break down" or "I should"
        - Start directly with the content - no introductory phrases
        - Stop after completing both sections

        Format your response using markdown:

        ## Summary
        - Key point 1
        - Key point 2
        - Key point 3

        ## Title
        - One descriptive title for this transcript

        Now analyze the transcript and provide your response:
        """
    }

    // MARK: - Response Parsing
    
    /// Strip numbered prefixes like [Task 1], [Title 2], [Reminder 3] from text
    private func stripNumberedPrefixes(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Pattern: [Task 1], [Task 2], [Title 1], [Reminder 1], etc.
        let patterns = [
            #"\[Task\s+\d+\]\s*"#,
            #"\[Title\s+\d+\]\s*"#,
            #"\[Reminder\s+\d+\]\s*"#,
            #"\[Action\s+\d+\]\s*"#,
            #"\[Detail\s+\d+\]\s*"#,
            #"\[Key\s+point\s+\d+\]\s*"#,
            #"\[Note\s+\d+\]\s*"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
            }
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseTasksFromResponse(_ response: String) -> [TaskItem] {
        let lines = response.sanitizedForDisplay().components(separatedBy: .newlines)
        var tasks: [TaskItem] = []
        var seenTasks = Set<String>()  // Deduplicate by normalized text

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                var taskText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Strip numbered prefixes like [Task 1], [Task 2], etc.
                taskText = stripNumberedPrefixes(from: String(taskText))
                
                let cleaned = RecordingNameGenerator.cleanAIOutput(taskText.sanitizedPlainText())
                if !cleaned.isEmpty && cleaned.count > 3 {
                    // Normalize for deduplication (lowercase, remove extra spaces)
                    let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !seenTasks.contains(normalized) {
                        seenTasks.insert(normalized)
                        tasks.append(TaskItem(text: cleaned, priority: .medium, confidence: 0.8))
                    }
                }
            }
        }

        return Array(tasks.prefix(15))
    }

    private func parseRemindersFromResponse(_ response: String) -> [ReminderItem] {
        let lines = response.sanitizedForDisplay().components(separatedBy: .newlines)
        var reminders: [ReminderItem] = []
        var seenReminders = Set<String>()  // Deduplicate by normalized text

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                var reminderText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Strip numbered prefixes like [Reminder 1], [Reminder 2], etc.
                reminderText = stripNumberedPrefixes(from: String(reminderText))
                
                let cleaned = RecordingNameGenerator.cleanAIOutput(reminderText.sanitizedPlainText())
                if !cleaned.isEmpty && cleaned.count > 3 {
                    // Normalize for deduplication (lowercase, remove extra spaces)
                    let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !seenReminders.contains(normalized) {
                        seenReminders.insert(normalized)
                        let timeRef = ReminderItem.TimeReference.fromReminderText(cleaned)
                        reminders.append(ReminderItem(text: cleaned, timeReference: timeRef, urgency: .later, confidence: 0.8))
                    }
                }
            }
        }

        return Array(reminders.prefix(15))
    }

    private func parseTitlesFromResponse(_ response: String) -> [TitleItem] {
        let lines = response.sanitizedForDisplay().components(separatedBy: .newlines)
        var titles: [TitleItem] = []
        var seenTitles = Set<String>()  // Deduplicate by normalized text

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                var titleText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Strip numbered prefixes like [Title 1], [Title 2], etc.
                titleText = stripNumberedPrefixes(from: String(titleText))
                
                // Use standardized cleaning
                let cleaned = RecordingNameGenerator.cleanStandardizedTitleResponse(titleText.sanitizedForTitle())
                if !cleaned.isEmpty && cleaned.count > 3 && cleaned.count < 100 {
                    // Normalize for deduplication (lowercase, remove extra spaces)
                    let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !seenTitles.contains(normalized) {
                        seenTitles.insert(normalized)
                        titles.append(TitleItem(text: cleaned, confidence: 0.8))
                    }
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
        
        // Deduplication sets
        var seenTasks = Set<String>()
        var seenReminders = Set<String>()
        var seenTitles = Set<String>()

        var currentSection = ""
        // Sanitize the entire response first, including Gemma3 and LFM tokens
        var sanitizedResponse = response.sanitizedForDisplay()
        
        // Check if response is essentially just stop tokens - if so, return early
        // Be more lenient - only return empty if response is truly empty after removing all stop tokens
        let stopTokenPatterns = ["<|im_end|>", "</|im_end|>", "<|endoftext|>", "</|endoftext|>"]
        var testResponse = sanitizedResponse
        for pattern in stopTokenPatterns {
            testResponse = testResponse.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }
        let cleanedTest = testResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only consider it "only stop tokens" if there's less than 10 characters of actual content
        if cleanedTest.isEmpty || cleanedTest.count < 10 {
            print("⚠️ [OnDeviceLLMService] Response contains only stop tokens or minimal content (length: \(cleanedTest.count)), returning empty result")
            return (summary: "", tasks: [], reminders: [], titles: [])
        }
        
        // Remove template tokens that might interfere with parsing
        let tokensToRemove = [
            "<end_of_turn>", "<start_of_turn>", "<eos>",
            "</lim_end>", "<lim_end>", "</im_end>", "<im_end>",
            "<|im_end|>", "<|im_start|>", "<|endoftext|>", "<|startoftext|>",
            "<|tool_call_start|>", "<|tool_call_end|>",
            "</|im_end|>", "</|im_start|>", "</|endoftext|>", "</|startoftext|>"  // Malformed variations
        ]
        for token in tokensToRemove {
            sanitizedResponse = sanitizedResponse.replacingOccurrences(of: token, with: "")
            // Also try case variations
            sanitizedResponse = sanitizedResponse.replacingOccurrences(of: token.lowercased(), with: "", options: .caseInsensitive)
        }
        
        // Remove any remaining patterns that look like stop tokens (aggressive cleanup)
        if let regex = try? NSRegularExpression(pattern: "</?\\|[^|]*\\|>", options: []) {
            let range = NSRange(sanitizedResponse.startIndex..., in: sanitizedResponse)
            sanitizedResponse = regex.stringByReplacingMatches(in: sanitizedResponse, options: [], range: range, withTemplate: "")
        }
        
        // Remove thinking blocks <think>...</think> (Qwen3, etc.)
        if let thinkRegex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            let range = NSRange(sanitizedResponse.startIndex..., in: sanitizedResponse)
            sanitizedResponse = thinkRegex.stringByReplacingMatches(in: sanitizedResponse, options: [], range: range, withTemplate: "")
        }
        // Also remove any standalone thinking tags
        sanitizedResponse = sanitizedResponse.replacingOccurrences(of: "<think>", with: "", options: .caseInsensitive)
        sanitizedResponse = sanitizedResponse.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
        sanitizedResponse = sanitizedResponse.replacingOccurrences(of: "<think/>", with: "", options: .caseInsensitive)
        
        // Remove introductory phrases and thinking-style content
        let introPhrases = [
            "and here's the analysis:",
            "here's the analysis:",
            "here is the analysis:",
            "and here is the analysis:",
            "here's my analysis:",
            "here is my analysis:",
            "alright, let me",
            "let me break down",
            "let me analyze",
            "i should",
            "i need to",
            "now, putting it together:",
            "putting it together:"
        ]
        for phrase in introPhrases {
            if sanitizedResponse.lowercased().hasPrefix(phrase.lowercased()) {
                sanitizedResponse = String(sanitizedResponse.dropFirst(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Remove thinking-style paragraphs that contain meta-commentary about the process
        // Pattern: Paragraphs starting with "Alright, let me..." or "Let me break down..." etc.
        // Also catch Qwen3-1.7B reasoning patterns like "Okay, let me try to summarize"
        if let thinkingPattern = try? NSRegularExpression(pattern: #"(?i)^(Alright, |Let me |I should |I need to |Okay, let me try|Let me try to|The user wants|I need to make sure|Let me check).*?(?=\n\n|##|$)"#, options: [.dotMatchesLineSeparators, .anchorsMatchLines]) {
            let range = NSRange(sanitizedResponse.startIndex..., in: sanitizedResponse)
            sanitizedResponse = thinkingPattern.stringByReplacingMatches(in: sanitizedResponse, options: [], range: range, withTemplate: "")
        }
        
        // Remove sentences that explicitly mention avoiding markdown or formatting
        sanitizedResponse = sanitizedResponse.replacingOccurrences(
            of: #"(?i)i should avoid any markdown.*?instructions?\."#,
            with: "",
            options: .regularExpression
        )
        
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
                      lowercased.contains("## title") ||  // Handle single "## Title" format for small models
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
                    var text = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    text = stripNumberedPrefixes(from: String(text))
                    let cleaned = RecordingNameGenerator.cleanAIOutput(String(text).sanitizedPlainText())
                    if !cleaned.isEmpty && cleaned.count > 3 {
                        let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !seenTasks.contains(normalized) {
                            seenTasks.insert(normalized)
                            tasks.append(TaskItem(text: cleaned, priority: .medium, confidence: 0.8))
                        }
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(".") {
                    // Handle numbered lists (e.g., "1. Task description")
                    let parts = trimmed.components(separatedBy: ".")
                    if parts.count > 1 {
                        var text = parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                        text = stripNumberedPrefixes(from: text)
                        let cleaned = RecordingNameGenerator.cleanAIOutput(text.sanitizedPlainText())
                        if !cleaned.isEmpty && cleaned.count > 3 {
                            let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !seenTasks.contains(normalized) {
                                seenTasks.insert(normalized)
                                tasks.append(TaskItem(text: cleaned, priority: .medium, confidence: 0.8))
                            }
                        }
                    }
                }
            case "reminders":
                // More flexible parsing - accept lines starting with bullet points or numbers
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    var text = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    text = stripNumberedPrefixes(from: String(text))
                    let cleaned = RecordingNameGenerator.cleanAIOutput(String(text).sanitizedPlainText())
                    if !cleaned.isEmpty && cleaned.count > 3 {
                        let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !seenReminders.contains(normalized) {
                            seenReminders.insert(normalized)
                            let timeRef = ReminderItem.TimeReference.fromReminderText(cleaned)
                            reminders.append(ReminderItem(text: cleaned, timeReference: timeRef, urgency: .later, confidence: 0.8))
                        }
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(".") {
                    // Handle numbered lists (e.g., "1. Reminder description")
                    let parts = trimmed.components(separatedBy: ".")
                    if parts.count > 1 {
                        var text = parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                        text = stripNumberedPrefixes(from: text)
                        let cleaned = RecordingNameGenerator.cleanAIOutput(text.sanitizedPlainText())
                        if !cleaned.isEmpty && cleaned.count > 3 {
                            let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !seenReminders.contains(normalized) {
                                seenReminders.insert(normalized)
                                let timeRef = ReminderItem.TimeReference.fromReminderText(cleaned)
                                reminders.append(ReminderItem(text: cleaned, timeReference: timeRef, urgency: .later, confidence: 0.8))
                            }
                        }
                    }
                }
            case "titles":
                // More flexible parsing - accept lines starting with bullet points or numbers
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    var text = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    text = stripNumberedPrefixes(from: String(text))
                    // Use standardized cleaning
                    let cleaned = RecordingNameGenerator.cleanStandardizedTitleResponse(String(text).sanitizedForTitle())
                    if !cleaned.isEmpty && cleaned.count > 3 && cleaned.count < 100 {
                        let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !seenTitles.contains(normalized) {
                            seenTitles.insert(normalized)
                            titles.append(TitleItem(text: cleaned, confidence: 0.8))
                        }
                    }
                } else if trimmed.first?.isNumber == true && trimmed.contains(".") {
                    // Handle numbered lists (e.g., "1. Title suggestion")
                    let parts = trimmed.components(separatedBy: ".")
                    if parts.count > 1 {
                        var text = parts.dropFirst().joined(separator: ".").trimmingCharacters(in: .whitespacesAndNewlines)
                        text = stripNumberedPrefixes(from: text)
                        let cleaned = RecordingNameGenerator.cleanStandardizedTitleResponse(text.sanitizedForTitle())
                        if !cleaned.isEmpty && cleaned.count > 3 && cleaned.count < 100 {
                            let normalized = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !seenTitles.contains(normalized) {
                                seenTitles.insert(normalized)
                                titles.append(TitleItem(text: cleaned, confidence: 0.8))
                            }
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
        
        // Clean up summary text - remove artifacts and introductory phrases
        summary = cleanupResponse(summary)
        
        // If no titles were found, generate fallback titles from summary content
        if titles.isEmpty && !summary.isEmpty {
            // Extract key phrases from summary to create titles
            let summaryLines = summary.components(separatedBy: .newlines)
            for line in summaryLines.prefix(5) {
                let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "- ", with: "")
                    .replacingOccurrences(of: "• ", with: "")
                    .replacingOccurrences(of: "* ", with: "")
                
                // Skip if too short or contains artifacts
                if cleaned.count > 10 && cleaned.count < 80 && 
                   !cleaned.contains("</") && !cleaned.contains("<|") {
                    let title = RecordingNameGenerator.cleanStandardizedTitleResponse(cleaned.sanitizedForTitle())
                    if !title.isEmpty && title.count > 3 && title.count < 100 {
                        titles.append(TitleItem(text: title, confidence: 0.6))
                    }
                }
            }
            
            // If still no titles, create a generic one from the first meaningful line
            if titles.isEmpty {
                let firstLine = summaryLines.first(where: { line in
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "- ", with: "")
                        .replacingOccurrences(of: "• ", with: "")
                        .replacingOccurrences(of: "* ", with: "")
                    return cleaned.count > 10 && cleaned.count < 80
                })
                
                if let firstLine = firstLine {
                    let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "- ", with: "")
                        .replacingOccurrences(of: "• ", with: "")
                        .replacingOccurrences(of: "* ", with: "")
                    let title = RecordingNameGenerator.cleanStandardizedTitleResponse(cleaned.sanitizedForTitle())
                    if !title.isEmpty && title.count > 3 && title.count < 100 {
                        titles.append(TitleItem(text: title, confidence: 0.5))
                    }
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
