//
//  MistralAIEngine.swift
//  Audio Journal
//
//  Summarization engine for Mistral AI chat models
//

import Foundation
import os.log

class MistralAIEngine: SummarizationEngine, ConnectionTestable {
    var name: String { "Mistral AI" }
    var engineType: String { "Mistral" }
    var description: String { "Advanced summarization using Mistral AI's optimized models." }
    let version: String = "1.0"

    private var service: MistralAISummarizationService?
    private var currentConfig: MistralAIConfig?
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "MistralAIEngine")

    // MARK: - Configuration Constants

    /// Maximum number of tasks to extract per recording to prevent overwhelming the user
    private let maxTasksPerRecording = 15

    /// Maximum number of reminders to extract per recording to prevent overwhelming the user
    private let maxRemindersPerRecording = 15

    /// Maximum number of title suggestions per recording to keep UI manageable
    private let maxTitlesPerRecording = 5

    /// Similarity threshold for deduplication using Jaccard similarity (0.0 = no match, 1.0 = exact match)
    ///
    /// **Rationale for 0.8:**
    /// - Values ≥ 0.8 catch semantically identical items with minor wording differences
    ///   (e.g., "Review the quarterly report" vs "Review quarterly report")
    /// - Values < 0.8 allow legitimate variations to coexist
    ///   (e.g., "Review Q1 report" and "Review Q2 report" both kept)
    /// - Tested empirically to balance duplicate removal with preserving distinct items
    /// - Higher values (0.9+) miss too many near-duplicates
    /// - Lower values (0.6-0.7) incorrectly merge distinct but related items
    private let deduplicationSimilarityThreshold = 0.8

    var isAvailable: Bool {
        let apiKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("Mistral AI API key not configured", category: "MistralAIEngine")
            }
            return false
        }

        let isEnabled = UserDefaults.standard.bool(forKey: "enableMistralAI")
        let keyExists = UserDefaults.standard.object(forKey: "enableMistralAI") != nil

        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Checking enableMistralAI setting - Value: \(isEnabled), Key exists: \(keyExists)", category: "MistralAIEngine")
        }

        guard isEnabled else {
            return false
        }

        return true
    }

    init() {
        updateConfiguration()
    }

    /// Generate a summary of the provided text
    ///
    /// - Parameters:
    ///   - text: The transcript text to summarize
    ///   - contentType: The type of content (meeting, lecture, conversation, etc.)
    /// - Returns: A markdown-formatted summary appropriate for the content type
    /// - Throws: `SummarizationError` if the API call fails or service is unavailable
    ///
    /// **Chunking Strategy:**
    /// If text exceeds the model's context window, it will be automatically chunked,
    /// processed in segments, and combined into a cohesive meta-summary.
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }

        do {
            return try await service.generateSummary(from: text, contentType: contentType)
        } catch {
            logger.error("Failed to generate summary: \(error.localizedDescription)")
            throw handleAPIError(error)
        }
    }

    /// Extract tasks from the provided text
    ///
    /// - Parameter text: The transcript text to extract tasks from
    /// - Returns: Array of task items (max 15)
    /// - Throws: `SummarizationError` if the API call fails or service is unavailable
    ///
    /// **Performance Note:**
    /// This method calls `processComplete()` internally, which extracts ALL content (summary, tasks, reminders, titles).
    /// If you need multiple types of extracted data, call `processComplete()` directly instead of calling
    /// `extractTasks()`, `extractReminders()`, and `extractTitles()` separately to avoid redundant API calls.
    func extractTasks(from text: String) async throws -> [TaskItem] {
        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }

        do {
            let result = try await service.processComplete(text: text)
            return result.tasks
        } catch {
            logger.error("Failed to extract tasks: \(error.localizedDescription)")
            throw handleAPIError(error)
        }
    }

    /// Extract reminders from the provided text
    ///
    /// - Parameter text: The transcript text to extract reminders from
    /// - Returns: Array of reminder items (max 15)
    /// - Throws: `SummarizationError` if the API call fails or service is unavailable
    ///
    /// **Performance Note:**
    /// This method calls `processComplete()` internally, which extracts ALL content (summary, tasks, reminders, titles).
    /// If you need multiple types of extracted data, call `processComplete()` directly instead of calling
    /// `extractTasks()`, `extractReminders()`, and `extractTitles()` separately to avoid redundant API calls.
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }

        do {
            let result = try await service.processComplete(text: text)
            return result.reminders
        } catch {
            logger.error("Failed to extract reminders: \(error.localizedDescription)")
            throw handleAPIError(error)
        }
    }

    /// Extract title suggestions from the provided text
    ///
    /// - Parameter text: The transcript text to extract title suggestions from
    /// - Returns: Array of title items (max 5)
    /// - Throws: `SummarizationError` if the API call fails or service is unavailable
    ///
    /// **Performance Note:**
    /// This method calls `processComplete()` internally, which extracts ALL content (summary, tasks, reminders, titles).
    /// If you need multiple types of extracted data, call `processComplete()` directly instead of calling
    /// `extractTasks()`, `extractReminders()`, and `extractTitles()` separately to avoid redundant API calls.
    func extractTitles(from text: String) async throws -> [TitleItem] {
        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }

        do {
            let result = try await service.processComplete(text: text)
            return result.titles
        } catch {
            logger.error("Failed to extract titles: \(error.localizedDescription)")
            throw handleAPIError(error)
        }
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        updateConfiguration()

        guard let service = service else {
            return .general
        }

        do {
            return try await service.classifyContent(text)
        } catch {
            logger.error("Failed to classify content: \(error.localizedDescription)")
            return .general
        }
    }

    /// Process text and extract all available information in a single call
    ///
    /// - Parameter text: The transcript text to process
    /// - Returns: A tuple containing summary, tasks (max 15), reminders (max 15), titles (max 5), and detected content type
    /// - Throws: `SummarizationError` if the API call fails or service is unavailable
    ///
    /// **Performance:**
    /// - Uses chunked processing for large transcripts (>context window)
    /// - Implements hash-based deduplication for extracted items
    /// - Applies configurable rate limiting between chunks based on model tier
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }

        let contextWindow = currentConfig?.model.contextWindow ?? TokenManager.maxTokensPerChunk

        if TokenManager.needsChunking(text, maxTokens: contextWindow) {
            return try await processChunkedText(text, service: service, contextWindow: contextWindow)
        }

        return try await service.processComplete(text: text)
    }

    func testConnection() async -> Bool {
        updateConfiguration()

        guard let service = service else {
            return false
        }

        let testPrompt = "Test connection"

        do {
            let response = try await service.generateSummary(from: testPrompt, contentType: .general)
            // Accept any non-empty response as success - the model doesn't need to return specific text
            let success = !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            logger.info("Mistral AI test connection \(success ? "successful" : "failed") - Response length: \(response.count)")
            return success
        } catch {
            logger.error("Mistral AI test connection failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Configuration Management

    /// Updates configuration from UserDefaults if settings have changed
    ///
    /// This method is called at the start of each operation to ensure the latest user settings are used.
    /// The configuration is only recreated if settings have actually changed (via equality check),
    /// preventing unnecessary service recreation and ensuring thread-safe access to latest settings.
    private func updateConfiguration() {
        let apiKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        let modelId = UserDefaults.standard.string(forKey: "mistralModel") ?? MistralAIModel.mistralMedium2508.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "mistralBaseURL") ?? "https://api.mistral.ai/v1"
        let temperature = UserDefaults.standard.double(forKey: "mistralTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "mistralMaxTokens")

        // Auto-detect JSON response format support based on URL, but allow user override
        let autoDetectedJsonSupport = baseURL.lowercased().contains("api.mistral.ai")
        let hasUserOverride = UserDefaults.standard.object(forKey: "mistralSupportsJsonResponseFormat") != nil
        let supportsJsonResponseFormat = hasUserOverride
            ? UserDefaults.standard.bool(forKey: "mistralSupportsJsonResponseFormat")
            : autoDetectedJsonSupport

        // Log when auto-detection is used or when it differs from user override
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            if hasUserOverride {
                let userSetting = UserDefaults.standard.bool(forKey: "mistralSupportsJsonResponseFormat")
                if userSetting != autoDetectedJsonSupport {
                    AppLogger.shared.verbose("Mistral AI JSON format: user override (\(userSetting)) differs from auto-detection (\(autoDetectedJsonSupport))", category: "MistralAIEngine")
                }
            } else {
                AppLogger.shared.verbose("Mistral AI JSON format: using auto-detection (\(autoDetectedJsonSupport)) based on URL", category: "MistralAIEngine")
            }
        }

        let model = MistralAIModel(rawValue: modelId) ?? .mistralMedium2508
        let newConfig = MistralAIConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : model.maxTokens,
            timeout: SummarizationTimeouts.current(),
            supportsJsonResponseFormat: supportsJsonResponseFormat
        )

        // Only recreate service if configuration actually changed (prevents unnecessary overhead)
        if currentConfig == nil || currentConfig != newConfig {
            currentConfig = newConfig

            service = MistralAISummarizationService(config: newConfig)

            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Updated Mistral AI configuration - Model: \(modelId), BaseURL: \(baseURL), JSON Format: \(supportsJsonResponseFormat)", category: "MistralAIEngine")
            }
        }
    }

    // MARK: - Chunked Processing

    /// Process large transcripts that exceed the model's context window
    ///
    /// **Chunking Strategy:**
    /// 1. Split text into sentence-boundary chunks that fit within context window
    /// 2. Process each chunk independently to extract summaries, tasks, reminders, and titles
    /// 3. Combine chunk summaries using recursive meta-summarization
    /// 4. Deduplicate extracted items using hash + similarity checks
    /// 5. Apply rate limiting between chunks based on model tier
    ///
    /// **Error Recovery:**
    /// - If a chunk fails, it will be retried once after a short delay
    /// - If retry fails, the chunk is skipped and processing continues with remaining chunks
    /// - At least one successful chunk is required; otherwise the entire operation fails
    ///
    /// - Parameters:
    ///   - text: The large transcript text to process
    ///   - service: The Mistral AI service instance to use
    ///   - contextWindow: Maximum tokens per chunk (model-specific)
    /// - Returns: Combined results from all chunks with deduplicated items
    /// - Throws: `SummarizationError` if all chunks fail or no successful results are obtained
    private func processChunkedText(_ text: String, service: MistralAISummarizationService, contextWindow: Int) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()

        let chunks = TokenManager.chunkText(text, maxTokens: contextWindow)
        var summaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentType: ContentType = .general
        var successfulChunks = 0
        var failedChunks = 0

        for (index, chunk) in chunks.enumerated() {
            var retryCount = 0
            let maxRetries = 1
            var chunkProcessed = false

            while retryCount <= maxRetries && !chunkProcessed {
                do {
                    let chunkResult = try await service.processComplete(text: chunk)
                    summaries.append(chunkResult.summary)
                    allTasks.append(contentsOf: chunkResult.tasks)
                    allReminders.append(contentsOf: chunkResult.reminders)
                    allTitles.append(contentsOf: chunkResult.titles)

                    if index == 0 {
                        contentType = chunkResult.contentType
                    }

                    successfulChunks += 1
                    chunkProcessed = true

                    if index < chunks.count - 1 {
                        let delay = currentConfig?.model.rateLimitDelay ?? 300_000_000
                        try await Task.sleep(nanoseconds: delay)
                    }
                } catch {
                    retryCount += 1
                    if retryCount <= maxRetries {
                        logger.warning("Failed to process Mistral chunk \(index + 1), retrying (\(retryCount)/\(maxRetries)): \(error.localizedDescription)")
                        // Brief delay before retry (1 second)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    } else {
                        logger.error("Failed to process Mistral chunk \(index + 1) after \(maxRetries) retries, skipping: \(error.localizedDescription)")
                        failedChunks += 1
                        chunkProcessed = true  // Move on to next chunk
                    }
                }
            }
        }

        // Require at least one successful chunk
        guard successfulChunks > 0 else {
            logger.error("All \(chunks.count) chunks failed to process")
            throw SummarizationError.aiServiceUnavailable(service: "Mistral AI - All chunks failed to process")
        }

        if failedChunks > 0 {
            logger.warning("Completed chunked processing with \(successfulChunks) successful and \(failedChunks) failed chunks")
        }

        let combinedSummary = try await combineSummaries(summaries, contentType: contentType, service: service)

        let deduplicatedTasks = deduplicateTasks(allTasks)
        let deduplicatedReminders = deduplicateReminders(allReminders)
        let deduplicatedTitles = deduplicateTitles(allTitles)

        let processingTime = Date().timeIntervalSince(startTime)
        logger.info("Mistral AI chunked processing completed in \(processingTime)s")

        return (combinedSummary, deduplicatedTasks, deduplicatedReminders, deduplicatedTitles, contentType)
    }

    private func deduplicateTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        var uniqueTasks: [TaskItem] = []
        var seenHashes = Set<String>()
        var normalizedTexts: [String] = []  // Store normalized texts for similarity check

        for task in tasks {
            let normalizedText = task.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // Fast exact duplicate check using hash - skip immediately if found
            if seenHashes.contains(normalizedText) {
                continue
            }

            // Slower similarity check for near-duplicates - only check against unique items
            var isDuplicate = false
            for existingNormalizedText in normalizedTexts {
                // Skip if this existing task was already caught by hash check (shouldn't happen but defensive)
                if seenHashes.contains(existingNormalizedText) && existingNormalizedText == normalizedText {
                    continue
                }

                let similarity = calculateTextSimilarity(normalizedText, existingNormalizedText)
                if similarity > deduplicationSimilarityThreshold {
                    isDuplicate = true
                    break  // Early exit - no need to check remaining items
                }
            }

            if !isDuplicate {
                uniqueTasks.append(task)
                seenHashes.insert(normalizedText)
                normalizedTexts.append(normalizedText)  // Cache normalized text for reuse
            }
        }

        return Array(uniqueTasks.prefix(maxTasksPerRecording))
    }

    private func deduplicateReminders(_ reminders: [ReminderItem]) -> [ReminderItem] {
        var uniqueReminders: [ReminderItem] = []
        var seenHashes = Set<String>()
        var normalizedTexts: [String] = []  // Store normalized texts for similarity check

        for reminder in reminders {
            let normalizedText = reminder.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // Fast exact duplicate check using hash - skip immediately if found
            if seenHashes.contains(normalizedText) {
                continue
            }

            // Slower similarity check for near-duplicates - only check against unique items
            var isDuplicate = false
            for existingNormalizedText in normalizedTexts {
                let similarity = calculateTextSimilarity(normalizedText, existingNormalizedText)
                if similarity > deduplicationSimilarityThreshold {
                    isDuplicate = true
                    break  // Early exit - no need to check remaining items
                }
            }

            if !isDuplicate {
                uniqueReminders.append(reminder)
                seenHashes.insert(normalizedText)
                normalizedTexts.append(normalizedText)  // Cache normalized text for reuse
            }
        }

        return Array(uniqueReminders.prefix(maxRemindersPerRecording))
    }

    private func deduplicateTitles(_ titles: [TitleItem]) -> [TitleItem] {
        var uniqueTitles: [TitleItem] = []
        var seenHashes = Set<String>()
        var normalizedTexts: [String] = []  // Store normalized texts for similarity check

        for title in titles {
            let normalizedText = title.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // Fast exact duplicate check using hash - skip immediately if found
            if seenHashes.contains(normalizedText) {
                continue
            }

            // Slower similarity check for near-duplicates - only check against unique items
            var isDuplicate = false
            for existingNormalizedText in normalizedTexts {
                let similarity = calculateTextSimilarity(normalizedText, existingNormalizedText)
                if similarity > deduplicationSimilarityThreshold {
                    isDuplicate = true
                    break  // Early exit - no need to check remaining items
                }
            }

            if !isDuplicate {
                uniqueTitles.append(title)
                seenHashes.insert(normalizedText)
                normalizedTexts.append(normalizedText)  // Cache normalized text for reuse
            }
        }

        return Array(uniqueTitles.prefix(maxTitlesPerRecording))
    }

    /// Combine multiple summaries into a cohesive meta-summary using Mistral
    private func combineSummaries(
        _ summaries: [String],
        contentType: ContentType,
        service: MistralAISummarizationService
    ) async throws -> String {
        guard !summaries.isEmpty else { return "" }

        // Join all summaries into one text block
        let combinedText = summaries.joined(separator: "\n\n")

        // Generate meta-summary ensuring context limits are respected
        let metaSummary = try await generateMetaSummary(from: combinedText, contentType: contentType, service: service, depth: 0)

        return metaSummary
    }

    /// Recursively generate a meta-summary that fits within the model's context window
    ///
    /// - Parameters:
    ///   - text: The text to summarize
    ///   - contentType: The type of content being summarized
    ///   - service: The Mistral AI service instance
    ///   - depth: Current recursion depth (used to prevent infinite recursion)
    /// - Returns: A summarized version of the text
    /// - Throws: `SummarizationError` if recursion depth is exceeded or API call fails
    private func generateMetaSummary(
        from text: String,
        contentType: ContentType,
        service: MistralAISummarizationService,
        depth: Int = 0
    ) async throws -> String {
        // Prevent infinite recursion
        guard depth < 10 else {
            logger.error("Meta-summary recursion depth exceeded at level \(depth)")
            throw SummarizationError.aiServiceUnavailable(service: "Mistral AI - Summary processing too complex (recursion limit reached)")
        }
        let maxTokens = currentConfig?.model.contextWindow ?? TokenManager.maxTokensPerChunk

        // If text fits within context window, summarize directly
        if TokenManager.getTokenCount(text) <= maxTokens {
            return try await service.generateSummary(from: text, contentType: contentType)
        }

        // Otherwise, chunk the text and summarize each piece
        let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
        var intermediateSummaries: [String] = []

        for (index, chunk) in chunks.enumerated() {
            logger.info("Processing meta-summary chunk \(index + 1) of \(chunks.count)")
            let summary = try await service.generateSummary(from: chunk, contentType: contentType)
            intermediateSummaries.append(summary)

            // Small delay between requests to prevent overwhelming the server
            if index < chunks.count - 1 {
                let delay = currentConfig?.model.rateLimitDelay ?? 300_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }

        // Recursively summarize the combined intermediate summaries
        let reducedText = intermediateSummaries.joined(separator: "\n\n")
        return try await generateMetaSummary(from: reducedText, contentType: contentType, service: service, depth: depth + 1)
    }

    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))

        let intersection = words1.intersection(words2)
        let union = words1.union(words2)

        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }

    private func handleAPIError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        } else {
            return SummarizationError.aiServiceUnavailable(service: "\(name): \(error.localizedDescription)")
        }
    }
}
