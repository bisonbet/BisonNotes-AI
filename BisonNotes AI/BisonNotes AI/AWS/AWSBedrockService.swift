//
//  AWSBedrockService.swift
//  Audio Journal
//
//  AWS Bedrock service implementation for AI summarization using AWS SDK
//

import Foundation
import AWSBedrockRuntime
import AWSClientRuntime

// MARK: - AWS Bedrock Service

class AWSBedrockService: ObservableObject {
    
    // MARK: - Properties
    
    @Published var config: AWSBedrockConfig
    private var bedrockClient: BedrockRuntimeClient?
    
    // MARK: - Initialization
    
    init(config: AWSBedrockConfig) {
        self.config = config
        // Client will be initialized lazily when first needed
        self.bedrockClient = nil
    }
    
    // MARK: - Private Helper Methods
    
    private func getBedrockClient() async throws -> BedrockRuntimeClient {
        if let client = bedrockClient {
            return client
        }
        
        // Use shared AWS credentials for all services
        let sharedCredentials = AWSCredentialsManager.shared.credentials
        
        // Ensure environment variables are set from shared credentials
        AWSCredentialsManager.shared.initializeEnvironment()
        
        do {
            let clientConfig = try await BedrockRuntimeClient.BedrockRuntimeClientConfig(
                region: sharedCredentials.region
            )
            
            // AWS SDK for Swift will automatically use environment variables
            // set by AWSCredentialsManager.initializeEnvironment()
            
            let client = BedrockRuntimeClient(config: clientConfig)
            self.bedrockClient = client
            return client
        } catch {
            print("⚠️ Failed to initialize BedrockRuntimeClient: \(error)")
            throw SummarizationError.aiServiceUnavailable(service: "Failed to initialize AWS Bedrock client: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Public Methods
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        // Check if text needs chunking for this individual method
        let tokenCount = TokenManager.getTokenCount(text)
        let maxTokens = Int(Double(config.model.contextWindow) * 0.8)

        if TokenManager.needsChunking(text, maxTokens: maxTokens) {
            print("🔀 AWS Bedrock Summary: Large text detected (\(tokenCount) tokens), using chunked processing")
            let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
            var summaries: [String] = []

            for chunk in chunks {
                let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .summary, contentType: contentType)
                let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .summary, text: chunk)

                let response = try await invokeModel(
                    prompt: userPrompt,
                    systemPrompt: systemPrompt,
                    maxTokens: config.maxTokens,
                    temperature: config.temperature
                )
                summaries.append(response)
            }

            // Generate meta-summary from all chunk summaries
            return try await generateMetaSummary(from: summaries, contentType: contentType)
        } else {
            // Single chunk processing
            let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .summary, contentType: contentType)
            let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .summary, text: text)

            let response = try await invokeModel(
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: config.maxTokens,
                temperature: config.temperature
            )

