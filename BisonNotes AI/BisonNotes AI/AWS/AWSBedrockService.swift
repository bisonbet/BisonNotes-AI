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
            let clientConfig = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
                region: sharedCredentials.region
            )
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
                let systemPrompt = createSystemPrompt(for: contentType)
                let userPrompt = createSummaryPrompt(text: chunk)
                
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
            let systemPrompt = createSystemPrompt(for: contentType)
            let userPrompt = createSummaryPrompt(text: text)
            
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
                let systemPrompt = "You are an AI assistant that extracts actionable tasks from text. Focus on personal, actionable items that require follow-up."
                let userPrompt = createTaskExtractionPrompt(text: chunk)
                
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
            let systemPrompt = "You are an AI assistant that extracts actionable tasks from text. Focus on personal, actionable items that require follow-up."
            let userPrompt = createTaskExtractionPrompt(text: text)
            
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
                let systemPrompt = "You are an AI assistant that extracts time-sensitive reminders from text. Focus on deadlines, appointments, and scheduled events."
                let userPrompt = createReminderExtractionPrompt(text: chunk)
                
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
            let systemPrompt = "You are an AI assistant that extracts time-sensitive reminders from text. Focus on deadlines, appointments, and scheduled events."
            let userPrompt = createReminderExtractionPrompt(text: text)
            
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
                let systemPrompt = "You are an AI assistant that generates concise, descriptive titles for content. Create 3-5 titles that capture the main topics or themes."
                let userPrompt = createTitleExtractionPrompt(text: chunk)
                
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
            let systemPrompt = "You are an AI assistant that generates concise, descriptive titles for content. Create 3-5 titles that capture the main topics or themes."
            let userPrompt = createTitleExtractionPrompt(text: text)
            
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
        
        // Log the request details for debugging
        if let requestBodyString = String(data: requestBody, encoding: .utf8) {
            print("📤 AWS Bedrock API Request Body: \(requestBodyString)")
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
            
            let response = try await client.invokeModel(input: invokeRequest)
            
            guard let responseBody = response.body else {
                throw SummarizationError.aiServiceUnavailable(service: "Empty response from AWS Bedrock")
            }
            
            // Convert response body to Data
            let responseData = Data(responseBody)
            
            // Log the raw response for debugging
            let responseString = String(data: responseData, encoding: .utf8) ?? "Unable to decode response"
            print("🌐 AWS Bedrock API Response received")
            print("📝 Raw response: \(responseString)")
            print("📊 Response data length: \(responseData.count) bytes")
            
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
        let systemPrompt = createSystemPrompt(for: contentType)
        let userPrompt = createCompleteProcessingPrompt(text: text)
        
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
    
    
    // MARK: - Prompt Generators
    
    private func createSystemPrompt(for contentType: ContentType) -> String {
        let basePrompt = """
        You are an AI assistant specialized in analyzing and summarizing audio transcripts and conversations. Your role is to provide clear, actionable insights from the content provided.
        
        **Key Guidelines:**
        - Focus on extracting meaningful, actionable information
        - Maintain accuracy and relevance to the source material
        - Use clear, professional language
        - Structure responses logically and coherently
        - Prioritize the most important information first
        """
        
        switch contentType {
        case .meeting:
            return basePrompt + """
            
            **Meeting Analysis Focus:**
            - Identify key decisions and action items
            - Note important deadlines and commitments
            - Highlight participant responsibilities
            - Capture meeting outcomes and next steps
            - Focus on business-relevant information
            """
        case .personalJournal:
            return basePrompt + """
            
            **Personal Journal Analysis Focus:**
            - Identify personal insights and reflections
            - Note emotional states and personal growth
            - Highlight personal goals and aspirations
            - Capture meaningful life events and experiences
            - Focus on personal development and self-awareness
            """
        case .technical:
            return basePrompt + """
            
            **Technical Analysis Focus:**
            - Identify technical problems and solutions
            - Note implementation details and requirements
            - Highlight technical decisions and trade-offs
            - Capture technical specifications and constraints
            - Focus on technical accuracy and precision
            """
        case .general:
            return basePrompt + """
            
            **General Analysis Focus:**
            - Identify main topics and themes
            - Note important information and insights
            - Highlight key points and takeaways
            - Capture relevant details and context
            - Focus on clarity and comprehensiveness
            """
        }
    }
    
    private func createSummaryPrompt(text: String) -> String {
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
        
        Content to summarize:
        \(text)
        
        Focus on the key points and main ideas. Keep the summary clear, informative, and well-structured with proper markdown formatting.
        """
    }
    
    private func createTaskExtractionPrompt(text: String) -> String {
        return """
        Extract actionable tasks from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "task description",
                "priority": "high|medium|low",
                "category": "call|meeting|purchase|research|email|travel|health|general",
                "timeReference": "today|tomorrow|this week|next week|specific date or null",
                "confidence": 0.85
            }
        ]

        Content:
        \(text)
        """
    }
    
    private func createReminderExtractionPrompt(text: String) -> String {
        return """
        Extract reminders and time-sensitive items from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "reminder description",
                "urgency": "immediate|today|thisWeek|later",
                "timeReference": "specific time or date mentioned",
                "confidence": 0.85
            }
        ]

        Content:
        \(text)
        """
    }
    
    private func createTitleExtractionPrompt(text: String) -> String {
        return """
        Analyze the following transcript and extract 4 high-quality titles or headlines. Focus on:
        - Main topics or themes discussed
        - Key decisions or outcomes
        - Important events or milestones
        - Central questions or problems addressed

        **Return the results in this exact JSON format:**
        {
          "titles": [
            {
              "text": "title text",
              "category": "Meeting|Personal|Technical|General",
              "confidence": 0.85
            }
          ]
        }

        Requirements:
        - Generate exactly 4 titles with 85% or higher confidence
        - Each title should be 40-60 characters and 4-6 words
        - Focus on the most important and specific topics
        - Avoid generic or vague titles
        - If no suitable titles are found, return empty array

        Transcript:
        \(text)
        """
    }
    
    private func createCompleteProcessingPrompt(text: String) -> String {
        return """
        Please analyze the following content and provide a comprehensive response in VALID JSON format only. Do not include any text before or after the JSON. The response must be a single, well-formed JSON object with this exact structure:

        {
            "summary": "A detailed summary using Markdown formatting with **bold**, *italic*, ## headers, • bullet points, etc.",
            "tasks": [
                {
                    "text": "task description",
                    "priority": "high|medium|low",
                    "category": "call|meeting|purchase|research|email|travel|health|general",
                    "timeReference": "today|tomorrow|this week|next week|specific date or null",
                    "confidence": 0.85
                }
            ],
            "reminders": [
                {
                    "text": "reminder description",
                    "urgency": "immediate|today|thisWeek|later",
                    "timeReference": "specific time or date mentioned",
                    "confidence": 0.85
                }
            ],
            "titles": [
                {
                    "text": "Generate 4 high-quality titles (40-60 characters, 4-6 words each) that capture the main topics, decisions, or key subjects discussed. Focus on the most important and specific topics. Use proper capitalization (Title Case) and never end with punctuation marks.",
                    "category": "meeting|personal|technical|general",
                    "confidence": 0.85
                }
            ]
        }

        IMPORTANT: 
        - Return ONLY valid JSON, no additional text or explanations
        - The "summary" field must use Markdown formatting: **bold**, *italic*, ## headers, • bullets, etc.
        - If no tasks are found, use an empty array: "tasks": []
        - If no reminders are found, use an empty array: "reminders": []
        - If no titles are found, use an empty array: "titles": []
        - Ensure all strings are properly quoted and escaped (especially for Markdown characters)
        - Do not include trailing commas
        - Escape special characters in JSON strings (quotes, backslashes, newlines)

        Content to analyze:
        \(text)
        """
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
                
                let cleanText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
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
                
                let cleanText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty && cleanText.count > 5 {
                    reminders.append(ReminderItem(
                        text: cleanText,
                        timeReference: ReminderItem.TimeReference(originalText: "No time specified"),
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
                
                let cleanText = trimmed
                    .replacingOccurrences(of: "•", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty {
                    // Apply standardized title cleaning
                    let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(cleanText)
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