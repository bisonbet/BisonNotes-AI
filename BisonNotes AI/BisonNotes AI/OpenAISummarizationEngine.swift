//
//  OpenAISummarizationEngine.swift
//  Audio Journal
//
//  OpenAI-powered summarization engine implementation
//

import Foundation

class OpenAISummarizationEngine: SummarizationEngine, ConnectionTestable {
    let name: String = "OpenAI"
    let description: String = "Advanced AI-powered summaries using OpenAI's GPT models"
    let version: String = "1.0"
    
    private var service: OpenAISummarizationService?
    private var currentConfig: OpenAISummarizationConfig?
    
    var isAvailable: Bool {
        // Check if API key is configured (unified with transcription)
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("API key not configured", category: "OpenAISummarizationEngine")
            }
            return false
        }
        
        // Check if OpenAI is enabled in settings
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOpenAI")
        let keyExists = UserDefaults.standard.object(forKey: "enableOpenAI") != nil
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Checking enableOpenAI setting - Value: \(isEnabled), Key exists: \(keyExists)", category: "OpenAISummarizationEngine")
        }
        
        guard isEnabled else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("OpenAI is not enabled in settings", category: "OpenAISummarizationEngine")
            }
            return false
        }
        
        // Basic API key format validation
        guard apiKey.hasPrefix("sk-") else {
            AppLogger.shared.error("Invalid API key format", category: "OpenAISummarizationEngine")
            return false
        }
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Basic availability checks passed", category: "OpenAISummarizationEngine")
        }
        return true
    }
    
    init() {
        updateConfiguration()
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        print("🤖 OpenAISummarizationEngine: Starting summary generation")
        
        updateConfiguration()
        
        guard let service = service else {
            print("❌ OpenAISummarizationEngine: Service is nil")
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI service not properly configured")
        }
        
        print("✅ OpenAISummarizationEngine: Calling OpenAI service for summary")
        
        do {
            return try await service.generateSummary(from: text, contentType: contentType)
        } catch {
            print("❌ OpenAISummarizationEngine: Summary generation failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        print("🤖 OpenAISummarizationEngine: Starting task extraction")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI service not properly configured")
        }
        
        do {
            return try await service.extractTasks(from: text)
        } catch {
            print("❌ OpenAISummarizationEngine: Task extraction failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        print("🤖 OpenAISummarizationEngine: Starting reminder extraction")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI service not properly configured")
        }
        
        do {
            return try await service.extractReminders(from: text)
        } catch {
            print("❌ OpenAISummarizationEngine: Reminder extraction failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        print("🤖 OpenAISummarizationEngine: Starting title extraction")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI service not properly configured")
        }
        
        do {
            return try await service.extractTitles(from: text)
        } catch {
            print("❌ OpenAISummarizationEngine: Title extraction failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        print("🤖 OpenAISummarizationEngine: Starting content classification")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI service not properly configured")
        }
        
        do {
            return try await service.classifyContent(text)
        } catch {
            print("❌ OpenAISummarizationEngine: Content classification failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        print("🤖 OpenAISummarizationEngine: Starting complete processing")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "OpenAI service not properly configured")
        }
        
        // Check if text needs chunking based on token count
        let tokenCount = TokenManager.getTokenCount(text)
        print("📊 Text token count: \(tokenCount)")
        
        do {
            // Use GPT-4.1 context window for chunking decision
            if TokenManager.needsChunking(text, maxTokens: TokenManager.gpt41ContextWindow) {
                print("🔀 Large transcript detected (\(tokenCount) tokens), using chunked processing")
                return try await processChunkedText(text, service: service)
            } else {
                print("📝 Processing single chunk (\(tokenCount) tokens)")
                return try await service.processComplete(text: text)
            }
        } catch {
            print("❌ OpenAISummarizationEngine: Complete processing failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    // MARK: - Configuration Management
    
    private func updateConfiguration() {
        let apiKey = UserDefaults.standard.string(forKey: "openAIAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? OpenAISummarizationModel.gpt41Mini.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "openAISummarizationBaseURL") ?? "https://api.openai.com/v1"
        let temperature = UserDefaults.standard.double(forKey: "openAISummarizationTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "openAISummarizationMaxTokens")
        
        // Check if the model is a predefined one or a dynamic model
        let model: OpenAISummarizationModel
        if let predefinedModel = OpenAISummarizationModel(rawValue: modelString) {
            model = predefinedModel
        } else {
            // Use a default model for dynamic models, but pass the actual model string to the service
            model = .gpt41Mini
        }
        
        let newConfig = OpenAISummarizationConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : 2048,
            timeout: 30.0,
            dynamicModelId: modelString // Pass the actual model ID for dynamic models
        )
        
        // Only create a new service if the configuration has actually changed
        if currentConfig == nil || currentConfig != newConfig {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Updating configuration - Model: \(modelString), BaseURL: \(baseURL)", category: "OpenAISummarizationEngine")
            }
            
            self.currentConfig = newConfig
            self.service = OpenAISummarizationService(config: newConfig)
            
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Configuration updated successfully", category: "OpenAISummarizationEngine")
            }
        }
    }
    
    // MARK: - Chunked Processing
    
    private func processChunkedText(_ text: String, service: OpenAISummarizationService) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()

        // Initialize Ollama service for meta-summary generation
        let ollamaService = OllamaService()
        _ = await ollamaService.testConnection()
        
        // Split text into chunks
        let chunks = TokenManager.chunkText(text)
        print("📦 Split text into \(chunks.count) chunks")
        
        // Process each chunk
        var allSummaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentType: ContentType = .general
        
        for (index, chunk) in chunks.enumerated() {
            print("🔄 Processing chunk \(index + 1) of \(chunks.count) (\(TokenManager.getTokenCount(chunk)) tokens)")
            
            do {
                let chunkResult = try await service.processComplete(text: chunk)
                allSummaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)
                
                // Use the first chunk's content type
                if index == 0 {
                    contentType = chunkResult.contentType
                }
                
            } catch {
                print("❌ Failed to process chunk \(index + 1): \(error)")
                throw error
            }
        }
        
        // Combine results using AI-generated meta-summary
        let combinedSummary = try await TokenManager.combineSummaries(
            allSummaries,
            contentType: contentType,
            service: ollamaService
        )
        
        // Deduplicate tasks, reminders, and titles
        let uniqueTasks = deduplicateTasks(allTasks)
        let uniqueReminders = deduplicateReminders(allReminders)
        let uniqueTitles = deduplicateTitles(allTitles)
        
        let processingTime = Date().timeIntervalSince(startTime)
        print("✅ Chunked processing completed in \(String(format: "%.2f", processingTime))s")
        print("📊 Final summary: \(combinedSummary.count) characters")
        print("📋 Final tasks: \(uniqueTasks.count)")
        print("🔔 Final reminders: \(uniqueReminders.count)")
        print("📝 Final titles: \(uniqueTitles.count)")
        
        return (combinedSummary, uniqueTasks, uniqueReminders, uniqueTitles, contentType)
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
        
        return Array(uniqueTasks.prefix(15)) // Limit to 15 tasks
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
        
        return Array(uniqueReminders.prefix(15)) // Limit to 15 reminders
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
        
        return Array(uniqueTitles.prefix(5)) // Limit to 5 titles
    }
    
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async -> Bool {
        print("🔧 OpenAISummarizationEngine: Testing connection...")
        
        updateConfiguration()
        
        guard let service = service else {
            print("❌ OpenAISummarizationEngine: Service is nil - configuration issue")
            return false
        }
        
        let connectionResult = await service.testConnection()
        if connectionResult {
            print("✅ OpenAISummarizationEngine: Connection test successful")
            return true
        } else {
            print("❌ OpenAISummarizationEngine: Connection test failed")
            return false
        }
    }
    
    // MARK: - Enhanced Error Handling
    
    private func handleAPIError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        }
        
        // Handle specific OpenAI API errors
        let errorString = error.localizedDescription.lowercased()
        
        if errorString.contains("quota") || errorString.contains("billing") {
            return SummarizationError.aiServiceUnavailable(service: "OpenAI API quota exceeded. Please check your billing status.")
        } else if errorString.contains("rate limit") || errorString.contains("too many requests") {
            return SummarizationError.aiServiceUnavailable(service: "OpenAI API rate limit exceeded. Please try again later.")
        } else if errorString.contains("invalid api key") || errorString.contains("authentication") {
            return SummarizationError.aiServiceUnavailable(service: "Invalid OpenAI API key. Please check your configuration.")
        } else if errorString.contains("timeout") || errorString.contains("network") {
            return SummarizationError.processingTimeout
        } else {
            return SummarizationError.aiServiceUnavailable(service: "OpenAI API error: \(error.localizedDescription)")
        }
    }
}

