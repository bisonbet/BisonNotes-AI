//
//  FutureAIEngines.swift
//  Audio Journal
//
//  Placeholder implementations for future AI services with proper availability checking
//

import Foundation
import os.log
import SwiftUI

// MARK: - AWS Bedrock Engine

class AWSBedrockEngine: SummarizationEngine, ConnectionTestable {
    let name: String = "AWS Bedrock"
    let description: String = "Advanced AI-powered summaries using AWS Bedrock with Claude and other foundation models"
    let version: String = "1.0"
    
    private var service: AWSBedrockService?
    private var currentConfig: AWSBedrockConfig?
    
    var isAvailable: Bool {
        // Check if AWS Bedrock is enabled in settings
        let isEnabled = UserDefaults.standard.bool(forKey: "enableAWSBedrock")
        let keyExists = UserDefaults.standard.object(forKey: "enableAWSBedrock") != nil
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Checking enableAWSBedrock setting - Value: \(isEnabled), Key exists: \(keyExists)", category: "AWSBedrockEngine")
        }
        
        guard isEnabled else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("AWS Bedrock is not enabled in settings", category: "AWSBedrockEngine")
            }
            return false
        }
        
        // Check credentials using unified credentials manager
        let useProfile = UserDefaults.standard.bool(forKey: "awsBedrockUseProfile")
        let profileName = UserDefaults.standard.string(forKey: "awsBedrockProfileName") ?? ""
        
        // Check credentials based on authentication method
        if useProfile {
            guard !profileName.isEmpty else {
                if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                    AppLogger.shared.verbose("AWS profile name not configured", category: "AWSBedrockEngine")
                }
                return false
            }
        } else {
            // Use unified credentials manager instead of separate UserDefaults keys
            let credentials = AWSCredentialsManager.shared.credentials
            guard credentials.isValid else {
                if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                    AppLogger.shared.verbose("AWS credentials not configured in unified manager", category: "AWSBedrockEngine")
                }
                return false
            }
        }
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Basic availability checks passed", category: "AWSBedrockEngine")
        }
        return true
    }
    
    init() {
        updateConfiguration()
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        print("🤖 AWSBedrockEngine: Starting summary generation")
        
        updateConfiguration()
        
        guard let service = service else {
            print("❌ AWSBedrockEngine: Service is nil")
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock service not properly configured")
        }
        
        print("✅ AWSBedrockEngine: Calling AWS Bedrock service for summary")
        
        do {
            return try await service.generateSummary(from: text, contentType: contentType)
        } catch {
            print("❌ AWSBedrockEngine: Summary generation failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        print("🤖 AWSBedrockEngine: Starting task extraction")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock service not properly configured")
        }
        
        do {
            return try await service.extractTasks(from: text)
        } catch {
            print("❌ AWSBedrockEngine: Task extraction failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        print("🤖 AWSBedrockEngine: Starting reminder extraction")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock service not properly configured")
        }
        
        do {
            return try await service.extractReminders(from: text)
        } catch {
            print("❌ AWSBedrockEngine: Reminder extraction failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        print("🤖 AWSBedrockEngine: Starting title extraction")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock service not properly configured")
        }
        
        do {
            return try await service.extractTitles(from: text)
        } catch {
            print("❌ AWSBedrockEngine: Title extraction failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        print("🤖 AWSBedrockEngine: Starting content classification")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock service not properly configured")
        }
        
        do {
            return try await service.classifyContent(text)
        } catch {
            print("❌ AWSBedrockEngine: Content classification failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        print("🤖 AWSBedrockEngine: Starting complete processing")
        
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock service not properly configured")
        }
        
        // Check if text needs chunking based on token count
        let tokenCount = TokenManager.getTokenCount(text)
        print("📊 Text token count: \(tokenCount)")
        
        do {
            // Use the model's context window for chunking decision
            let contextWindow = currentConfig?.model.contextWindow ?? TokenManager.maxTokensPerChunk
            if TokenManager.needsChunking(text, maxTokens: contextWindow) {
                print("🔀 Large transcript detected (\(tokenCount) tokens), using chunked processing")
                return try await processChunkedText(text, service: service)
            } else {
                print("📝 Processing single chunk (\(tokenCount) tokens)")
                return try await service.processComplete(text: text)
            }
        } catch {
            print("❌ AWSBedrockEngine: Complete processing failed: \(error)")
            throw handleAPIError(error)
        }
    }
    
    // MARK: - Configuration Management
    
    private func updateConfiguration() {
        // Use unified credentials manager instead of separate UserDefaults keys
        let credentials = AWSCredentialsManager.shared.credentials
        let sessionToken = UserDefaults.standard.string(forKey: "awsBedrockSessionToken")
        let modelString = UserDefaults.standard.string(forKey: "awsBedrockModel") ?? AWSBedrockModel.claude45Haiku.rawValue
        let temperature = UserDefaults.standard.double(forKey: "awsBedrockTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "awsBedrockMaxTokens")
        let useProfile = UserDefaults.standard.bool(forKey: "awsBedrockUseProfile")
        let profileName = UserDefaults.standard.string(forKey: "awsBedrockProfileName")
        
        let model = AWSBedrockModel(rawValue: modelString) ?? .claude45Haiku
        
        let newConfig = AWSBedrockConfig(
            region: credentials.region,
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: sessionToken,
            model: model,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : 4096,
            timeout: 60.0,
            useProfile: useProfile,
            profileName: profileName
        )
        
        // Only create a new service if the configuration has actually changed
        if currentConfig == nil || currentConfig != newConfig {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Updating configuration - Model: \(modelString), Region: \(credentials.region)", category: "AWSBedrockEngine")
            }
            
            self.currentConfig = newConfig
            self.service = AWSBedrockService(config: newConfig)
            
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Configuration updated successfully", category: "AWSBedrockEngine")
            }
        }
    }
    
    // MARK: - Chunked Processing
    
    private func processChunkedText(_ text: String, service: AWSBedrockService) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()
        
        // Initialize Ollama service for meta-summary generation
        let ollamaService = OllamaService()
        _ = await ollamaService.testConnection()
        
        // Split text into chunks
        let contextWindow = currentConfig?.model.contextWindow ?? TokenManager.maxTokensPerChunk
        let chunks = TokenManager.chunkText(text, maxTokens: contextWindow)
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
                
                // Add delay between chunks to avoid rate limiting
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second between chunks
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
        print("🔧 AWSBedrockEngine: Testing connection...")
        
        updateConfiguration()
        
        guard let service = service else {
            print("❌ AWSBedrockEngine: Service is nil - configuration issue")
            return false
        }
        
        let connectionResult = await service.testConnection()
        if connectionResult {
            print("✅ AWSBedrockEngine: Connection test successful")
            return true
        } else {
            print("❌ AWSBedrockEngine: Connection test failed")
            return false
        }
    }
    
    func loadAvailableModels() async throws -> [AWSBedrockModel] {
        updateConfiguration()
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        return try await service.listAvailableModels()
    }
    
    // MARK: - Enhanced Error Handling
    
    private func handleAPIError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        }
        
        // Handle specific AWS Bedrock errors
        let errorString = error.localizedDescription.lowercased()
        
        if errorString.contains("access denied") || errorString.contains("unauthorized") {
            return SummarizationError.aiServiceUnavailable(service: "AWS Bedrock access denied. Please check your credentials and permissions.")
        } else if errorString.contains("throttling") || errorString.contains("rate limit") {
            return SummarizationError.aiServiceUnavailable(service: "AWS Bedrock rate limit exceeded. Please try again later.")
        } else if errorString.contains("model not found") || errorString.contains("validation") {
            return SummarizationError.aiServiceUnavailable(service: "AWS Bedrock model not available. Please check your model configuration.")
        } else if errorString.contains("timeout") || errorString.contains("network") {
            return SummarizationError.processingTimeout
        } else {
            return SummarizationError.aiServiceUnavailable(service: "AWS Bedrock error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Whisper-Based Engine (Future Implementation)

// OpenAICompatibleEngine has been moved to OpenAISummarizationEngine.swift
// This placeholder is for future Whisper-based implementations

// MARK: - Supporting Structures for Future Implementation

struct DiarizedTranscript {
    let segments: [DiarizedSegment]
    let speakers: [Speaker]
    let confidence: Double
    let processingTime: TimeInterval
}

struct DiarizedSegment {
    let id: UUID
    let speakerId: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let confidence: Double
}

struct Speaker {
    let id: String
    let name: String?
    let voiceCharacteristics: VoiceCharacteristics
    let segmentCount: Int
    let totalDuration: TimeInterval
}

struct VoiceCharacteristics {
    let pitch: Double
    let tone: String
    let pace: Double
    let volume: Double
}

// MARK: - Local LLM Engine (Future Implementation)

class LocalLLMEngine: SummarizationEngine, ConnectionTestable {
    let name: String = "Local LLM (Ollama)"
    let description: String = "Privacy-focused local language model processing using Ollama"
    let version: String = "1.0"
    
    var isAvailable: Bool {
        // Check if Ollama is enabled in settings
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOllama")
        let keyExists = UserDefaults.standard.object(forKey: "enableOllama") != nil
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Checking enableOllama setting - Value: \(isEnabled), Key exists: \(keyExists)", category: "LocalLLMEngine")
        }
        
        guard isEnabled else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("Ollama is not enabled in settings", category: "LocalLLMEngine")
            }
            return false
        }
        
        // Check if server URL is configured (use defaults if not set)
        let _ = UserDefaults.standard.string(forKey: "ollamaServerURL") ?? "http://localhost"
        let _ = UserDefaults.standard.string(forKey: "ollamaModelName") ?? "llama2:7b"
        
        // For Ollama to be considered available, we need to have both URL and model
        // But we should also check if this is actually a real Ollama server
        // Since we can't easily test connection here, we'll be more conservative
        
        // Only consider available if explicitly configured (not using defaults)
        let hasExplicitURL = UserDefaults.standard.object(forKey: "ollamaServerURL") != nil
        let hasExplicitModel = UserDefaults.standard.object(forKey: "ollamaModelName") != nil
        
        guard hasExplicitURL && hasExplicitModel else {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                AppLogger.shared.verbose("Ollama not explicitly configured (using defaults)", category: "LocalLLMEngine")
            }
            return false
        }
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLogger.shared.verbose("Basic availability checks passed", category: "LocalLLMEngine")
        }
        return true
    }
    
    private var ollamaService: OllamaService?
    private var config: OllamaConfig?
    
    init() {
        // Initialize with saved configuration
        let serverURL = UserDefaults.standard.string(forKey: "ollamaServerURL") ?? "http://localhost"
        let port = UserDefaults.standard.integer(forKey: "ollamaPort")
        let modelName = UserDefaults.standard.string(forKey: "ollamaModelName") ?? "llama2:7b"
        let maxTokens = UserDefaults.standard.integer(forKey: "ollamaMaxTokens")
        let temperature = UserDefaults.standard.double(forKey: "ollamaTemperature")
        let contextTokens = UserDefaults.standard.integer(forKey: "ollamaContextTokens")

        let config = OllamaConfig(
            serverURL: serverURL,
            port: port > 0 ? port : 11434,
            modelName: modelName,
            maxTokens: maxTokens > 0 ? maxTokens : 2048,
            temperature: temperature > 0 ? temperature : 0.1,
            maxContextTokens: contextTokens > 0 ? contextTokens : 4096
        )

        self.config = config
        self.ollamaService = OllamaService(config: config)
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        print("🤖 LocalLLMEngine: Starting summary generation")
        
        // Update configuration with latest settings
        updateConfiguration()
        
        // Validate model availability before proceeding
        try await validateAndUpdateModel()
        
        guard let service = ollamaService else {
            print("❌ LocalLLMEngine: Ollama service is nil")
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not properly configured")
        }
        
        // Check if Ollama is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOllama")
        print("🔧 LocalLLMEngine: Ollama enabled: \(isEnabled)")
        
        guard isEnabled else {
            print("❌ LocalLLMEngine: Ollama is not enabled in settings")
            throw SummarizationError.aiServiceUnavailable(service: "Ollama is not enabled in settings")
        }
        
        // Test connection before attempting to generate summary
        print("🔧 LocalLLMEngine: Testing connection to Ollama server...")
        let isConnected = await service.testConnection()
        print("🔧 LocalLLMEngine: Connection test result: \(isConnected)")
        
        guard isConnected else {
            print("❌ LocalLLMEngine: Cannot connect to Ollama server")
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server. Please check your server URL and port settings.")
        }
        
        print("✅ LocalLLMEngine: Calling Ollama service for summary")
        
        do {
            return try await service.generateSummary(from: text)
        } catch {
            print("❌ LocalLLMEngine: Summary generation failed: \(error)")
            throw handleOllamaError(error)
        }
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        print("🤖 LocalLLMEngine: Starting task extraction")
        
        // Update configuration with latest settings
        updateConfiguration()
        
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not properly configured")
        }
        
        // Check if Ollama is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOllama")
        guard isEnabled else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama is not enabled in settings")
        }
        
        // Test connection before attempting to extract tasks
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server. Please check your server URL and port settings.")
        }
        
        do {
            let result = try await service.extractTasksAndReminders(from: text)
            return result.tasks
        } catch {
            print("❌ LocalLLMEngine: Task extraction failed: \(error)")
            throw handleOllamaError(error)
        }
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        print("🤖 LocalLLMEngine: Starting reminder extraction")
        
        // Update configuration with latest settings
        updateConfiguration()
        
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not properly configured")
        }
        
        // Check if Ollama is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOllama")
        guard isEnabled else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama is not enabled in settings")
        }
        
        // Test connection before attempting to extract reminders
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server. Please check your server URL and port settings.")
        }
        
        do {
            let result = try await service.extractTasksAndReminders(from: text)
            return result.reminders
        } catch {
            print("❌ LocalLLMEngine: Reminder extraction failed: \(error)")
            throw handleOllamaError(error)
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        print("🤖 LocalLLMEngine: Starting title extraction")
        
        // Update configuration with latest settings
        updateConfiguration()
        
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not properly configured")
        }
        
        // Check if Ollama is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOllama")
        guard isEnabled else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama is not enabled in settings")
        }
        
        // Test connection before attempting to extract titles
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server. Please check your server URL and port settings.")
        }
        
        do {
            return try await service.extractTitles(from: text)
        } catch {
            print("❌ LocalLLMEngine: Title extraction failed: \(error)")
            throw handleOllamaError(error)
        }
    }
    

    
    // MARK: - Enhanced Error Handling
    
    private func handleOllamaError(_ error: Error) -> SummarizationError {
        if let summarizationError = error as? SummarizationError {
            return summarizationError
        }
        
        // Handle specific Ollama errors
        if let ollamaError = error as? OllamaError {
            switch ollamaError {
            case .notConnected:
                return SummarizationError.aiServiceUnavailable(service: "Ollama server is not connected. Please check your server URL and port settings.")
            case .serverError(let message):
                return SummarizationError.aiServiceUnavailable(service: "Ollama server error: \(message)")
            case .parsingError(let message):
                return SummarizationError.aiServiceUnavailable(service: "Ollama parsing error: \(message)")
            case .modelNotFound(let model):
                return SummarizationError.aiServiceUnavailable(service: "Ollama model '\(model)' not found on server. Please check your model configuration.")
            }
        }
        
        // Handle network errors
        let errorString = error.localizedDescription.lowercased()
        if errorString.contains("timeout") || errorString.contains("network") {
            return SummarizationError.processingTimeout
        } else {
            return SummarizationError.aiServiceUnavailable(service: "Ollama error: \(error.localizedDescription)")
        }
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        print("🔍 LocalLLMEngine: Starting content classification")
        
        // Use enhanced ContentAnalyzer for classification
        let contentType = ContentAnalyzer.classifyContent(text)
        print("✅ LocalLLMEngine: Content classified as \(contentType.rawValue)")
        
        return contentType
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Update configuration with latest settings
        updateConfiguration()
        
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        // Check if Ollama is enabled
        let isEnabled = UserDefaults.standard.bool(forKey: "enableOllama")
        guard isEnabled else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama is not enabled in settings")
        }
        
        // Test connection before attempting to process
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server. Please check your server URL and port settings.")
        }
        
        // Check if text needs chunking based on token count
        let tokenCount = TokenManager.getTokenCount(text)
        print("📊 Text token count: \(tokenCount)")
        
        let maxContext = config?.maxContextTokens ?? TokenManager.maxTokensPerChunk
        if TokenManager.needsChunking(text, maxTokens: maxContext) {
            print("🔀 Large transcript detected (\(tokenCount) tokens), using chunked processing")
            return try await processChunkedText(text, service: service, maxTokens: maxContext)
        } else {
            print("📝 Processing single chunk (\(tokenCount) tokens)")
            do {
                return try await processSingleChunk(text, service: service)
            } catch {
                // If the server reports a context window issue, retry with chunked processing
                let errorMessage = error.localizedDescription.lowercased()
                if errorMessage.contains("context") || errorMessage.contains("token") {
                    print("🔁 Context window exceeded, retrying with chunked processing")
                    do {
                        let result = try await processChunkedText(text, service: service, maxTokens: maxContext)
                        print("✅ Chunked retry succeeded")
                        return result
                    } catch {
                        print("❌ Chunked retry failed: \(error)")
                        throw error
                    }
                }
                throw error
            }
        }
    }
    
    private func processSingleChunk(_ text: String, service: OllamaService) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        print("🔄 LocalLLMEngine: Processing single chunk with Ollama using complete processing")
        
        do {
            // Use the new single-call method for complete processing
            let result = try await service.processComplete(from: text)
            print("✅ LocalLLMEngine: Complete processing successful")
            print("📊 LocalLLMEngine: Summary: \(result.summary.count) chars, Tasks: \(result.tasks.count), Reminders: \(result.reminders.count), Titles: \(result.titles.count)")
            
            return result
            
        } catch {
            print("⚠️ LocalLLMEngine: Complete processing failed, falling back to individual calls: \(error)")
            
            // Fallback to individual calls if the complete processing fails
            return try await processSingleChunkFallback(text, service: service)
        }
    }
    
    private func processSingleChunkFallback(_ text: String, service: OllamaService) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        print("🔄 LocalLLMEngine: Using fallback individual processing")
        
        // Process requests sequentially to avoid overwhelming the Ollama server
        let summary = try await service.generateSummary(from: text)
        print("✅ LocalLLMEngine: Summary generated successfully")
        
        // Small delay between requests to prevent overwhelming the server
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Try to extract tasks and reminders, but don't fail if it doesn't work
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []
        
        do {
            let extraction = try await service.extractTasksAndReminders(from: text)
            tasks = extraction.tasks
            reminders = extraction.reminders
            print("✅ LocalLLMEngine: Tasks and reminders extracted successfully")
        } catch {
            print("⚠️ LocalLLMEngine: Failed to extract tasks/reminders, continuing with empty arrays: \(error)")
            // Continue with empty arrays instead of failing
        }
        
        // Small delay between requests to prevent overwhelming the server
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Try to extract titles, but don't fail if it doesn't work
        var titles: [TitleItem] = []
        
        do {
            titles = try await service.extractTitles(from: text)
            print("✅ LocalLLMEngine: Titles extracted successfully")
        } catch {
            print("⚠️ LocalLLMEngine: Failed to extract titles, continuing with empty array: \(error)")
            // Continue with empty array instead of failing
        }
        
        let contentType = try await classifyContent(text)
        
        print("✅ LocalLLMEngine: Fallback processing completed")
        print("📊 LocalLLMEngine: Summary: \(summary.count) chars, Tasks: \(tasks.count), Reminders: \(reminders.count), Titles: \(titles.count)")
        
        return (summary, tasks, reminders, titles, contentType)
    }
    
    private func processChunkedText(_ text: String, service: OllamaService, maxTokens: Int) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()

        // Split text into chunks
        let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
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
                let chunkResult = try await processSingleChunk(chunk, service: service)
                allSummaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)
                
                // Use the first chunk's content type
                if index == 0 {
                    contentType = chunkResult.contentType
                }
                
                // Add delay between chunks to prevent overwhelming the server
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second between chunks
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
            service: service
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
    
    // MARK: - Configuration Management
    
    func updateConfiguration() {
        let serverURL = UserDefaults.standard.string(forKey: "ollamaServerURL") ?? "http://localhost"
        let port = UserDefaults.standard.integer(forKey: "ollamaPort")
        let modelName = UserDefaults.standard.string(forKey: "ollamaModelName") ?? "llama2:7b"
        let maxTokens = UserDefaults.standard.integer(forKey: "ollamaMaxTokens")
        let temperature = UserDefaults.standard.double(forKey: "ollamaTemperature")
        let contextTokens = UserDefaults.standard.integer(forKey: "ollamaContextTokens")
        
        print("🔧 LocalLLMEngine: Updating configuration - Server: \(serverURL), Port: \(port), Model: \(modelName)")
        
        let config = OllamaConfig(
            serverURL: serverURL,
            port: port > 0 ? port : 11434,
            modelName: modelName,
            maxTokens: maxTokens > 0 ? maxTokens : 2048,
            temperature: temperature > 0 ? temperature : 0.1,
            maxContextTokens: contextTokens > 0 ? contextTokens : 4096
        )

        self.config = config
        self.ollamaService = OllamaService(config: config)
        print("✅ LocalLLMEngine: Configuration updated successfully")
    }
    
    private func validateAndUpdateModel() async throws {
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not configured")
        }
        
        // Test connection first
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server at \(config?.baseURL ?? "unknown")")
        }
        
        // Check if the configured model is available
        let isModelAvailable = await service.isModelAvailable(config?.modelName ?? "")
        
        if !isModelAvailable {
            print("⚠️ LocalLLMEngine: Configured model '\(config?.modelName ?? "unknown")' is not available")
            
            // Try to get the first available model
            if let firstAvailableModel = await service.getFirstAvailableModel() {
                print("🔄 LocalLLMEngine: Switching to available model '\(firstAvailableModel)'")
                
                // Update the configuration with the available model
                let newConfig = OllamaConfig(
                    serverURL: config?.serverURL ?? "",
                    port: config?.port ?? 11434,
                    modelName: firstAvailableModel,
                    maxTokens: config?.maxTokens ?? 2048,
                    temperature: config?.temperature ?? 0.1,
                    maxContextTokens: config?.maxContextTokens ?? 4096
                )
                
                self.config = newConfig
                self.ollamaService = OllamaService(config: newConfig)
                
                // Optionally update UserDefaults with the working model
                UserDefaults.standard.set(firstAvailableModel, forKey: "ollamaModelName")
                print("💾 LocalLLMEngine: Updated saved model preference to '\(firstAvailableModel)'")
                
            } else {
                throw SummarizationError.aiServiceUnavailable(service: "No models available on Ollama server. Please install a model using 'ollama pull <model_name>'")
            }
        } else {
            print("✅ LocalLLMEngine: Model '\(config?.modelName ?? "unknown")' is available")
        }
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async -> Bool {
        print("🔧 LocalLLMEngine: Testing connection...")
        
        updateConfiguration()
        
        guard let service = ollamaService else {
            print("❌ LocalLLMEngine: Service is nil - configuration issue")
            return false
        }
        
        let isConnected = await service.testConnection()
        if isConnected {
            print("✅ LocalLLMEngine: Connection test successful")
        } else {
            print("❌ LocalLLMEngine: Connection test failed")
        }
        return isConnected
    }
    
    func loadAvailableModels() async throws -> [String] {
        updateConfiguration()
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        let models = try await service.loadAvailableModels()
        return models.map { $0.name }
    }
    
    // MARK: - Debug Methods
    
    func testCompleteProcessing() async throws -> String {
        print("🧪 LocalLLMEngine: Testing complete processing with simple prompt")
        
        updateConfiguration()
        
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not configured")
        }
        
        // Test connection first
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server")
        }
        
        // Simple test to see what Ollama returns
        let testText = "I need to call John tomorrow and buy groceries. Don't forget the meeting at 3pm. We discussed the quarterly budget and decided to increase marketing spend."
        
        do {
            let result = try await service.processComplete(from: testText)
            let summary = "Successfully processed: Summary (\(result.summary.count) chars), \(result.tasks.count) tasks, \(result.reminders.count) reminders, \(result.titles.count) titles, content type: \(result.contentType.rawValue)"
            print("✅ LocalLLMEngine: Complete processing test successful - \(summary)")
            return summary
        } catch {
            let errorMessage = "Complete processing test failed: \(error.localizedDescription)"
            print("❌ LocalLLMEngine: \(errorMessage)")
            throw SummarizationError.aiServiceUnavailable(service: errorMessage)
        }
    }
    
    func testJSONParsing() async throws -> String {
        print("🧪 LocalLLMEngine: Testing JSON parsing with simple prompt")
        
        updateConfiguration()
        
        guard let service = ollamaService else {
            throw SummarizationError.aiServiceUnavailable(service: "Ollama service not configured")
        }
        
        // Test connection first
        let isConnected = await service.testConnection()
        guard isConnected else {
            throw SummarizationError.aiServiceUnavailable(service: "Cannot connect to Ollama server")
        }
        
        // Simple test to see what Ollama returns
        let testText = "I need to call John tomorrow and buy groceries. Don't forget the meeting at 3pm."
        
        do {
            let result = try await service.extractTasksAndReminders(from: testText)
            let summary = "Successfully parsed \(result.tasks.count) tasks and \(result.reminders.count) reminders"
            print("✅ LocalLLMEngine: JSON parsing test successful - \(summary)")
            return summary
        } catch {
            let errorMessage = "JSON parsing test failed: \(error.localizedDescription)"
            print("❌ LocalLLMEngine: \(errorMessage)")
            throw SummarizationError.aiServiceUnavailable(service: errorMessage)
        }
    }
    

}

