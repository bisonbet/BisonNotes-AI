//
//  OnDeviceLLMEngine.swift
//  BisonNotes AI
//
//  SummarizationEngine implementation for on-device LLM
//  Integrates with BisonNotes AI engine system
//

import Foundation
import os.log
import UIKit

// MARK: - On-Device LLM Engine

/// On-device LLM engine implementing the SummarizationEngine protocol
class OnDeviceLLMEngine: SummarizationEngine, ConnectionTestable {

    // MARK: - SummarizationEngine Properties

    var name: String { "On-Device AI" }
    var engineType: String { "On-Device AI" }
    var description: String { "Private, local summarization using models like Llama, Phi, or Mistral running entirely on your device." }
    let version: String = "1.0"

    var isAvailable: Bool {
        // Check if on-device LLM is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)

        guard isEnabled else {
            if OnDeviceLLMFeatureFlags.verboseLogging {
                AppLog.shared.summarization("[OnDeviceLLMEngine] Not enabled in settings", level: .debug)
            }
            return false
        }

        // Check if a model is downloaded
        let selectedModel = OnDeviceLLMModelInfo.selectedModel
        guard selectedModel.isDownloaded else {
            if OnDeviceLLMFeatureFlags.verboseLogging {
                AppLog.shared.summarization("[OnDeviceLLMEngine] Model not downloaded: \(selectedModel.displayName)", level: .debug)
            }
            return false
        }

        return true
    }
    
    var metadataName: String {
        return OnDeviceLLMModelInfo.selectedModel.id
    }

    // MARK: - Private Properties

    private var service: OnDeviceLLMService?
    private var currentConfig: OnDeviceLLMConfig?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.bisonnotes.app", category: "OnDeviceLLMEngine")
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        updateConfiguration()
        setupBackgroundObservers()
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    // MARK: - Background Safety

