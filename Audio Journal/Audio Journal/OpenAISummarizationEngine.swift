//
//  OpenAISummarizationEngine.swift
//  Audio Journal
//
//  OpenAI-powered summarization engine implementation
//

import Foundation

class OpenAISummarizationEngine: SummarizationEngine {
    let name: String = "OpenAI"
    let description: String = "Advanced AI-powered summaries using OpenAI's GPT models"
    let version: String = "1.0"
    
    private var service: OpenAISummarizationService?
    private var currentConfig: OpenAISummarizationConfig?
    
    var isAvailable: Bool {
        // Check if API key is configured
        let apiKey = UserDefaults.standard.string(forKey: "openAISummarizationAPIKey") ?? ""
        return !apiKey.isEmpty
    }
    
    init() {
        updateConfiguration()
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        print("🤖 OpenAISummarizationEngine: Starting summary generation")
        
        updateConfiguration()
        
        guard let service = service else {
            print("❌ OpenAISummarizationEngine: Service is nil")
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        print("✅ OpenAISummarizationEngine: Calling OpenAI service for summary")
        return try await service.generateSummary(from: text, contentType: contentType)
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        return try await service.extractTasks(from: text)
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        return try await service.extractReminders(from: text)
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        return try await service.classifyContent(text)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        updateConfiguration()
        
        guard let service = service else {
            throw SummarizationError.aiServiceUnavailable(service: name)
        }
        
        print("🤖 OpenAISummarizationEngine: Starting complete processing")
        
        // Check if text needs chunking based on token count
        let tokenCount = TokenManager.getTokenCount(text)
        print("📊 Text token count: \(tokenCount)")
        
        if TokenManager.needsChunking(text) {
            print("🔀 Large transcript detected (\(tokenCount) tokens), using chunked processing")
            return try await processChunkedText(text, service: service)
        } else {
            print("📝 Processing single chunk (\(tokenCount) tokens)")
            return try await service.processComplete(text: text)
        }
    }
    
    // MARK: - Configuration Management
    
    private func updateConfiguration() {
        let apiKey = UserDefaults.standard.string(forKey: "openAISummarizationAPIKey") ?? ""
        let modelString = UserDefaults.standard.string(forKey: "openAISummarizationModel") ?? OpenAISummarizationModel.gpt41Mini.rawValue
        let baseURL = UserDefaults.standard.string(forKey: "openAISummarizationBaseURL") ?? "https://api.openai.com/v1"
        let temperature = UserDefaults.standard.double(forKey: "openAISummarizationTemperature")
        let maxTokens = UserDefaults.standard.integer(forKey: "openAISummarizationMaxTokens")
        
        let model = OpenAISummarizationModel(rawValue: modelString) ?? .gpt41Mini
        
        let newConfig = OpenAISummarizationConfig(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            temperature: temperature > 0 ? temperature : 0.1,
            maxTokens: maxTokens > 0 ? maxTokens : nil
        )
        
        // Only create a new service if the configuration has actually changed
        if currentConfig == nil || currentConfig != newConfig {
            print("🔧 OpenAISummarizationEngine: Updating configuration - Model: \(model.displayName), BaseURL: \(baseURL)")
            
            self.currentConfig = newConfig
            self.service = OpenAISummarizationService(config: newConfig)
            print("✅ OpenAISummarizationEngine: Configuration updated successfully")
        }
    }
    
    // MARK: - Chunked Processing
    
    private func processChunkedText(_ text: String, service: OpenAISummarizationService) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        let startTime = Date()
        
        // Split text into chunks
        let chunks = TokenManager.chunkText(text)
        print("📦 Split text into \(chunks.count) chunks")
        
        // Process each chunk
        var allSummaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var contentType: ContentType = .general
        
        for (index, chunk) in chunks.enumerated() {
            print("🔄 Processing chunk \(index + 1) of \(chunks.count) (\(TokenManager.getTokenCount(chunk)) tokens)")
            
            do {
                let chunkResult = try await service.processComplete(text: chunk)
                allSummaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                
                // Use the first chunk's content type
                if index == 0 {
                    contentType = chunkResult.contentType
                }
                
            } catch {
                print("❌ Failed to process chunk \(index + 1): \(error)")
                throw error
            }
        }
        
        // Combine results
        let combinedSummary = TokenManager.combineSummaries(allSummaries, contentType: contentType)
        
        // Deduplicate tasks and reminders
        let uniqueTasks = deduplicateTasks(allTasks)
        let uniqueReminders = deduplicateReminders(allReminders)
        
        let processingTime = Date().timeIntervalSince(startTime)
        print("✅ Chunked processing completed in \(String(format: "%.2f", processingTime))s")
        print("📊 Final summary: \(combinedSummary.count) characters")
        print("📋 Final tasks: \(uniqueTasks.count)")
        print("🔔 Final reminders: \(uniqueReminders.count)")
        
        return (combinedSummary, uniqueTasks, uniqueReminders, contentType)
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
    
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async -> Bool {
        updateConfiguration()
        
        guard let service = service else {
            return false
        }
        
        do {
            try await service.testConnection()
            return true
        } catch {
            print("❌ OpenAI connection test failed: \(error)")
            return false
        }
    }
}