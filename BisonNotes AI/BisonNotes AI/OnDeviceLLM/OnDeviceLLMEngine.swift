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
    var engineType: String { "On Device AI" }
    var description: String { "Private, local summarization using models like Llama, Phi, or Mistral running entirely on your device." }
    let version: String = "1.0"

    var isAvailable: Bool {
        // Check if on-device LLM is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: OnDeviceLLMModelInfo.SettingsKeys.enableOnDeviceLLM)

        guard isEnabled else {
            if OnDeviceLLMFeatureFlags.verboseLogging {
                print("[OnDeviceLLMEngine] Not enabled in settings")
            }
            return false
        }

        // Check if a model is downloaded
        let selectedModel = OnDeviceLLMModelInfo.selectedModel
        guard selectedModel.isDownloaded else {
            if OnDeviceLLMFeatureFlags.verboseLogging {
                print("[OnDeviceLLMEngine] Model not downloaded: \(selectedModel.displayName)")
            }
            return false
        }

        return true
    }
    
    var metadataName: String {
        return OnDeviceLLMModelInfo.selectedModel.displayName
    }

    // MARK: - Private Properties

    private var service: OnDeviceLLMService?
    private var currentConfig: OnDeviceLLMConfig?
    private let logger = Logger(subsystem: "com.bisonnotes.app", category: "OnDeviceLLMEngine")

    // MARK: - Initialization

    init() {
        updateConfiguration()
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
        print("[OnDeviceLLMEngine] Starting summary generation")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let summary = try await service.generateSummary(from: text, contentType: contentType)
            print("[OnDeviceLLMEngine] Summary generated successfully")
            return summary
        } catch {
            print("[OnDeviceLLMEngine] Summary generation failed: \(error)")
            throw handleError(error)
        }
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        print("[OnDeviceLLMEngine] Starting task extraction")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let tasks = try await service.extractTasks(from: text)
            print("[OnDeviceLLMEngine] Extracted \(tasks.count) tasks")
            return tasks
        } catch {
            print("[OnDeviceLLMEngine] Task extraction failed: \(error)")
            throw handleError(error)
        }
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        print("[OnDeviceLLMEngine] Starting reminder extraction")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let reminders = try await service.extractReminders(from: text)
            print("[OnDeviceLLMEngine] Extracted \(reminders.count) reminders")
            return reminders
        } catch {
            print("[OnDeviceLLMEngine] Reminder extraction failed: \(error)")
            throw handleError(error)
        }
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        print("[OnDeviceLLMEngine] Starting title extraction")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        do {
            let titles = try await service.extractTitles(from: text)
            print("[OnDeviceLLMEngine] Extracted \(titles.count) titles")
            return titles
        } catch {
            print("[OnDeviceLLMEngine] Title extraction failed: \(error)")
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
        print("[OnDeviceLLMEngine] Starting complete processing")

        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "On-Device AI service not configured")
        }

        // Check if text needs chunking
        // Use model's actual context capability (capped at 16k for mobile safety) rather than potentially small user setting
        let tokenCount = TokenManager.getTokenCount(text)
        let selectedModel = OnDeviceLLMModelInfo.selectedModel
        let maxContextTokens = min(selectedModel.contextWindow, 16384)
        
        // Reserve ~20% of context for output when deciding chunk size
        let effectiveInputLimit = Int(Double(maxContextTokens) * 0.8)
        print("[OnDeviceLLMEngine] Text token count: \(tokenCount), max context: \(maxContextTokens), effective input limit: \(effectiveInputLimit)")

        do {
            if TokenManager.needsChunking(text, maxTokens: effectiveInputLimit) {
                print("[OnDeviceLLMEngine] Large text detected, using chunked processing")
                return try await processChunkedText(text, service: service, maxTokens: effectiveInputLimit)
            } else {
                print("[OnDeviceLLMEngine] Processing single chunk")
                let result = try await service.processComplete(text: text)

                if let metrics = service.lastMetrics {
                    print("[OnDeviceLLMEngine] Inference completed at \(String(format: "%.1f", metrics.inferenceTokensPerSecond)) tokens/sec")
                }

                return result
            }
        } catch {
            print("[OnDeviceLLMEngine] Complete processing failed: \(error)")
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

        let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
        print("[OnDeviceLLMEngine] Split into \(chunks.count) chunks")

        var allSummaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentType: ContentType = .general

        for (index, chunk) in chunks.enumerated() {
            print("[OnDeviceLLMEngine] Processing chunk \(index + 1)/\(chunks.count)")

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
                    print("[OnDeviceLLMEngine] Background time critical (\(remaining)s), aborting to prevent crash")
                    throw OnDeviceLLMError.inferenceFailed("Insufficient background time remaining")
                }
            }

            do {
                let chunkResult = try await service.processComplete(text: chunk)
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
                print("[OnDeviceLLMEngine] Chunk \(index + 1) failed: \(error)")
                throw error
            }
        }

        // Combine summaries
        let combinedSummary: String
        if allSummaries.count > 1 {
            // Create a meta-summary using the LLM with a structured outline requirement
            let metaPrompt = """
            Here are summaries from different parts of a recording. Consolidate them into a SINGLE, COHERENT Structured Outline.

            CRITICAL INSTRUCTIONS:
            1. Create ONE unified "Overview" section that covers the entire recording.
            2. Merge all "Key Facts & Details" into a single comprehensive list.
            3. Combine "Important Notes" and "Conclusions".
            4. Resolve any redundancies between sections.
            5. Maintain the 15% detail level - do not over-condense.

            INPUT SUMMARIES:
            \(allSummaries.joined(separator: "\n\n=== SECTION ===\n\n"))

            FINAL CONSOLIDATED OUTLINE:
            """
            combinedSummary = try await service.generateSummary(from: metaPrompt, contentType: contentType)
        } else {
            combinedSummary = allSummaries.first ?? ""
        }

        // Deduplicate
        let uniqueTasks = deduplicateItems(allTasks, limit: 15) { $0.text }
        let uniqueReminders = deduplicateItems(allReminders, limit: 15) { $0.text }
        let uniqueTitles = deduplicateItems(allTitles, limit: 5) { $0.text }

        let processingTime = Date().timeIntervalSince(startTime)
        print("[OnDeviceLLMEngine] Chunked processing completed in \(String(format: "%.1f", processingTime))s")

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
        print("[OnDeviceLLMEngine] Testing connection...")

        updateConfiguration()

        guard let service = service else {
            print("[OnDeviceLLMEngine] Service not configured")
            return false
        }

        let result = await service.testConnection()
        print("[OnDeviceLLMEngine] Connection test result: \(result)")
        return result
    }

    // MARK: - Error Handling

    private func handleError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        }

        if let llmError = error as? OnDeviceLLMError {
            switch llmError {
            case .modelNotLoaded, .modelNotDownloaded:
                return SummarizationError.aiServiceUnavailable(service: "On-Device AI model not ready. Please download a model in Settings.")
            case .downloadFailed(let message):
                return SummarizationError.aiServiceUnavailable(service: "Model download failed: \(message)")
            case .inferenceFailed(let message):
                return SummarizationError.aiServiceUnavailable(service: "Inference failed: \(message)")
            case .insufficientDiskSpace(let required):
                return SummarizationError.aiServiceUnavailable(service: "Insufficient disk space. Need \(formatSize(required)) free.")
            case .networkUnavailable:
                return SummarizationError.aiServiceUnavailable(service: "Network unavailable for model download")
            case .configurationError(let message):
                return SummarizationError.aiServiceUnavailable(service: message)
            }
        }

        return SummarizationError.aiServiceUnavailable(service: "On-Device AI error: \(error.localizedDescription)")
    }

    private func formatSize(_ size: Int64) -> String {
        let sizeInGB = Double(size) / 1_000_000_000.0
        return String(format: "%.2f GB", sizeInGB)
    }
}