    /// Observe app lifecycle to prevent Metal GPU work from background.
    /// iOS kills Metal command buffers submitted from background apps, causing
    /// a fatal crash in llama.cpp's Metal backend (ggml_abort).
    private func setupBackgroundObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppLog.shared.summarization("[OnDeviceLLMEngine] App entered background - pausing GPU inference")
            self?.service?.setAppBackgrounded(true)
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            AppLog.shared.summarization("[OnDeviceLLMEngine] App entering foreground - resuming GPU inference")
            self?.service?.setAppBackgrounded(false)
        }
    }

    // MARK: - Configuration

    private func updateConfiguration() {
        let newConfig = OnDeviceLLMConfig.current

        // Only recreate service if config changed
        if currentConfig == nil ||
           currentConfig?.modelInfo.id != newConfig.modelInfo.id ||
           currentConfig?.temperature != newConfig.temperature {

            currentConfig = newConfig
            service = OnDeviceLLMService(config: newConfig)

            if OnDeviceLLMFeatureFlags.verboseLogging {
                logger.info("Configuration updated - Model: \(newConfig.modelInfo.displayName), Temp: \(newConfig.temperature)")
            }
        }
    }

    // MARK: - SummarizationEngine Methods

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        AppLog.shared.summarization("[OnDeviceLLMEngine] Starting summary generation")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let summary = try await service.generateSummary(from: text, contentType: contentType)
            AppLog.shared.summarization("[OnDeviceLLMEngine] Summary generated successfully")
            return summary
        } catch {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Summary generation failed: \(error)", level: .error)
            throw handleError(error)
        }
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        AppLog.shared.summarization("[OnDeviceLLMEngine] Starting task extraction")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let tasks = try await service.extractTasks(from: text)
            AppLog.shared.summarization("[OnDeviceLLMEngine] Extracted \(tasks.count) tasks")
            return tasks
        } catch {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Task extraction failed: \(error)", level: .error)
            throw handleError(error)
        }
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        AppLog.shared.summarization("[OnDeviceLLMEngine] Starting reminder extraction")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let reminders = try await service.extractReminders(from: text)
            AppLog.shared.summarization("[OnDeviceLLMEngine] Extracted \(reminders.count) reminders")
            return reminders
        } catch {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Reminder extraction failed: \(error)", level: .error)
            throw handleError(error)
        }
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        AppLog.shared.summarization("[OnDeviceLLMEngine] Starting title extraction")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let titles = try await service.extractTitles(from: text)
            AppLog.shared.summarization("[OnDeviceLLMEngine] Extracted \(titles.count) titles")
            return titles
        } catch {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Title extraction failed: \(error)", level: .error)
            throw handleError(error)
        }
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        // Use local classification (no LLM needed)
        return ContentAnalyzer.classifyContent(text)
    }

    func processComplete(text: String) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        AppLog.shared.summarization("[OnDeviceLLMEngine] Starting complete processing")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        // Check if text needs chunking
        // Use device-appropriate context size based on RAM (8k for <8GB, 16k for >=8GB)
        let selectedModel = OnDeviceLLMModelInfo.selectedModel
        let deviceContextSize = DeviceCapabilities.onDeviceLLMContextSize
        let maxContextTokens = min(selectedModel.contextWindow, deviceContextSize)
        
        // Reserve space for output tokens
        // OnDeviceLLM.tokenizeAndBatchInput reserves 10% (min 256, max 2048) for output
        // We use a slightly more conservative 15% to account for token estimation inaccuracy
        // and ensure chunks fit even if estimation is off
        let outputReserve = min(2048, max(256, maxContextTokens / 10))
        let effectiveInputLimit = maxContextTokens - outputReserve
        
        // Try to use accurate tokenization if model is loaded, otherwise use estimation
        let tokenCount: Int
        do {
            try service.ensureModelLoaded()
            tokenCount = try service.getAccurateTokenCount(text)
            AppLog.shared.summarization("[OnDeviceLLMEngine] Using accurate tokenization: \(tokenCount) tokens", level: .debug)
        } catch {
            // Fall back to estimation if model not loaded yet
            tokenCount = TokenManager.getTokenCount(text)
            AppLog.shared.summarization("[OnDeviceLLMEngine] Using token estimation: \(tokenCount) tokens", level: .debug)
        }
        
        AppLog.shared.summarization("[OnDeviceLLMEngine] Text token count: \(tokenCount), max context: \(maxContextTokens), output reserve: \(outputReserve), effective input limit: \(effectiveInputLimit)", level: .debug)

        do {
            if tokenCount > effectiveInputLimit {
                AppLog.shared.summarization("[OnDeviceLLMEngine] Large text detected, using chunked processing with overlap")
                return try await processChunkedText(text, service: service, maxTokens: effectiveInputLimit)
            } else {
                AppLog.shared.summarization("[OnDeviceLLMEngine] Processing single chunk", level: .debug)
                let result = try await service.processComplete(text: text)

                // Check if inference was interrupted by app entering background
                if service.wasInterruptedByBackground {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Inference interrupted by app backgrounding (GPU not available)", level: .error)
                    throw OnDeviceLLMError.inferenceFailed("On-device AI needs the app to stay open. Please return to the app and try again.")
                }

                if let metrics = service.lastMetrics {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Inference completed at \(String(format: "%.1f", metrics.inferenceTokensPerSecond)) tokens/sec")
                }

                return result
            }
        } catch {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Complete processing failed: \(error)", level: .error)
            throw handleError(error)
        }
    }

    // MARK: - Chunked Processing

    private func processChunkedText(
        _ text: String,
        service: OnDeviceLLMService,
        maxTokens: Int
    ) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let startTime = Date()

        // Ensure model is loaded to use accurate tokenization
        try service.ensureModelLoaded()
        
        // Get accurate tokenizer function from service
        // Use 100 tokens overlap (approximately 75-100 words) to preserve context at boundaries
        let overlapTokens = 100
        let tokenizer: ((String) -> Int)? = { text in
            do {
                return try service.getAccurateTokenCount(text)
            } catch {
                // Fall back to estimation if tokenizer unavailable
                AppLog.shared.summarization("[OnDeviceLLMEngine] Could not use accurate tokenizer, falling back to estimation: \(error)", level: .error)
                return TokenManager.getTokenCount(text)
            }
        }
        
        let chunks = TokenManager.chunkTextWithOverlap(
            text,
            maxTokens: maxTokens,
            overlapTokens: overlapTokens,
            tokenizer: tokenizer
        )
        AppLog.shared.summarization("[OnDeviceLLMEngine] Split into \(chunks.count) chunks with \(overlapTokens) token overlap")
        
        // Validate chunk sizes using accurate tokenization
        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkTokenCount = try service.getAccurateTokenCount(chunk)
                if chunkTokenCount > maxTokens {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Chunk \(index + 1) token count (\(chunkTokenCount)) exceeds limit (\(maxTokens)). May be truncated by OnDeviceLLM.", level: .error)
                } else {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Chunk \(index + 1): \(chunkTokenCount) tokens (within limit)", level: .debug)
                }
            } catch {
                // Fall back to estimation if tokenizer unavailable
                let chunkTokenEstimate = TokenManager.getTokenCount(chunk)
                if chunkTokenEstimate > maxTokens {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Chunk \(index + 1) estimated token count (\(chunkTokenEstimate)) exceeds limit (\(maxTokens)). May be truncated by OnDeviceLLM.", level: .error)
                }
            }
        }

        var allSummaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentType: ContentType = .general

        for (index, chunk) in chunks.enumerated() {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Processing chunk \(index + 1)/\(chunks.count)", level: .debug)

            // Check if we are running in background and task is about to expire
            // Must access UIApplication.shared on MainActor
            let isBackground = await MainActor.run {
                UIApplication.shared.applicationState == .background
            }
            
            if isBackground {
                let remaining = await MainActor.run {
                    UIApplication.shared.backgroundTimeRemaining
                }
                
                if remaining < 10 { // Less than 10 seconds remaining
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Background time critical (\(remaining)s), aborting to prevent crash", level: .error)
                    throw OnDeviceLLMError.inferenceFailed("On-device AI needs the app to stay open. Please return to the app and try again.")
                }
            }

            do {
                let chunkResult = try await service.processComplete(text: chunk)

                // Check if chunk processing was interrupted by backgrounding
                if service.wasInterruptedByBackground {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Chunk \(index + 1) interrupted by app backgrounding", level: .error)
                    throw OnDeviceLLMError.inferenceFailed("On-device AI needs the app to stay open. Please return to the app and try again.")
                }

                allSummaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)

                if index == 0 {
                    contentType = chunkResult.contentType
                }

                // Add a small delay between chunks to let the GPU cool down/prevent TDR
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                }
            } catch {
                AppLog.shared.summarization("[OnDeviceLLMEngine] Chunk \(index + 1) failed: \(error)", level: .error)
                throw error
            }
        }

        // Combine summaries into a final consolidated summary
        let combinedSummary: String
        if allSummaries.count > 1 {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Combining \(allSummaries.count) chunk summaries into final summary")
            // Calculate word count from original transcript (same method as chunk summaries)
            let originalWordCount = text.split(separator: " ").count
            combinedSummary = try await combineChunkSummaries(
                allSummaries,
                service: service,
                contentType: contentType,
                originalWordCount: originalWordCount
            )
        } else {
            combinedSummary = allSummaries.first ?? ""
        }

        // Deduplicate
        let uniqueTasks = deduplicateItems(allTasks, limit: 15) { $0.text }
        let uniqueReminders = deduplicateItems(allReminders, limit: 15) { $0.text }
        let uniqueTitles = deduplicateItems(allTitles, limit: 5) { $0.text }

        let processingTime = Date().timeIntervalSince(startTime)
        AppLog.shared.summarization("[OnDeviceLLMEngine] Chunked processing completed in \(String(format: "%.1f", processingTime))s")

        return (combinedSummary, uniqueTasks, uniqueReminders, uniqueTitles, contentType)
    }

    private func deduplicateItems<T>(_ items: [T], limit: Int, getText: (T) -> String) -> [T] {
        var seen = Set<String>()
        var unique: [T] = []

        for item in items {
            let text = getText(item).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.contains(text) && !text.isEmpty {
                seen.insert(text)
                unique.append(item)
            }
        }

        return Array(unique.prefix(limit))
    }

    // MARK: - Connection Testing

    func testConnection() async -> Bool {
        AppLog.shared.summarization("[OnDeviceLLMEngine] Testing connection...")

        updateConfiguration()

        guard let service = service else {
            AppLog.shared.summarization("[OnDeviceLLMEngine] Service not configured", level: .error)
            return false
        }

        let result = await service.testConnection()
        AppLog.shared.summarization("[OnDeviceLLMEngine] Connection test result: \(result)")
        return result
    }

    // MARK: - Meta-Summary Combination

    /// Combine multiple chunk summaries into a single consolidated summary
    /// - Parameters:
    ///   - summaries: Array of summaries from individual chunks
    ///   - service: The LLM service to use for combination
    ///   - contentType: The content type of the original transcript
    ///   - originalWordCount: Word count of the ORIGINAL transcript (not the summaries)
    /// - Returns: A single consolidated summary that is 15% of the original transcript length
    private func combineChunkSummaries(
        _ summaries: [String],
        service: OnDeviceLLMService,
        contentType: ContentType,
        originalWordCount: Int
    ) async throws -> String {
        // Calculate target word count based on ORIGINAL transcript (15% detail level)
        // This ensures the final consolidated summary is proportional to the original transcript,
        // not the already-summarized chunks (which would be much smaller)
        let targetWords = max(200, Int(Double(originalWordCount) * 0.15))
        
        let combinedSummariesText = summaries.joined(separator: "\n\n=== SECTION ===\n\n")
        
        // Create a comprehensive meta-summary prompt that matches the structure of initial summaries
        let metaPromptBase = """
        You are consolidating summaries from different parts of a single recording into ONE unified, comprehensive Structured Outline.

        CRITICAL REQUIREMENTS:
        - The final summary MUST be approximately \(targetWords) words long.
        - Create a SINGLE, COHERENT outline that covers the ENTIRE recording.
        - Use the EXACT same structured format as the input summaries.
        - Do NOT simply concatenate - merge, deduplicate, and synthesize information.
        - Maintain the 15% detail level - do not over-condense.

        REQUIRED OUTPUT FORMAT:
        ## 1. Overview
        (A unified overview that synthesizes all sections into one comprehensive summary of the entire recording)

        ## 2. Key Facts & Details
        (Merge all facts from all sections into a single comprehensive list, removing duplicates)
        - [Fact 1]
        - [Fact 2]

        ## 3. Important Notes
        (Combine all important notes from all sections)
        - [Note 1]
        - [Note 2]

        ## 4. Conclusions
        (Synthesize all conclusions and final thoughts into one unified section)

        INPUT SUMMARIES FROM DIFFERENT SECTIONS:
        """
        
        let metaPromptEnd = "\n\nFINAL CONSOLIDATED OUTLINE:\n"
        
        // Use accurate tokenization for size checking
        let getTokenCount: (String) -> Int = { text in
            do {
                return try service.getAccurateTokenCount(text)
            } catch {
                return TokenManager.getTokenCount(text)
            }
        }
        
        let fullMetaPrompt = metaPromptBase + combinedSummariesText + metaPromptEnd
        let metaPromptTokenCount = getTokenCount(fullMetaPrompt)
        let deviceContextSize = DeviceCapabilities.onDeviceLLMContextSize
        let outputReserve = min(2048, max(256, deviceContextSize / 10))
        let maxInputForMeta = deviceContextSize - outputReserve
        
        AppLog.shared.summarization("[OnDeviceLLMEngine] Meta-summary: \(metaPromptTokenCount) tokens, max: \(maxInputForMeta), target: \(targetWords) words", level: .debug)
        
        // If prompt fits, use it directly
        if metaPromptTokenCount <= maxInputForMeta {
            return try await service.generateSummary(from: fullMetaPrompt, contentType: contentType)
        }
        
        // Otherwise, recursively combine in smaller groups
        AppLog.shared.summarization("[OnDeviceLLMEngine] Meta-summary too large, using hierarchical combination")
        return try await combineSummariesRecursive(
            summaries,
            service: service,
            contentType: contentType,
            targetWords: targetWords,
            metaPromptBase: metaPromptBase,
            metaPromptEnd: metaPromptEnd,
            maxInputTokens: maxInputForMeta,
            getTokenCount: getTokenCount
        )
    }
    
    /// Recursively combine summaries in smaller groups until they fit
    private func combineSummariesRecursive(
        _ summaries: [String],
        service: OnDeviceLLMService,
        contentType: ContentType,
        targetWords: Int,
        metaPromptBase: String,
        metaPromptEnd: String,
        maxInputTokens: Int,
        getTokenCount: (String) -> Int
    ) async throws -> String {
        // Base case: single summary
        if summaries.count == 1 {
            return summaries.first ?? ""
        }
        
        // Calculate how many summaries we can fit in one prompt
        let promptOverhead = getTokenCount(metaPromptBase + metaPromptEnd)
        let availableTokens = maxInputTokens - promptOverhead
        
        // Try to combine all summaries if they fit
        let combinedText = summaries.joined(separator: "\n\n=== SECTION ===\n\n")
        let fullPrompt = metaPromptBase + combinedText + metaPromptEnd
        
        if getTokenCount(fullPrompt) <= maxInputTokens {
            // All summaries fit, combine them
            return try await service.generateSummary(from: fullPrompt, contentType: contentType)
        }
        
        // Need to split into smaller groups
        // Calculate how many summaries fit per group
        let avgSummaryTokens = getTokenCount(combinedText) / summaries.count
        let summariesPerGroup = max(1, availableTokens / max(avgSummaryTokens, 1))
        
        AppLog.shared.summarization("[OnDeviceLLMEngine] Splitting \(summaries.count) summaries into groups of ~\(summariesPerGroup)", level: .debug)
        
        // Process in groups
        var intermediateSummaries: [String] = []
        var currentGroup: [String] = []
        var currentGroupTokens = 0
        
        for summary in summaries {
            let summaryTokens = getTokenCount(summary)
            
            // Check if adding this summary would exceed the limit
            let groupText = (currentGroup + [summary]).joined(separator: "\n\n=== SECTION ===\n\n")
            let groupPromptTokens = getTokenCount(metaPromptBase + groupText + metaPromptEnd)
            
            if groupPromptTokens > maxInputTokens && !currentGroup.isEmpty {
                // Finalize current group
                let groupText = currentGroup.joined(separator: "\n\n=== SECTION ===\n\n")
                let groupPrompt = metaPromptBase + groupText + metaPromptEnd
                let combined = try await service.generateSummary(from: groupPrompt, contentType: contentType)
                intermediateSummaries.append(combined)
                
                // Start new group
                currentGroup = [summary]
                currentGroupTokens = summaryTokens
                
                // Small delay between groups
                try await Task.sleep(nanoseconds: 500_000_000)
            } else {
                // Add to current group
                currentGroup.append(summary)
                currentGroupTokens += summaryTokens
            }
        }
        
        // Process remaining group
        if !currentGroup.isEmpty {
            let groupText = currentGroup.joined(separator: "\n\n=== SECTION ===\n\n")
            let groupPrompt = metaPromptBase + groupText + metaPromptEnd
            let combined = try await service.generateSummary(from: groupPrompt, contentType: contentType)
            intermediateSummaries.append(combined)
        }
        
        // Recursively combine intermediate summaries
        return try await combineSummariesRecursive(
            intermediateSummaries,
            service: service,
            contentType: contentType,
            targetWords: targetWords,
            metaPromptBase: metaPromptBase,
            metaPromptEnd: metaPromptEnd,
            maxInputTokens: maxInputTokens,
            getTokenCount: getTokenCount
        )
    }

    // MARK: - Error Handling

    private func handleError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        }

        if let llmError = error as? OnDeviceLLMError {
            switch llmError {
            case .modelNotLoaded, .modelNotDownloaded:
                return SummarizationError.configurationRequired(message: "On-Device AI model not ready. Please download a model in Settings.")
            case .downloadFailed(let message):
                return SummarizationError.processingFailed(reason: "Model download failed: \(message)")
            case .inferenceFailed(let message):
                return SummarizationError.processingFailed(reason: message)
            case .insufficientDiskSpace(let required):
                return SummarizationError.processingFailed(reason: "Insufficient disk space. Need \(formatSize(required)) free.")
            case .networkUnavailable:
                return SummarizationError.networkError(underlying: error)
            case .configurationError(let message):
                return SummarizationError.configurationRequired(message: message)
            }
        }

        return SummarizationError.processingFailed(reason: "On-Device AI error: \(error.localizedDescription)")
    }

    private func formatSize(_ size: Int64) -> String {
        let sizeInGB = Double(size) / 1_000_000_000.0
        return String(format: "%.2f GB", sizeInGB)
    }
}