// MARK: - Google AI Studio Engine

// Local SummaryResponse struct for JSON parsing
private struct SummaryResponse: Codable {
    let summary: String
    let tasks: [String]
    let reminders: [String]
    let titles: [String]
    let contentType: String
}

class GoogleAIStudioEngine: SummarizationEngine {
    let name = "Google AI Studio"
    let description = "Advanced AI-powered summaries using Google's Gemini models"
    let isAvailable: Bool
    let version = "1.0"
    
    private let service = GoogleAIStudioService()
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "GoogleAIStudioEngine")
    
    init() {
        // Check if Google AI Studio is enabled and configured
        let apiKey = UserDefaults.standard.string(forKey: "googleAIStudioAPIKey") ?? ""
        let isEnabled = UserDefaults.standard.bool(forKey: "enableGoogleAIStudio")
        self.isAvailable = !apiKey.isEmpty && isEnabled
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        guard isAvailable else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        let prompt = createSummaryPrompt(text: text, contentType: contentType)
        return try await service.generateContent(prompt: prompt, useStructuredOutput: false)
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        guard isAvailable else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        let prompt = createTaskExtractionPrompt(text: text)
        let response = try await service.generateContent(prompt: prompt, useStructuredOutput: false)
        return parseTasksFromResponse(response)
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        guard isAvailable else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        let prompt = createReminderExtractionPrompt(text: text)
        let response = try await service.generateContent(prompt: prompt, useStructuredOutput: false)
        return parseRemindersFromResponse(response)
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        guard isAvailable else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        let prompt = createTitleExtractionPrompt(text: text)
        let response = try await service.generateContent(prompt: prompt, useStructuredOutput: false)
        return parseTitlesFromResponse(response)
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        guard isAvailable else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        let prompt = createContentClassificationPrompt(text: text)
        let response = try await service.generateContent(prompt: prompt, useStructuredOutput: false)
        return parseContentTypeFromResponse(response)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        guard isAvailable else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        // Check if text needs chunking based on token count
        let tokenCount = TokenManager.getTokenCount(text)
        print("📊 GoogleAI: Text token count: \(tokenCount)")
        
        do {
            // Use Google AI Studio's context window for chunking decision
            if TokenManager.needsChunking(text, maxTokens: TokenManager.googleAIStudioContextWindow) {
                print("🔀 Large transcript detected (\(tokenCount) tokens), using chunked processing")
                return try await processChunkedText(text)
            } else {
                print("📝 Processing single chunk (\(tokenCount) tokens)")
                return try await processSingleChunk(text)
            }
        } catch {
            // If the server reports a context window issue, retry with chunked processing
            let errorMessage = error.localizedDescription.lowercased()
            if errorMessage.contains("context") || errorMessage.contains("token") {
                print("⚠️ Context limit reached, falling back to chunked processing")
                return try await processChunkedText(text)
            }
            throw error
        }
    }
    
    private func processSingleChunk(_ text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Create a comprehensive prompt for complete processing
        let prompt = createCompleteProcessingPrompt(text: text)
        
        // Use structured output for complete processing
        let response = try await service.generateContent(prompt: prompt, useStructuredOutput: true)
        
        // Parse the structured response
        let components = parseStructuredResponse(response)
        
        return (
            summary: components.summary,
            tasks: components.tasks,
            reminders: components.reminders,
            titles: components.titles,
            contentType: components.contentType
        )
    }
    
    // MARK: - Chunked Processing
    
    private func processChunkedText(_ text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()
        
        print("🔄 GoogleAI: Starting chunked processing...")
        
        // Use Google AI Studio's context window for chunking
        let chunks = TokenManager.chunkText(text, maxTokens: TokenManager.googleAIStudioContextWindow)
        print("📊 GoogleAI: Split into \(chunks.count) chunks")
        
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var summaries: [String] = []
        
        // Process each chunk
        for (index, chunk) in chunks.enumerated() {
            print("🔄 GoogleAI: Processing chunk \(index + 1) of \(chunks.count) (\(TokenManager.getTokenCount(chunk)) tokens)")
            
            do {
                let chunkResult = try await processSingleChunk(chunk)
                
                summaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)
                
                // Add delay between chunks to respect rate limits
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                }
            } catch {
                print("❌ GoogleAI: Error processing chunk \(index + 1): \(error)")
                // Continue with other chunks instead of failing completely
            }
        }
        
        // Combine all summaries into a final meta-summary
        let combinedSummary = summaries.joined(separator: "\n\n")
        let finalSummary: String
        
        if TokenManager.needsChunking(combinedSummary, maxTokens: TokenManager.googleAIStudioContextWindow) {
            // If combined summary is still too long, use the first summary as base
            finalSummary = summaries.first ?? "Summary not available"
        } else {
            // Generate a meta-summary from all chunk summaries
            let metaPrompt = """
            Please create a comprehensive summary by combining these section summaries:
            
            \(combinedSummary)
            
            Create a cohesive, well-structured summary using proper Markdown formatting.
            """
            
            do {
                finalSummary = try await service.generateContent(prompt: metaPrompt, useStructuredOutput: false)
            } catch {
                // Fallback to combined summary if meta-summary fails
                finalSummary = combinedSummary
            }
        }
        
        // Deduplicate and limit results
        let deduplicatedTasks = Array(Set(allTasks.map { $0.text })).prefix(15).map { TaskItem(text: $0, priority: .medium, confidence: 0.8) }
        let deduplicatedReminders = Array(Set(allReminders.map { $0.text })).prefix(15).map { ReminderItem(text: $0, timeReference: ReminderItem.TimeReference(originalText: $0), urgency: .later, confidence: 0.8) }
        let deduplicatedTitles = Array(Set(allTitles.map { $0.text })).prefix(5).map { TitleItem(text: $0, confidence: 0.8) }
        
        // Use the most common content type or default to general
        let contentType: ContentType = .general
        
        let processingTime = Date().timeIntervalSince(startTime)
        print("✅ GoogleAI: Chunked processing completed in \(processingTime)s")
        print("📊 GoogleAI: Final results - Tasks: \(deduplicatedTasks.count), Reminders: \(deduplicatedReminders.count), Titles: \(deduplicatedTitles.count)")
        
        return (
            summary: finalSummary,
            tasks: deduplicatedTasks,
            reminders: deduplicatedReminders,
            titles: deduplicatedTitles,
            contentType: contentType
        )
    }
    
    func testConnection() async -> Bool {
        return await service.testConnection()
    }
    
    func loadAvailableModels() async throws -> [String] {
        return try await service.loadAvailableModels()
    }
    
    // MARK: - Private Helper Methods
    
    private func createSummaryPrompt(text: String, contentType: ContentType) -> String {
        return """
        Please provide a comprehensive summary of the following content using proper Markdown formatting:
        
        Use the following Markdown elements as appropriate:
        - **Bold text** for key points and important information
        - *Italic text* for emphasis
        - ## Headers for main sections
        - ### Subheaders for subsections
        - • Bullet points for lists
        - 1. Numbered lists for sequential items
        - > Blockquotes for important quotes or statements
        - `Code formatting` for technical terms or specific names
        
        Content to summarize:
        \(text)
        
        Content type: \(contentType.rawValue)
        
        Focus on the key points and main ideas. Keep the summary clear, informative, and well-structured with proper markdown formatting.
        """
    }
    
    private func createTaskExtractionPrompt(text: String) -> String {
        return """
        Extract personal and relevant actionable tasks from the following text:
        
        \(text)
        
        IMPORTANT GUIDELINES:
        - Focus ONLY on tasks that are personal to the speaker or their immediate context
        - Avoid tasks related to national news, public figures, celebrities, or general world events
        - Include specific action items, to-dos, or commitments mentioned by the speaker
        - Prioritize tasks that require personal action or follow-up
        - Examples of GOOD tasks: "Call John about the project", "Schedule dentist appointment", "Buy groceries"
        - Examples of tasks to AVOID: "Follow the news about elections", "Check updates on celebrity gossip", "Monitor world events"
        
        Return only personal, actionable tasks that directly affect the speaker.
        """
    }
    
    private func createReminderExtractionPrompt(text: String) -> String {
        return """
        Extract personal and relevant reminders from the following text:
        
        \(text)
        
        IMPORTANT GUIDELINES:
        - Focus ONLY on personal appointments, deadlines, or time-sensitive commitments
        - Avoid reminders about national news, public events, or general world happenings
        - Include specific dates, times, or deadlines mentioned by the speaker
        - Prioritize items that affect the speaker personally
        - Examples of GOOD reminders: "Dentist appointment on Friday", "Submit report by Monday", "Pick up dry cleaning tomorrow"
        - Examples of reminders to AVOID: "Election day is coming", "Check the weather forecast", "Follow news about world events"
        
        Return only personal, time-sensitive items that directly affect the speaker.
        """
    }
    
    private func createTitleExtractionPrompt(text: String) -> String {
        return """
        Suggest 3-5 appropriate titles for the following content:
        
        \(text)
        
        Provide concise, descriptive titles that capture the main topic or theme.
        """
    }
    
    private func createContentClassificationPrompt(text: String) -> String {
        return """
        Classify the following content into one of these categories:
        - meeting
        - interview
        - lecture
        - conversation
        - presentation
        - general
        
        Content:
        \(text)
        
        Respond with only the category name.
        """
    }
    
    private func parseTasksFromResponse(_ response: String) -> [TaskItem] {
        let lines = response.components(separatedBy: .newlines)
        var tasks: [TaskItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && (trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")) {
                let taskText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !taskText.isEmpty {
                    tasks.append(TaskItem(text: taskText, priority: .medium, confidence: 0.8))
                }
            }
        }
        
        return tasks
    }
    
    private func parseRemindersFromResponse(_ response: String) -> [ReminderItem] {
        let lines = response.components(separatedBy: .newlines)
        var reminders: [ReminderItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && (trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")) {
                let reminderText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !reminderText.isEmpty {
                    let timeRef = ReminderItem.TimeReference(originalText: reminderText)
                    reminders.append(ReminderItem(text: reminderText, timeReference: timeRef, urgency: .later, confidence: 0.8))
                }
            }
        }
        
        return reminders
    }
    
    private func parseTitlesFromResponse(_ response: String) -> [TitleItem] {
        let lines = response.components(separatedBy: .newlines)
        var titles: [TitleItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && (trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")) {
                let titleText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !titleText.isEmpty {
                    titles.append(TitleItem(text: titleText, confidence: 0.8))
                }
            }
        }
        
        return titles
    }
    
    private func parseContentTypeFromResponse(_ response: String) -> ContentType {
        let lowercased = response.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch lowercased {
        case "meeting": return .meeting
        case "interview": return .meeting
        case "lecture": return .technical
        case "conversation": return .meeting
        case "presentation": return .technical
        default: return .general
        }
    }
    
    private func createCompleteProcessingPrompt(text: String) -> String {
        return """
        Analyze the following transcript and extract comprehensive information:
        
        \(text)
        
        Please provide a structured response with:
        1. A detailed summary using proper Markdown formatting:
           - Use **bold** for key points and important information
           - Use *italic* for emphasis
           - Use ## headers for main sections
           - Use ### subheaders for subsections
           - Use • bullet points for lists
           - Use > blockquotes for important statements
           - Keep the summary well-structured and informative
        
        2. Personal and relevant actionable tasks (not general news or public events):
           - Focus on tasks that are personal to the speaker or their immediate context
           - Avoid tasks related to national news, public figures, or general world events
           - Include specific action items, to-dos, or commitments mentioned
           - Prioritize tasks that require personal action or follow-up
        
        3. Personal and relevant reminders (not general news or public events):
           - Focus on personal appointments, deadlines, or time-sensitive commitments
           - Avoid reminders about national news, public events, or general world happenings
           - Include specific dates, times, or deadlines mentioned
           - Prioritize items that affect the speaker personally
        
        4. 3-5 suggested titles that capture the main topic or theme
        
        5. The content type classification (meeting, interview, lecture, conversation, presentation, or general)
        
        Format your response as a JSON object with the following structure:
        {
          "summary": "detailed markdown-formatted summary of the content",
          "tasks": ["personal task1", "personal task2", "personal task3"],
          "reminders": ["personal reminder1", "personal reminder2"],
          "titles": ["title1", "title2", "title3"],
          "contentType": "content type"
        }
        
        IMPORTANT: Focus on personal, relevant content. Avoid extracting tasks or reminders related to:
        - National or international news events
        - Public figures or celebrities
        - General world events or politics
        - Events that don't directly affect the speaker
        """
    }
    
    private func parseStructuredResponse(_ response: String) -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        logger.info("GoogleAIStudioEngine: Parsing structured response")
        logger.info("Response length: \(response.count) characters")
        
        // Try to parse as JSON first
        if let jsonData = response.data(using: .utf8) {
            do {
                let summaryResponse = try JSONDecoder().decode(SummaryResponse.self, from: jsonData)
                logger.info("GoogleAIStudioEngine: Successfully parsed JSON response")
                logger.info("Summary length: \(summaryResponse.summary.count)")
                logger.info("Tasks count: \(summaryResponse.tasks.count)")
                logger.info("Reminders count: \(summaryResponse.reminders.count)")
                logger.info("Titles count: \(summaryResponse.titles.count)")
                
                // Convert string arrays to proper objects
                let tasks = summaryResponse.tasks.map { TaskItem(text: $0, priority: .medium, confidence: 0.8) }
                let reminders = summaryResponse.reminders.map { ReminderItem(text: $0, timeReference: ReminderItem.TimeReference(originalText: $0), urgency: .later, confidence: 0.8) }
                let titles = summaryResponse.titles.map { TitleItem(text: $0, confidence: 0.8) }
                let contentType = ContentType(rawValue: summaryResponse.contentType) ?? .general
                
                return (
                    summary: summaryResponse.summary,
                    tasks: tasks,
                    reminders: reminders,
                    titles: titles,
                    contentType: contentType
                )
            } catch {
                logger.error("GoogleAIStudioEngine: Failed to parse JSON response: \(error)")
                logger.error("GoogleAIStudioEngine: Raw response: \(response)")
            }
        }
        
        // Fallback: parse the formatted response
        var summary = ""
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []
        var titles: [TitleItem] = []
        var contentType: ContentType = .general
        
        let lines = response.components(separatedBy: .newlines)
        var currentSection = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("SUMMARY:") {
                currentSection = "summary"
                continue
            } else if trimmed.hasPrefix("TASKS:") {
                currentSection = "tasks"
                continue
            } else if trimmed.hasPrefix("REMINDERS:") {
                currentSection = "reminders"
                continue
            } else if trimmed.hasPrefix("SUGGESTED TITLES:") {
                currentSection = "titles"
                continue
            } else if trimmed.hasPrefix("CONTENT TYPE:") {
                currentSection = "contentType"
                continue
            }
            
            switch currentSection {
            case "summary":
                if !trimmed.isEmpty {
                    summary += (summary.isEmpty ? "" : "\n") + trimmed
                }
            case "tasks":
                if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") {
                    let taskText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !taskText.isEmpty {
                        tasks.append(TaskItem(text: taskText, priority: .medium, confidence: 0.8))
                    }
                }
            case "reminders":
                if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") {
                    let reminderText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                                            if !reminderText.isEmpty {
                            let timeRef = ReminderItem.TimeReference(originalText: reminderText)
                            reminders.append(ReminderItem(text: reminderText, timeReference: timeRef, urgency: .later, confidence: 0.8))
                        }
                }
            case "titles":
                if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") {
                    let titleText = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !titleText.isEmpty {
                        titles.append(TitleItem(text: titleText, confidence: 0.8))
                    }
                }
            case "contentType":
                if !trimmed.isEmpty {
                    contentType = parseContentTypeFromResponse(trimmed)
                }
            default:
                break
            }
        }
        
        return (summary: summary, tasks: tasks, reminders: reminders, titles: titles, contentType: contentType)
    }
}

