//
//  OpenAICompatibleEngine.swift
//  BisonNotes AI
//
//  Compatible API summarization engine implementation
//

import Foundation

// MARK: - Compatible API Engine

class OpenAICompatibleEngine: SummarizationEngine, ConnectionTestable {
    var name: String { "Compatible API" }
    var engineType: String { AIEngineType.openAICompatible.rawValue }
    var description: String { "Connect to a compatible API endpoint (for example, a local server or custom provider)." }
    let version: String = "1.0"
    var metadataName: String {
        return UserDefaults.standard.string(forKey: "openAICompatibleModel") ?? ""
    }

    private var service: OpenAICompatibleService?
    private var currentConfig: OpenAICompatibleConfig?

    var isAvailable: Bool {
        // Check if API key is configured
        let apiKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.openAICompatibleAPIKey) ?? ""
        guard !apiKey.isEmpty else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("API key not configured", category: "OpenAICompatibleEngine")
            }
            return false
        }

        // Check if the compatible API is enabled in settings
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOpenAICompatible")
        let keyExists = UserDefaults.standard.object(forKey: "enableOpenAICompatible") != nil

        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Checking enableOpenAICompatible setting - Value: \(isEnabled), Key exists: \(keyExists)", category: "OpenAICompatibleEngine")
        }

        guard isEnabled else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Compatible API is not enabled in settings", category: "OpenAICompatibleEngine")
            }
            return false
        }

        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Basic availability checks passed", category: "OpenAICompatibleEngine")
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
            AppLog.shared.summarization("CompatibleAPIEngine: Failed to generate summary: \(error)", level: .error)
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
            AppLog.shared.summarization("CompatibleAPIEngine: Failed to extract tasks: \(error)", level: .error)
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
            AppLog.shared.summarization("CompatibleAPIEngine: Failed to extract reminders: \(error)", level: .error)
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
            AppLog.shared.summarization("CompatibleAPIEngine: Failed to extract titles: \(error)", level: .error)
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
            AppLog.shared.summarization("CompatibleAPIEngine: Failed to classify content: \(error)", level: .error)
            return .general
        }
    }

    func processComplete(text: String) async throws -> SummarizationResult {
        updateConfiguration()

        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }

        do {
            return try await service.processComplete(text: text)
        } catch {
            AppLog.shared.summarization("CompatibleAPIEngine: Failed to process complete: \(error)", level: .error)
            throw handleAPIError(error)
        }
    }

    func testConnection() async -> Bool {
        updateConfiguration()

        guard let service = service else {
            return false
        }

        let connectionResult = await service.testConnection()
        if connectionResult {
            AppLog.shared.summarization("CompatibleAPIEngine: Connection test successful")
            return true
        } else {
            AppLog.shared.summarization("CompatibleAPIEngine: Connection test failed", level: .error)
            return false
        }
    }

    // MARK: - Configuration Management

    private func updateConfiguration() {
        let apiKey = KeychainSecretStore.shared.string(forKey: KeychainSecretStore.openAICompatibleAPIKey) ?? ""
        let modelId = UserDefaults.standard.string(forKey: "openAICompatibleModel") ?? ""
        let baseURL = UserDefaults.standard.string(forKey: "openAICompatibleBaseURL") ?? ""
        let temperature = UserDefaults.standard.double(forKey: "openAICompatibleTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "openAICompatibleMaxTokens")

        let newConfig = OpenAICompatibleConfig(
            apiKey: apiKey,
            modelID: modelId,
            baseURL: baseURL,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : 2048,
            timeout: SummarizationTimeouts.current(),
            dynamicModelId: modelId // Pass the actual model ID for dynamic models
        )

        // Only create a new service if the configuration has actually changed
        if currentConfig == nil || currentConfig != newConfig {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Updating configuration - Model: \(modelId), BaseURL: \(baseURL)", category: "OpenAICompatibleEngine")
            }

            self.currentConfig = newConfig
            self.service = OpenAICompatibleService(config: newConfig)

            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Configuration updated successfully", category: "OpenAICompatibleEngine")
            }
        }
    }

    private func handleAPIError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        } else {
            return SummarizationError.aiServiceUnavailable(service: "\(name): \(error.localizedDescription)")
        }
    }
}
