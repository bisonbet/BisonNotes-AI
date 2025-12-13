//
//  MistralAIEngine.swift
//  Audio Journal
//
//  Summarization engine for Mistral AI chat models
//

import Foundation
import os.log

class MistralAIEngine: SummarizationEngine, ConnectionTestable {
    let name: String = "Mistral AI"
    let description: String = "Summaries powered by Mistral's latest chat and reasoning models"
    let version: String = "1.0"

    private var service: MistralAISummarizationService?
    private var currentConfig: MistralAIConfig?
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "MistralAIEngine")

    var isAvailable: Bool {
        let apiKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("Mistral API key not configured", category: "MistralAIEngine")
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

        let testPrompt = "Hello from BisonNotes. Please reply with 'Mistral connection confirmed'."

        do {
            let response = try await service.generateSummary(from: testPrompt, contentType: .general)
            let success = response.localizedCaseInsensitiveContains("connection confirmed")
            logger.info("Mistral test connection \(success ? "successful" : "failed")")
            return success
        } catch {
            logger.error("Mistral test connection failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Configuration Management

    private func updateConfiguration() {
        let apiKey = UserDefaults.standard.string(forKey: "mistralAPIKey") ?? ""
        let modelId = UserDefaults.standard.string(forKey: "mistralModel") ?? MistralAIModel.mistralMedium2508.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "mistralBaseURL") ?? "https://api.mistral.ai/v1"
        let temperature = UserDefaults.standard.double(forKey: "mistralTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "mistralMaxTokens")

        let model = MistralAIModel(rawValue: modelId) ?? .mistralMedium2508
        let newConfig = MistralAIConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : model.maxTokens,
            timeout: 45.0
        )

        if currentConfig == nil || currentConfig != newConfig {
            currentConfig = newConfig

            service = MistralAISummarizationService(config: newConfig)

            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Updated Mistral configuration - Model: \(modelId), BaseURL: \(baseURL)", category: "MistralAIEngine")
            }
        }
    }

    // MARK: - Chunked Processing

    private func processChunkedText(_ text: String, service: MistralAISummarizationService, contextWindow: Int) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()

        let chunks = TokenManager.chunkText(text, maxTokens: contextWindow)
        var summaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentType: ContentType = .general

        for (index, chunk) in chunks.enumerated() {
            do {
                let chunkResult = try await service.processComplete(text: chunk)
                summaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)

                if index == 0 {
                    contentType = chunkResult.contentType
                }

                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            } catch {
                logger.error("Failed to process Mistral chunk \(index + 1): \(error.localizedDescription)")
                throw error
            }
        }

        let combinedSummary = try await TokenManager.combineSummaries(
            summaries,
            contentType: contentType,
            service: OllamaService()
        )

        let deduplicatedTasks = deduplicateTasks(allTasks)
        let deduplicatedReminders = deduplicateReminders(allReminders)
        let deduplicatedTitles = deduplicateTitles(allTitles)

        let processingTime = Date().timeIntervalSince(startTime)
        logger.info("Mistral chunked processing completed in \(processingTime)s")

        return (combinedSummary, deduplicatedTasks, deduplicatedReminders, deduplicatedTitles, contentType)
    }

    private func deduplicateTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        var uniqueTasks: [TaskItem] = []

        for task in tasks {
            let isDuplicate = uniqueTasks.contains { existingTask in
                let similarity = calculateTextSimilarity(task.text, existingTask.text)
                return similarity > 0.8
            }

            if !isDuplicate {
                uniqueTasks.append(task)
            }
        }

        return Array(uniqueTasks.prefix(15))
    }

    private func deduplicateReminders(_ reminders: [ReminderItem]) -> [ReminderItem] {
        var uniqueReminders: [ReminderItem] = []

        for reminder in reminders {
            let isDuplicate = uniqueReminders.contains { existingReminder in
                let similarity = calculateTextSimilarity(reminder.text, existingReminder.text)
                return similarity > 0.8
            }

            if !isDuplicate {
                uniqueReminders.append(reminder)
            }
        }

        return Array(uniqueReminders.prefix(15))
    }

    private func deduplicateTitles(_ titles: [TitleItem]) -> [TitleItem] {
        var uniqueTitles: [TitleItem] = []

        for title in titles {
            let isDuplicate = uniqueTitles.contains { existingTitle in
                let similarity = calculateTextSimilarity(title.text, existingTitle.text)
                return similarity > 0.8
            }

            if !isDuplicate {
                uniqueTitles.append(title)
            }
        }

        return Array(uniqueTitles.prefix(5))
    }

    private func handleAPIError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        } else {
            return SummarizationError.aiServiceUnavailable(service: "\(name): \(error.localizedDescription)")
        }
    }
}