// MARK: - Not Configured Engine for unconfigured state

class NotConfiguredEngine: SummarizationEngine {
    let name: String = "Not Configured"
    let description: String = "No AI summarization engine has been configured"
    let version: String = "1.0"
    let isAvailable: Bool = false

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        throw SummarizationError.configurationRequired(message: "AI summarization engine not configured. Please go to Settings to configure an AI engine.")
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        throw SummarizationError.configurationRequired(message: "AI summarization engine not configured. Please go to Settings to configure an AI engine.")
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        throw SummarizationError.configurationRequired(message: "AI summarization engine not configured. Please go to Settings to configure an AI engine.")
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        throw SummarizationError.configurationRequired(message: "AI summarization engine not configured. Please go to Settings to configure an AI engine.")
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        return .general
    }

    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        throw SummarizationError.configurationRequired(message: "AI summarization engine not configured. Please go to Settings to configure an AI engine.")
    }
}

// MARK: - No-Op Engine for "None" selection

class NoOpEngine: SummarizationEngine {
    let name: String = "None"
    let description: String = "No AI summarization engine selected"
    let version: String = "1.0"
    let isAvailable: Bool = true
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        return "AI summarization is disabled. Please select an AI engine in Settings > AI Processing to generate summaries."
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        return []
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        return []
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        return []
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        return .general
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let summary = "AI summarization is disabled. Please select an AI engine in Settings > AI Processing to generate summaries."
        return (summary, [], [], [], .general)
    }
}

