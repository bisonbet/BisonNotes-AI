//
//  AWSBedrockService.swift
//  Audio Journal
//
//  AWS Bedrock service implementation for AI summarization using AWS SDK
//

import Foundation
// TODO: Add AWS Bedrock SDK imports once added to project
// import AWSBedrock
// import AWSBedrockRuntime

// MARK: - AWS Bedrock Service

class AWSBedrockService: ObservableObject {
    
    // MARK: - Properties
    
    @Published var config: AWSBedrockConfig
    private let session: URLSession
    
    // MARK: - Initialization
    
    init(config: AWSBedrockConfig) {
        self.config = config
        
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout * 2
        self.session = URLSession(configuration: sessionConfig)
    }
    
    // MARK: - Public Methods
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
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
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
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
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
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
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
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
    
    func classifyContent(_ text: String) async throws -> ContentType {
        // Use enhanced ContentAnalyzer for classification
        return ContentAnalyzer.classifyContent(text)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // First classify the content
        let contentType = try await classifyContent(text)
        
        if config.model.supportsStructuredOutput {
            // Use structured output for supported models
            return try await processCompleteStructured(text: text, contentType: contentType)
        } else {
            // Use individual calls for models without structured output
            return try await processCompleteIndividual(text: text, contentType: contentType)
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
        
        // Create the model request
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
        
        // Create the AWS API request URL using URLComponents for proper encoding
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bedrock-runtime.\(config.region).amazonaws.com"
        components.path = "/model/\(config.model.rawValue)/invoke"
        
        guard let url = components.url else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid AWS Bedrock endpoint URL")
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(url.host!, forHTTPHeaderField: "Host")
        urlRequest.setValue("BisonNotes AI iOS App", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = requestBody
        
        // Sign the request with AWS Signature Version 4
        try signRequest(&urlRequest, body: requestBody)
        
        // Log the request details for debugging
        if let requestBodyString = String(data: requestBody, encoding: .utf8) {
            print("📤 AWS Bedrock API Request Body: \(requestBodyString)")
        }
        
        do {
            print("🌐 Making AWS Bedrock API request...")
            let (data, response) = try await session.data(for: urlRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SummarizationError.aiServiceUnavailable(service: "Invalid response from AWS Bedrock")
            }
            
            // Log the raw response for debugging
            let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
            print("🌐 AWS Bedrock API Response - Status: \(httpResponse.statusCode)")
            print("📝 Raw response: \(responseString)")
            print("📊 Response data length: \(data.count) bytes")
            
            if httpResponse.statusCode != 200 {
                // Try to parse error response
                if let errorResponse = try? JSONDecoder().decode(AWSBedrockError.self, from: data) {
                    print("❌ AWS Bedrock API Error: \(errorResponse.message)")
                    throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock API Error: \(errorResponse.message)")
                } else {
                    print("❌ AWS Bedrock API Error: HTTP \(httpResponse.statusCode) - \(responseString)")
                    throw SummarizationError.aiServiceUnavailable(service: "AWS Bedrock API Error: HTTP \(httpResponse.statusCode)")
                }
            }
            
            // Parse the model-specific response
            let modelResponse = try AWSBedrockModelFactory.parseResponse(for: config.model, data: data)
            
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
    
    // MARK: - AWS Signature Version 4
    
    private func signRequest(_ request: inout URLRequest, body: Data) throws {
        let now = Date()
        let formatter = DateFormatter()
        
        // ISO8601 date format for AWS
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        let amzDate = formatter.string(from: now)
        
        formatter.dateFormat = "yyyyMMdd"
        let dateStamp = formatter.string(from: now)
        
        // Add required headers
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        
        // Create canonical request
        let canonicalRequest = createCanonicalRequest(request: request, body: body)
        
        // Create string to sign
        let credentialScope = "\(dateStamp)/\(config.region)/bedrock/aws4_request"
        let stringToSign = """
AWS4-HMAC-SHA256
\(amzDate)
\(credentialScope)
\(sha256Hex(canonicalRequest))
"""
        
        // Debug the string to sign
        print("🔍 DEBUG: Our string to sign:")
        print(stringToSign)
        
        // Calculate signature
        let signature = try calculateSignature(
            stringToSign: stringToSign,
            dateStamp: dateStamp,
            region: config.region,
            service: "bedrock"
        )
        
        // Create authorization header  
        let authorizationHeader = "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(credentialScope), SignedHeaders=host;x-amz-date, Signature=\(signature)"
        
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
    }
    
    private func createCanonicalRequest(request: URLRequest, body: Data) -> String {
        let httpMethod = request.httpMethod ?? "POST"
        
        // Build the canonical URI exactly as AWS expects it
        // Based on error messages, AWS expects: /model/anthropic.claude-3-5-haiku-20241022-v1%3A0/invoke
        let modelId = config.model.rawValue
        let encodedModelId = modelId.replacingOccurrences(of: ":", with: "%3A")
        let canonicalUri = "/model/\(encodedModelId)/invoke"
        let canonicalQueryString = "" // No query parameters for Bedrock
        
        // Canonical headers (must be lowercase and sorted)
        var canonicalHeaders = ""
        var signedHeadersList: [String] = []
        
        // Get headers we want to sign and sort them
        if let headers = request.allHTTPHeaderFields {
            let sortedHeaders = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
            for (key, value) in sortedHeaders {
                let lowerKey = key.lowercased()
                if lowerKey == "host" || lowerKey == "x-amz-date" {
                    canonicalHeaders += "\(lowerKey):\(value.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    signedHeadersList.append(lowerKey)
                }
            }
        }
        
        let signedHeaders = signedHeadersList.sorted().joined(separator: ";")
        let payloadHash = sha256Hex(body)
        
        return "\(httpMethod)\n\(canonicalUri)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
    }
    
    private func calculateSignature(stringToSign: String, dateStamp: String, region: String, service: String) throws -> String {
        let kDate = try hmacSHA256(key: Data("AWS4\(config.secretAccessKey)".utf8), message: Data(dateStamp.utf8))
        let kRegion = try hmacSHA256(key: kDate, message: Data(region.utf8))
        let kService = try hmacSHA256(key: kRegion, message: Data(service.utf8))
        let kSigning = try hmacSHA256(key: kService, message: Data("aws4_request".utf8))
        let signature = try hmacSHA256(key: kSigning, message: Data(stringToSign.utf8))
        
        return signature.map { String(format: "%02x", $0) }.joined()
    }
    
    private func hmacSHA256(key: Data, message: Data) throws -> Data {
        var context = CCHmacContext()
        CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA256), key.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress }, key.count)
        CCHmacUpdate(&context, message.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress }, message.count)
        
        var hmac = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        hmac.withUnsafeMutableBytes { buffer in
            CCHmacFinal(&context, buffer.bindMemory(to: UInt8.self).baseAddress)
        }
        
        return hmac
    }
    
    private func sha256Hex(_ data: Data) -> String {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { buffer in
            hash.withUnsafeMutableBytes { hashBuffer in
                CC_SHA256(buffer.bindMemory(to: UInt8.self).baseAddress, CC_LONG(data.count), hashBuffer.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func sha256Hex(_ string: String) -> String {
        return sha256Hex(Data(string.utf8))
    }
    
    // MARK: - AWS URI Encoding
    
    /// AWS-compliant URI encoding function
    /// Encodes all characters except: A-Z, a-z, 0-9, '-', '.', '_', '~'
    /// Follows AWS Signature V4 specification
    private func awsUriEncode(_ string: String) -> String {
        let unreservedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        
        var encoded = ""
        for character in string {
            let scalar = character.unicodeScalars.first!
            if unreservedCharacters.contains(scalar) {
                encoded.append(character)
            } else {
                // Encode the character as %XX where XX is uppercase hex
                let utf8 = String(character).data(using: .utf8)!
                for byte in utf8 {
                    encoded.append(String(format: "%%%02X", byte))
                }
            }
        }
        return encoded
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