// MARK: - OpenAI Compatible Engine

class OpenAICompatibleEngine: SummarizationEngine, ConnectionTestable {
    let name: String = "OpenAI API Compatible"
    let description: String = "Advanced AI summaries using OpenAI API compatible models"
    let version: String = "1.0"
    
    private var service: OpenAISummarizationService?
    private var currentConfig: OpenAISummarizationConfig?
    
    var isAvailable: Bool {
        // Check if API key is configured
        let apiKey = UserDefaults.standard.string(forKey: "openAICompatibleAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("API key not configured", category: "OpenAICompatibleEngine")
            }
            return false
        }
        
        // Check if OpenAI Compatible is enabled in settings
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOpenAICompatible")
        let keyExists = UserDefaults.standard.object(forKey: "enableOpenAICompatible") != nil
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Checking enableOpenAICompatible setting - Value: \(isEnabled), Key exists: \(keyExists)", category: "OpenAICompatibleEngine")
        }
        
        guard isEnabled else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("OpenAI Compatible is not enabled in settings", category: "OpenAICompatibleEngine")
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
            print("❌ OpenAICompatibleEngine: Failed to generate summary: \(error)")
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
            print("❌ OpenAICompatibleEngine: Failed to extract tasks: \(error)")
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
            print("❌ OpenAICompatibleEngine: Failed to extract reminders: \(error)")
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
            print("❌ OpenAICompatibleEngine: Failed to extract titles: \(error)")
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
            print("❌ OpenAICompatibleEngine: Failed to classify content: \(error)")
            return .general
        }
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        do {
            return try await service.processComplete(text: text)
        } catch {
            print("❌ OpenAICompatibleEngine: Failed to process complete: \(error)")
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
            print("✅ OpenAICompatibleEngine: Connection test successful")
            return true
        } else {
            print("❌ OpenAICompatibleEngine: Connection test failed")
            return false
        }
    }
    
    // MARK: - Configuration Management
    
    private func updateConfiguration() {
        let apiKey = UserDefaults.standard.string(forKey: "openAICompatibleAPIKey") ?? ""
        let modelId = UserDefaults.standard.string(forKey: "openAICompatibleModel") ?? "gpt-3.5-turbo"
        let baseURL = UserDefaults.standard.string(forKey: "openAICompatibleBaseURL") ?? "https://api.openai.com/v1"
        let temperature = UserDefaults.standard.double(forKey: "openAICompatibleTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "openAICompatibleMaxTokens")
        
        let model = OpenAISummarizationModel(rawValue: modelId) ?? .gpt41Mini
        let newConfig = OpenAISummarizationConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : 2048,
            timeout: 30.0,
            dynamicModelId: modelId // Pass the actual model ID for dynamic models
        )
        
        // Only create a new service if the configuration has actually changed
        if currentConfig == nil || currentConfig != newConfig {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Updating configuration - Model: \(modelId), BaseURL: \(baseURL)", category: "OpenAICompatibleEngine")
            }
            
            self.currentConfig = newConfig
            self.service = OpenAISummarizationService(config: newConfig)
            
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