// MARK: - Engine Factory

class AIEngineFactory {
    static func createEngine(type: AIEngineType) -> SummarizationEngine {
        switch type {
        case .notConfigured:
            return NotConfiguredEngine()
        case .none:
            return NoOpEngine()
        case .enhancedAppleIntelligence:
            return EnhancedAppleIntelligenceEngine()
        case .openAI:
            return OpenAISummarizationEngine()
        case .awsBedrock:
            return AWSBedrockEngine()
        case .openAICompatible:
            return OpenAICompatibleEngine()
        case .localLLM:
            return LocalLLMEngine()
        case .googleAIStudio:
            return GoogleAIStudioEngine()
        }
    }
    
    static func getAvailableEngines() -> [AIEngineType] {
        return AIEngineType.allCases.filter { type in
            let engine = createEngine(type: type)
            return engine.isAvailable
        }
    }
    
    static func getAllEngines() -> [AIEngineType] {
        return AIEngineType.allCases
    }
}

enum AIEngineType: String, CaseIterable {
    case notConfigured = "Not Configured"
    case none = "None"
    case enhancedAppleIntelligence = "Enhanced Apple Intelligence"
    case openAI = "OpenAI"
    case awsBedrock = "AWS Bedrock"
    case openAICompatible = "OpenAI API Compatible"
    case localLLM = "Local LLM (Ollama)"
    case googleAIStudio = "Google AI Studio"
    
