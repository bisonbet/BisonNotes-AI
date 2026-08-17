//
//  OnDeviceLLMEngine.swift
//  BisonNotes AI
//
//  SummarizationEngine implementation for on-device LLM
//  Integrates with BisonNotes AI engine system
//

import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

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
    /// Tokens live outside the engine's actor isolation so the nonisolated
    /// Swift 6 deinit can still unregister them. NotificationCenter retains
    /// block observers until `removeObserver` is called, and engines are
    /// constructed per availability check (`AIEngineFactory.getAvailableEngines`),
    /// so leaving registrations behind accumulates them for the process lifetime.
    private let lifecycleObservers = LifecycleObserverTokens()

    // MARK: - Initialization

    init() {
        updateConfiguration()
        setupBackgroundObservers()
    }

    deinit {
        lifecycleObservers.removeAll()
    }

    // MARK: - Background Safety

    /// Observe app lifecycle to prevent Metal GPU work from background.
    /// iOS kills Metal command buffers submitted from background apps, causing
    /// a fatal crash in llama.cpp's Metal backend (ggml_abort).
    private func setupBackgroundObservers() {
        // The background/foreground GPU pause is an iOS-only safeguard. On native
        // macOS, PlatformLifecycle.didEnterBackgroundNotification maps to
        // NSApplication.didHideNotification (Cmd-H); a hidden Mac app can still run
        // Metal, so treating a hide as backgrounding would needlessly abort an
        // in-flight summarization. Only observe these on iOS.
        #if os(iOS)
        lifecycleObservers.add(NotificationCenter.default.addObserver(
            forName: PlatformLifecycle.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppLog.shared.summarization("[OnDeviceLLMEngine] App entered background - pausing GPU inference")
                await self?.service?.setAppBackgrounded(true)
            }
        })

        lifecycleObservers.add(NotificationCenter.default.addObserver(
            forName: PlatformLifecycle.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                AppLog.shared.summarization("[OnDeviceLLMEngine] App entering foreground - resuming GPU inference")
                await self?.service?.setAppBackgrounded(false)
            }
        })
        #endif

        // On macOS, quitting via the menu calls NSApplication.terminate: → exit().
        // Static C++ destructors for ggml_metal_device then run before Swift deinits, which
        // triggers GGML_ASSERT([rsets->data count] == 0) if any Metal command buffers are
        // still in flight. Explicitly unloading the model here forces llama_free /
        // llama_model_free to run before exit(), releasing all Metal resources cleanly.
        lifecycleObservers.add(NotificationCenter.default.addObserver(
            forName: PlatformLifecycle.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // This observer is posted on the main queue during terminate, so the
            // isolation assumption holds. The unload must *complete* before this
            // returns: merely scheduling it lets exit() run the ggml_metal_device
            // destructors first, which is exactly the assert this guards against.
            MainActor.assumeIsolated {
                guard let self, let service = self.service else { return }
                self.service = nil

                AppLog.shared.summarization("[OnDeviceLLMEngine] App will terminate - releasing llama.cpp Metal resources")

                // The unload runs on the inference actor, which never hops back
                // to the main actor, so blocking here cannot deadlock. The cap
                // keeps a wedged unload from stalling quit indefinitely.
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached(priority: .userInitiated) {
                    await service.unloadModel()
                    semaphore.signal()
                }
                if semaphore.wait(timeout: .now() + 3) == .timedOut {
                    AppLog.shared.summarization(
                        "[OnDeviceLLMEngine] Timed out waiting for model unload during termination",
                        level: .error
                    )
                }
            }
        })
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

    func processComplete(text: String) async throws -> SummarizationResult {
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
            try await service.ensureModelLoaded()
            tokenCount = try await service.getAccurateTokenCount(text)
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
                if await service.wasInterruptedByBackground {
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Inference interrupted by app backgrounding (GPU not available)", level: .error)
                    throw OnDeviceLLMError.inferenceFailed("On-device AI needs the app to stay open. Please return to the app and try again.")
                }

                if let metrics = await service.lastMetrics {
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
    ) async throws -> SummarizationResult {
        let startTime = Date()

        // Ensure model is loaded to use accurate tokenization
        try await service.ensureModelLoaded()

        // Size the chunks with the model's own tokenizer. The estimator
        // undercounts real BPE tokens, so chunking with it produces chunks that
        // overflow the context window and get truncated at inference time — the
        // validation loop below can only report that, not repair it.
        // Use 100 tokens overlap (approximately 75-100 words) to preserve context at boundaries
        let overlapTokens = 100

        let chunks = await TokenManager.chunkTextWithOverlapAsync(
            text,
            maxTokens: maxTokens,
            overlapTokens: overlapTokens
        ) { sentence in
            do {
                return try await service.getAccurateTokenCount(sentence)
            } catch {
                // Fall back to estimation if the tokenizer is unavailable
                AppLog.shared.summarization("[OnDeviceLLMEngine] Could not use accurate tokenizer, falling back to estimation: \(error)", level: .error)
                return TokenManager.getTokenCount(sentence)
            }
        }
        AppLog.shared.summarization("[OnDeviceLLMEngine] Split into \(chunks.count) chunks with \(overlapTokens) token overlap")

        // Validate chunk sizes using accurate tokenization
        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkTokenCount = try await service.getAccurateTokenCount(chunk)
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
            let isBackground = await MainActor.run {
                PlatformApp.isInBackground
            }

            if isBackground {
                let remaining = await MainActor.run {
                    PlatformBackgroundTask.remainingTime
                }

                if remaining < 10 { // Less than 10 seconds remaining
                    AppLog.shared.summarization("[OnDeviceLLMEngine] Background time critical (\(remaining)s), aborting to prevent crash", level: .error)
                    throw OnDeviceLLMError.inferenceFailed("On-device AI needs the app to stay open. Please return to the app and try again.")
                }
            }

            do {
                let chunkResult = try await service.processComplete(text: chunk)

                // Check if chunk processing was interrupted by backgrounding
                if await service.wasInterruptedByBackground {
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

        return SummarizationResult(
            summary: combinedSummary,
            tasks: uniqueTasks,
            reminders: uniqueReminders,
            titles: uniqueTitles,
            contentType: contentType
        )
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
    /// - Returns: A single consolidated summary at the user's selected detail level
    private func combineChunkSummaries(
        _ summaries: [String],
        service: OnDeviceLLMService,
        contentType: ContentType,
        originalWordCount: Int
    ) async throws -> String {
        // Calculate the target from the ORIGINAL transcript, not the already summarized chunks.
        // This keeps the selected detail level proportional to the recording's actual length.
        let detailLevel = SummaryDetailLevel.current
        let targetRange = detailLevel.targetWordRange(for: originalWordCount)
        let targetWords = targetRange.upperBound
        let detailInstructions = detailLevel.promptInstructions(
            forSourceWordCount: originalWordCount
        )

        let combinedSummariesText = summaries.joined(separator: "\n\n=== SECTION ===\n\n")

        // Create a comprehensive meta-summary prompt that matches the structure of initial summaries
        let metaPromptBase = """
        You are consolidating summaries from different parts of a single recording into ONE unified, comprehensive Structured Outline.

        CRITICAL REQUIREMENTS:
        - The final summary must follow the selected detail level.
        \(detailInstructions)
        - Create a SINGLE, COHERENT outline that covers the ENTIRE recording.
        - Use the EXACT same structured format as the input summaries.
        - Do NOT simply concatenate - merge, deduplicate, and synthesize information.

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

        // Use accurate tokenization for size checking. Falling back to the
        // estimator here would undercount the prompt and let the meta-summary
        // overflow the context window.
        let getTokenCount: (String) async -> Int = { text in
            do {
                return try await service.getAccurateTokenCount(text)
            } catch {
                return TokenManager.getTokenCount(text)
            }
        }

        let fullMetaPrompt = metaPromptBase + combinedSummariesText + metaPromptEnd
        let metaPromptTokenCount = await getTokenCount(fullMetaPrompt)
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
        getTokenCount: (String) async -> Int
    ) async throws -> String {
        // Base case: single summary
        if summaries.count == 1 {
            return summaries.first ?? ""
        }

        // Calculate how many summaries we can fit in one prompt
        let promptOverhead = await getTokenCount(metaPromptBase + metaPromptEnd)
        let availableTokens = maxInputTokens - promptOverhead

        // Try to combine all summaries if they fit
        let combinedText = summaries.joined(separator: "\n\n=== SECTION ===\n\n")
        let fullPrompt = metaPromptBase + combinedText + metaPromptEnd

        if await getTokenCount(fullPrompt) <= maxInputTokens {
            // All summaries fit, combine them
            return try await service.generateSummary(from: fullPrompt, contentType: contentType)
        }

        // Need to split into smaller groups
        // Calculate how many summaries fit per group
        let avgSummaryTokens = await getTokenCount(combinedText) / summaries.count
        let summariesPerGroup = max(1, availableTokens / max(avgSummaryTokens, 1))

        AppLog.shared.summarization("[OnDeviceLLMEngine] Splitting \(summaries.count) summaries into groups of ~\(summariesPerGroup)", level: .debug)

        // Process in groups
        var intermediateSummaries: [String] = []
        var currentGroup: [String] = []
        var currentGroupTokens = 0

        for summary in summaries {
            let summaryTokens = await getTokenCount(summary)

            // Check if adding this summary would exceed the limit
            let groupText = (currentGroup + [summary]).joined(separator: "\n\n=== SECTION ===\n\n")
            let groupPromptTokens = await getTokenCount(metaPromptBase + groupText + metaPromptEnd)

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