            return response
        }
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        // Check if text needs chunking
        let maxTokens = Int(Double(config.model.contextWindow) * 0.8)

        if TokenManager.needsChunking(text, maxTokens: maxTokens) {
            let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
            var allTasks: [TaskItem] = []

            for chunk in chunks {
                let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .tasks, contentType: .general)
                let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .tasks, text: chunk)

                let response = try await invokeModel(
                    prompt: userPrompt,
                    systemPrompt: systemPrompt,
                    maxTokens: 1024,
                    temperature: 0.1
                )

                let chunkTasks = parseTasksFromResponse(response)
                allTasks.append(contentsOf: chunkTasks)
            }

            return deduplicateTasks(allTasks)
        } else {
            let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .tasks, contentType: .general)
            let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .tasks, text: text)

            let response = try await invokeModel(
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 1024,
                temperature: 0.1
            )

            return parseTasksFromResponse(response)
        }
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        // Check if text needs chunking
        let maxTokens = Int(Double(config.model.contextWindow) * 0.8)

        if TokenManager.needsChunking(text, maxTokens: maxTokens) {
            let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
            var allReminders: [ReminderItem] = []

            for chunk in chunks {
                let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .reminders, contentType: .general)
                let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .reminders, text: chunk)

                let response = try await invokeModel(
                    prompt: userPrompt,
                    systemPrompt: systemPrompt,
                    maxTokens: 1024,
                    temperature: 0.1
                )

                let chunkReminders = parseRemindersFromResponse(response)
                allReminders.append(contentsOf: chunkReminders)
            }

            return deduplicateReminders(allReminders)
        } else {
            let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .reminders, contentType: .general)
            let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .reminders, text: text)

            let response = try await invokeModel(
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 1024,
                temperature: 0.1
            )

            return parseRemindersFromResponse(response)
        }
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        // Check if text needs chunking
        let maxTokens = Int(Double(config.model.contextWindow) * 0.8)

        if TokenManager.needsChunking(text, maxTokens: maxTokens) {
            let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
            var allTitles: [TitleItem] = []

            for chunk in chunks {
                let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .titles, contentType: .general)
                let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .titles, text: chunk)

                let response = try await invokeModel(
                    prompt: userPrompt,
                    systemPrompt: systemPrompt,
                    maxTokens: 512,
                    temperature: 0.2
                )

                let chunkTitles = parseTitlesFromResponse(response)
                allTitles.append(contentsOf: chunkTitles)
            }

            return deduplicateTitles(allTitles)
        } else {
            let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .titles, contentType: .general)
            let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .titles, text: text)

            let response = try await invokeModel(
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: 512,
                temperature: 0.2
            )

            return parseTitlesFromResponse(response)
        }
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        // Use enhanced ContentAnalyzer for classification
        return ContentAnalyzer.classifyContent(text)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // First classify the content
        let contentType = try await classifyContent(text)
        
        // Check if text needs chunking based on model's context window
        let tokenCount = TokenManager.getTokenCount(text)
        let maxTokens = Int(Double(config.model.contextWindow) * 0.8) // Leave 20% buffer for response
        
        print("📊 AWS Bedrock: Text token count: \(tokenCount), max allowed: \(maxTokens)")
        
        if TokenManager.needsChunking(text, maxTokens: maxTokens) {
            print("🔀 Large transcript detected (\(tokenCount) tokens), using chunked processing")
            return try await processCompleteChunked(text: text, contentType: contentType, maxTokens: maxTokens)
        } else {
            print("📝 Processing single chunk (\(tokenCount) tokens)")
            if config.model.supportsStructuredOutput {
                // Use structured output for supported models
                return try await processCompleteStructured(text: text, contentType: contentType)
            } else {
                // Use individual calls for models without structured output
                return try await processCompleteIndividual(text: text, contentType: contentType)
            }
        }
    }
    
    func testConnection() async -> Bool {
        do {
            let testPrompt = "Hello, this is a test message. Please respond with 'Test successful'."
            let response = try await invokeModel(
                prompt: testPrompt,
                systemPrompt: "You are a helpful assistant.",
                maxTokens: 50,
                temperature: 0.1
            )
            let success = response.contains("Test successful") || response.contains("test successful")
            print("✅ AWS Bedrock connection test \(success ? "successful" : "failed")")
            return success
        } catch {
            print("❌ AWS Bedrock connection test failed: \(error)")
            return false
        }
    }
    
    func listAvailableModels() async throws -> [AWSBedrockModel] {
        // For now, return the predefined models
        // In a full implementation, you could query the AWS Bedrock API
        return AWSBedrockModel.allCases
    }
    
    // MARK: - Private Helper Methods
    
    private func invokeModel(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        // Validate configuration
        guard config.isValid else {
            print("❌ AWS Bedrock configuration is invalid")
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock configuration is invalid")
        }
        
        print("🔧 AWS Bedrock API Configuration - Model: \(config.model.rawValue), Region: \(config.region)")
        
        // Create the model request payload
        let modelRequest = AWSBedrockModelFactory.createRequest(
            for: config.model,
            prompt: prompt,
            systemPrompt: systemPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
        
        // Encode the request body
        let requestBody: Data
        do {
            let encoder = JSONEncoder()
            requestBody = try encoder.encode(modelRequest)
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to encode request: \(error.localizedDescription)")
        }
        
        do {
            print("🌐 Making AWS Bedrock API request using official SDK...")
            
            // Get the Bedrock client (initialize if needed)
            let client = try await getBedrockClient()
            
            // Use the official AWS SDK to invoke the model
            let invokeRequest = InvokeModelInput(
                accept: "application/json",
                body: requestBody,
                contentType: "application/json",
                modelId: config.model.rawValue
            )
            
            let response: InvokeModelOutput
            do {
                // Wrap SDK call to honor the user-configured timeout even if the SDK has its own limits.
                response = try await withTimeout(seconds: config.timeout) {
                    try await client.invokeModel(input: invokeRequest)
                }
            } catch let error as SummarizationError {
                throw error
            } catch {
                if (error as? URLError)?.code == .timedOut {
                    throw SummarizationError.processingTimeout
                }
                throw error
            }
            
            guard let responseBody = response.body else {
                throw SummarizationError.aiServiceUnavailable(service: "Empty response from AWS Bedrock")
            }
            
            // Convert response body to Data
            let responseData = Data(responseBody)
            
            // Log the raw response only when verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                let responseString = String(data: responseData, encoding: .utf8) ?? "Unable to decode response"
                print("🌐 AWS Bedrock API Response received")
                print("📝 Raw response: \(responseString)")
                print("📊 Response data length: \(responseData.count) bytes")
            }
            
            // Parse the model-specific response
            let modelResponse = try AWSBedrockModelFactory.parseResponse(for: config.model, data: responseData)
            
            print("✅ AWS Bedrock API Success - Model: \(config.model.rawValue)")
            print("📝 Response content length: \(modelResponse.content.count) characters")
            
            return modelResponse.content
            
        } catch {
            print("❌ AWS Bedrock API request failed: \(error)")
            throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock API request failed: \(error.localizedDescription)")
        }
    }
    
    private func processCompleteStructured(text: String, contentType: ContentType) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let systemPrompt = OpenAIPromptGenerator.createSystemPrompt(for: .complete, contentType: contentType)
        let userPrompt = OpenAIPromptGenerator.createUserPrompt(for: .complete, text: text)
        
        let response = try await invokeModel(
            prompt: userPrompt,
            systemPrompt: systemPrompt,
            maxTokens: config.maxTokens,
            temperature: config.temperature
        )
        
        // Parse the structured response
        let result = try parseCompleteResponseFromJSON(response)
        return (result.summary, result.tasks, result.reminders, result.titles, contentType)
    }
    
    private func processCompleteIndividual(text: String, contentType: ContentType) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Process requests sequentially to avoid overwhelming the API
        let summary = try await generateSummary(from: text, contentType: contentType)
        
        // Small delay between requests
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        let tasks = try await extractTasks(from: text)
        
        // Small delay between requests
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        let reminders = try await extractReminders(from: text)
        
        // Small delay between requests
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        let titles = try await extractTitles(from: text)
        
        return (summary, tasks, reminders, titles, contentType)
    }
    
    private func processCompleteChunked(text: String, contentType: ContentType, maxTokens: Int) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Split text into chunks
        let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
        print("📦 AWS Bedrock: Split text into \(chunks.count) chunks")
        
        // Process each chunk
        var allSummaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        
        for (index, chunk) in chunks.enumerated() {
            print("🔄 AWS Bedrock: Processing chunk \(index + 1) of \(chunks.count) (\(TokenManager.getTokenCount(chunk)) tokens)")
            
            do {
                if config.model.supportsStructuredOutput {
                    let chunkResult = try await processCompleteStructured(text: chunk, contentType: contentType)
                    allSummaries.append(chunkResult.summary)
                    allTasks.append(contentsOf: chunkResult.tasks)
                    allReminders.append(contentsOf: chunkResult.reminders)
                    allTitles.append(contentsOf: chunkResult.titles)
                } else {
                    let chunkResult = try await processCompleteIndividual(text: chunk, contentType: contentType)
                    allSummaries.append(chunkResult.summary)
                    allTasks.append(contentsOf: chunkResult.tasks)
                    allReminders.append(contentsOf: chunkResult.reminders)
                    allTitles.append(contentsOf: chunkResult.titles)
                }
                
                // Small delay between chunks to prevent overwhelming the API
                if index < chunks.count - 1 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second between chunks
                }
            } catch {
                print("❌ AWS Bedrock: Failed to process chunk \(index + 1): \(error)")
                throw error
            }
        }
        
        // Combine all summaries into a cohesive meta-summary
        let combinedSummary = try await generateMetaSummary(from: allSummaries, contentType: contentType)
        
        // Deduplicate tasks and reminders
        let deduplicatedTasks = deduplicateTasks(allTasks)
        let deduplicatedReminders = deduplicateReminders(allReminders)
        let deduplicatedTitles = deduplicateTitles(allTitles)
        
        print("📊 AWS Bedrock: Final summary: \(combinedSummary.count) characters")
        print("📊 AWS Bedrock: Tasks: \(deduplicatedTasks.count), Reminders: \(deduplicatedReminders.count), Titles: \(deduplicatedTitles.count)")
        
        return (combinedSummary, deduplicatedTasks, deduplicatedReminders, deduplicatedTitles, contentType)
    }
    
    private func generateMetaSummary(from summaries: [String], contentType: ContentType) async throws -> String {
        guard !summaries.isEmpty else { return "" }
        
        // If only one summary, return it directly
        if summaries.count == 1 {
            return summaries[0]
        }
        
        // Combine all summaries for meta-summarization
        let combinedText = summaries.joined(separator: "\n\n")
        
        // Check if combined text fits within context window
        let combinedTokens = TokenManager.getTokenCount(combinedText)
        let maxTokens = Int(Double(config.model.contextWindow) * 0.8)
        
        if combinedTokens <= maxTokens {
            // Generate meta-summary directly
            let systemPrompt = """
            You are an AI assistant that creates cohesive summaries from multiple text segments. 
            Combine the following summaries into one comprehensive, well-structured summary that captures all key information without redundancy.
            Use proper Markdown formatting with **bold**, *italic*, ## headers, and • bullet points.
            """
            
            let userPrompt = """
            Please create a comprehensive summary by combining these segments:
            
            \(combinedText)
            
            Create a single, cohesive summary that captures all important information while eliminating redundancy.
            """
            
            return try await invokeModel(
                prompt: userPrompt,
                systemPrompt: systemPrompt,
                maxTokens: config.maxTokens,
                temperature: config.temperature
            )
        } else {
            // Recursively chunk and summarize if still too large
            let chunks = TokenManager.chunkText(combinedText, maxTokens: maxTokens)
            var intermediateSummaries: [String] = []
            
            for chunk in chunks {
                let summary = try await generateSummary(from: chunk, contentType: contentType)
                intermediateSummaries.append(summary)
            }
            
            // Recursively generate meta-summary
            return try await generateMetaSummary(from: intermediateSummaries, contentType: contentType)
        }
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
    // MARK: - Response Parsers
    
    private func parseCompleteResponseFromJSON(_ jsonString: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        // Reuse the existing OpenAI response parser since the JSON structure is the same
        return try OpenAIResponseParser.parseCompleteResponseFromJSON(jsonString)
    }
    
    private func parseTasksFromResponse(_ response: String) -> [TaskItem] {
        do {
            return try OpenAIResponseParser.parseTasksFromJSON(response)
        } catch {
            print("❌ Failed to parse tasks JSON, falling back to text parsing")
            return parseTasksFromPlainText(response)
        }
    }
    
    private func parseRemindersFromResponse(_ response: String) -> [ReminderItem] {
        do {
            return try OpenAIResponseParser.parseRemindersFromJSON(response)
        } catch {
            print("❌ Failed to parse reminders JSON, falling back to text parsing")
            return parseRemindersFromPlainText(response)
        }
    }
    
    private func parseTitlesFromResponse(_ response: String) -> [TitleItem] {
        do {
            return try OpenAIResponseParser.parseTitlesFromJSON(response)
        } catch {
            print("❌ Failed to parse titles JSON, falling back to text parsing")
            return parseTitlesFromPlainText(response)
        }
    }
    
    private func parseTasksFromPlainText(_ text: String) -> [TaskItem] {
        let lines = text.components(separatedBy: .newlines)
        var tasks: [TaskItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().contains("task") || 
               trimmed.lowercased().contains("todo") ||
               trimmed.lowercased().contains("action") ||
               (trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")) {
                
                let rawText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let cleanText = RecordingNameGenerator.cleanAIOutput(rawText)
                
                if !cleanText.isEmpty && cleanText.count > 5 {
                    tasks.append(TaskItem(
                        text: cleanText,
                        priority: .medium,
                        timeReference: nil,
                        category: .general,
                        confidence: 0.6
                    ))
                }
            }
        }
        
        return tasks
    }
    
    private func parseRemindersFromPlainText(_ text: String) -> [ReminderItem] {
        let lines = text.components(separatedBy: .newlines)
        var reminders: [ReminderItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().contains("reminder") || 
               trimmed.lowercased().contains("remember") ||
               (trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")) {
                
                let rawText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let cleanText = RecordingNameGenerator.cleanAIOutput(rawText)
                
                if !cleanText.isEmpty && cleanText.count > 5 {
                    reminders.append(ReminderItem(
                        text: cleanText,
                        timeReference: ReminderItem.TimeReference.fromReminderText(cleanText),
                        urgency: .later,
                        confidence: 0.6
                    ))
                }
            }
        }
        
        return reminders
    }
    
    private func parseTitlesFromPlainText(_ text: String) -> [TitleItem] {
        let lines = text.components(separatedBy: .newlines)
        var titles: [TitleItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*")) && 
               trimmed.count > 10 && trimmed.count < 80 {
                
                let rawText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !rawText.isEmpty {
                    // Apply standardized title cleaning
                    let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(rawText)
                    if cleanedTitle != "Untitled Conversation" {
                        titles.append(TitleItem(
                            text: cleanedTitle,
                            confidence: 0.6,
                            category: .general
                        ))
                    }
                }
            }
        }
        
        return Array(titles.prefix(5)) // Limit to 5 titles
    }
}