    var description: String {
        switch self {
        case .notConfigured:
            return "No AI summarization engine has been configured yet"
        case .none:
            return "No AI summarization engine selected"
        case .enhancedAppleIntelligence:
            return "Advanced natural language processing using Apple's frameworks"
        case .openAI:
            return "Advanced AI-powered summaries using OpenAI's GPT models"
        case .awsBedrock:
            return "Cloud-based AI using AWS Bedrock foundation models"
        case .openAICompatible:
            return "Advanced AI summaries using OpenAI API compatible models"
        case .localLLM:
            return "Privacy-focused local language model processing"
        case .googleAIStudio:
            return "Advanced AI-powered summaries using Google's Gemini models"
        }
    }
    
    var isComingSoon: Bool {
        switch self {
        case .notConfigured, .none, .enhancedAppleIntelligence, .localLLM, .openAI, .openAICompatible, .googleAIStudio:
            return false
        case .awsBedrock:
            return false
        }
    }
    
    var requirements: [String] {
        switch self {
        case .notConfigured:
            return ["Configuration required - please select and configure an AI engine"]
        case .none:
            return ["No requirements - AI features disabled"]
        case .enhancedAppleIntelligence:
            return ["iOS 15.0+", "Built-in frameworks"]
        case .openAI:
            return ["OpenAI API Key", "Internet Connection", "Usage Credits"]
        case .awsBedrock:
            return ["AWS Account", "Internet Connection", "API Keys"]
        case .openAICompatible:
            return ["OpenAI API Compatible Service", "Internet Connection"]
        case .localLLM:
            return ["Ollama Server", "Local Network", "Model Download"]
        case .googleAIStudio:
            return ["Google AI Studio API Key", "Internet Connection", "Usage Credits"]
        }
    }
}