//
//  GoogleAIStudioService.swift
//  Audio Journal
//
//  Service for Google AI Studio (Gemini) API integration
//

import Foundation
import os.log
import SwiftUI

// MARK: - Google AI Studio Service

class GoogleAIStudioService: ObservableObject {
    private let logger = Logger(subsystem: "com.audiojournal.app", category: "GoogleAIStudio")
    
    @AppStorage("googleAIStudioAPIKey") private var apiKey: String = ""
    @AppStorage("googleAIStudioModel") private var selectedModel: String = "gemini-2.5-flash"
    @AppStorage("googleAIStudioTemperature") private var temperature: Double = 0.1
    @AppStorage("googleAIStudioMaxTokens") private var maxTokens: Int = 8192
    @AppStorage("enableGoogleAIStudio") private var enableGoogleAIStudio: Bool = false
    
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    
    // MARK: - API Response Models
    
    struct GeminiRequest: Codable {
        let contents: [Content]
        let generationConfig: GenerationConfig
    }
    
    struct Content: Codable {
        let parts: [Part]
    }
    
    struct Part: Codable {
        let text: String
    }
    
    struct GenerationConfig: Codable {
        let responseMimeType: String
        let responseSchema: Schema
        let temperature: Double?
        let maxOutputTokens: Int?
    }
    
    struct Schema: Codable {
        let type: String
        let properties: [String: SchemaProperty]
        let required: [String]
        let propertyOrdering: [String]
    }
    
    struct SchemaProperty: Codable {
        let type: String
        let description: String?
        let maxItems: Int?
        
        init(type: String, description: String? = nil, maxItems: Int? = nil) {
            self.type = type
            self.description = description
            self.maxItems = maxItems
        }
    }
    
    struct GeminiResponse: Codable {
        let candidates: [Candidate]
    }
    
    struct Candidate: Codable {
        let content: Content
    }
    
    struct SummaryResponse: Codable {
        let summary: String
        let tasks: [String]
        let reminders: [String]
        let titles: [String]
        let contentType: String
    }
    
    // MARK: - Initialization
    
    init() {
        // Ensure enableGoogleAIStudio has a default value in UserDefaults
        if UserDefaults.standard.object(forKey: "enableGoogleAIStudio") == nil {
            UserDefaults.standard.set(false, forKey: "enableGoogleAIStudio")
            logger.info("GoogleAIStudioService: Initialized enableGoogleAIStudio to false in UserDefaults")
        }
    }
    
    // MARK: - Configuration
    
    func updateConfiguration() {
        logger.info("GoogleAIStudioService: Updating configuration")
        logger.info("API Key: \(self.apiKey.isEmpty ? "Not set" : "Set")")
        logger.info("Model: \(self.selectedModel)")
        logger.info("Temperature: \(self.temperature)")
        logger.info("Max Tokens: \(self.maxTokens)")
        logger.info("Enabled: \(self.enableGoogleAIStudio)")
    }
    
    // MARK: - Connection Testing
    
    func testConnection() async -> Bool {
        guard !apiKey.isEmpty else {
            logger.error("GoogleAIStudioService: API key not set")
            return false
        }
        
        do {
            let testPrompt = "Hello, this is a test message. Please respond with 'Test successful'."
            let response = try await generateContent(prompt: testPrompt, useStructuredOutput: false)
            let success = response.contains("Test successful") || response.contains("test successful")
            logger.info("GoogleAIStudioService: Connection test \(success ? "successful" : "failed")")
            return success
        } catch {
            logger.error("GoogleAIStudioService: Connection test failed - \(error)")
            return false
        }
    }
    
    // MARK: - Content Generation
    
    func generateContent(prompt: String, useStructuredOutput: Bool = true) async throws -> String {
        guard !apiKey.isEmpty else {
            throw SummarizationError.aiServiceUnavailable(service: "Google AI Studio")
        }
        
        let url = URL(string: "\(baseURL)/models/\(selectedModel):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        if useStructuredOutput {
            request.httpBody = try createStructuredRequest(prompt: prompt)
        } else {
            request.httpBody = try createSimpleRequest(prompt: prompt)
        }
        
        // Create a URLSession with timeout configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60.0
        config.timeoutIntervalForResource = 120.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummarizationError.networkError(underlying: NSError(domain: "GoogleAIStudio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }
        
        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("GoogleAIStudioService: API error - \(httpResponse.statusCode): \(errorMessage)")
            throw SummarizationError.networkError(underlying: NSError(domain: "GoogleAIStudio", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(errorMessage)"]))
        }
        
        if useStructuredOutput {
            return try parseStructuredResponse(data: data)
        } else {
            return try parseSimpleResponse(data: data)
        }
    }
    
    // MARK: - Request Creation
    
    private func createStructuredRequest(prompt: String) throws -> Data {
        // Create schema manually as JSON to avoid recursive struct issues
        let schemaDict: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "A concise summary of the main content"
                ],
                "tasks": [
                    "type": "array",
                    "description": "Extracted actionable tasks",
                    "items": [
                        "type": "string"
                    ],
                    "maxItems": 10
                ],
                "reminders": [
                    "type": "array",
                    "description": "Extracted reminders and time-sensitive items",
                    "items": [
                        "type": "string"
                    ],
                    "maxItems": 10
                ],
                "titles": [
                    "type": "array",
                    "description": "Suggested titles for the content",
                    "items": [
                        "type": "string"
                    ],
                    "maxItems": 5
                ],
                "contentType": [
                    "type": "string",
                    "description": "Classification of content type (meeting, interview, lecture, etc.)"
                ]
            ],
            "required": ["summary", "tasks", "reminders", "titles", "contentType"],
            "propertyOrdering": ["summary", "tasks", "reminders", "titles", "contentType"]
        ]
        
        // Create a custom GenerationConfig that accepts JSON data
        let requestDict: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "text": createStructuredPrompt(prompt)
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": schemaDict,
                "temperature": temperature,
                "maxOutputTokens": maxTokens
            ]
        ]
        
        return try JSONSerialization.data(withJSONObject: requestDict)
    }
    
    private func createSimpleRequest(prompt: String) throws -> Data {
        let request = GeminiRequest(
            contents: [Content(parts: [Part(text: prompt)])],
            generationConfig: GenerationConfig(
                responseMimeType: "text/plain",
                responseSchema: Schema(
                    type: "STRING",
                    properties: [:],
                    required: [],
                    propertyOrdering: []
                ),
                temperature: temperature,
                maxOutputTokens: maxTokens
            )
        )
        
        return try JSONEncoder().encode(request)
    }
    
    private func createStructuredPrompt(_ text: String) -> String {
        return """
        Analyze the following text and extract key information in a structured format:
        
        \(text)
        
        Please provide:
        1. A comprehensive summary using proper Markdown formatting:
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
        
        4. Suggested titles that capture the main topic or theme
        
        5. The content type classification (meeting, interview, lecture, conversation, presentation, or general)
        
        Format your response as a JSON object with the following structure:
        {
          "summary": "detailed markdown-formatted summary of the content",
          "tasks": ["personal task1", "personal task2"],
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
    
    // MARK: - Response Parsing
    
    private func parseStructuredResponse(data: Data) throws -> String {
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        
        guard let candidate = response.candidates.first,
              let textPart = candidate.content.parts.first else {
            throw SummarizationError.processingFailed(reason: "No response content")
        }
        
        logger.info("GoogleAIStudioService: Raw response length: \(textPart.text.count) characters")
        logger.info("GoogleAIStudioService: Raw response preview: \(textPart.text.prefix(200))...")
        
        // Try to parse as JSON first
        if let jsonData = textPart.text.data(using: .utf8) {
            do {
                let summaryResponse = try JSONDecoder().decode(SummaryResponse.self, from: jsonData)
                logger.info("GoogleAIStudioService: Successfully parsed JSON response")
                return formatStructuredResponse(summaryResponse)
            } catch {
                logger.warning("GoogleAIStudioService: Failed to parse JSON response: \(error)")
                logger.warning("GoogleAIStudioService: Raw response: \(textPart.text)")
                
                // Check if the response is truncated
                if textPart.text.contains("\"summary\"") && !textPart.text.hasSuffix("}") {
                    logger.error("GoogleAIStudioService: Response appears to be truncated")
                    
                    // Try to extract partial information from truncated JSON
                    if let partialResponse = extractPartialResponse(from: textPart.text) {
                        logger.info("GoogleAIStudioService: Successfully extracted partial response")
                        return formatStructuredResponse(partialResponse)
                    }
                    
                    throw SummarizationError.processingFailed(reason: "Response was truncated by API")
                }
                
                return textPart.text
            }
        }
        
        return textPart.text
    }
    
    private func parseSimpleResponse(data: Data) throws -> String {
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
        
        guard let candidate = response.candidates.first,
              let textPart = candidate.content.parts.first else {
            throw SummarizationError.processingFailed(reason: "No response content")
        }
        
        return textPart.text
    }
    
    private func formatStructuredResponse(_ response: SummaryResponse) -> String {
        var formatted = "SUMMARY:\n\(response.summary)\n\n"
        
        if !response.tasks.isEmpty {
            formatted += "TASKS:\n"
            for task in response.tasks {
                formatted += "• \(task)\n"
            }
            formatted += "\n"
        }
        
        if !response.reminders.isEmpty {
            formatted += "REMINDERS:\n"
            for reminder in response.reminders {
                formatted += "• \(reminder)\n"
            }
            formatted += "\n"
        }
        
        if !response.titles.isEmpty {
            formatted += "SUGGESTED TITLES:\n"
            for title in response.titles {
                formatted += "• \(title)\n"
            }
            formatted += "\n"
        }
        
        formatted += "CONTENT TYPE: \(response.contentType)"
        
        return formatted
    }
    
    // MARK: - Partial Response Extraction
    
    private func extractPartialResponse(from truncatedJSON: String) -> SummaryResponse? {
        logger.info("GoogleAIStudioService: Attempting to extract partial response from truncated JSON")
        
        // Try to find and extract the summary field
        var summary = ""
        var tasks: [String] = []
        var reminders: [String] = []
        var titles: [String] = []
        var contentType = "general"
        
        // Extract summary using regex
        if let summaryMatch = truncatedJSON.range(of: "\"summary\":\\s*\"([^\"]*)\"", options: .regularExpression) {
            let summaryStart = truncatedJSON.index(summaryMatch.lowerBound, offsetBy: 11) // Skip "summary":"
            let summaryEnd = truncatedJSON.index(summaryStart, offsetBy: 1) // Skip the opening quote
            if let closingQuote = truncatedJSON[summaryEnd...].firstIndex(of: "\"") {
                summary = String(truncatedJSON[summaryEnd..<closingQuote])
            }
        }
        
        // Extract tasks using regex
        if let tasksMatch = truncatedJSON.range(of: "\"tasks\":\\s*\\[([^\\]]*)\\]", options: .regularExpression) {
            let tasksContent = String(truncatedJSON[tasksMatch])
            tasks = extractArrayItems(from: tasksContent)
        }
        
        // Extract reminders using regex
        if let remindersMatch = truncatedJSON.range(of: "\"reminders\":\\s*\\[([^\\]]*)\\]", options: .regularExpression) {
            let remindersContent = String(truncatedJSON[remindersMatch])
            reminders = extractArrayItems(from: remindersContent)
        }
        
        // Extract titles using regex
        if let titlesMatch = truncatedJSON.range(of: "\"titles\":\\s*\\[([^\\]]*)\\]", options: .regularExpression) {
            let titlesContent = String(truncatedJSON[titlesMatch])
            titles = extractArrayItems(from: titlesContent)
        }
        
        // Extract content type using regex
        if let contentTypeMatch = truncatedJSON.range(of: "\"contentType\":\\s*\"([^\"]*)\"", options: .regularExpression) {
            let contentTypeStart = truncatedJSON.index(contentTypeMatch.lowerBound, offsetBy: 14) // Skip "contentType":"
            let contentTypeEnd = truncatedJSON.index(contentTypeStart, offsetBy: 1) // Skip the opening quote
            if let closingQuote = truncatedJSON[contentTypeEnd...].firstIndex(of: "\"") {
                contentType = String(truncatedJSON[contentTypeEnd..<closingQuote])
            }
        }
        
        // Only return if we have at least a summary
        if !summary.isEmpty {
            logger.info("GoogleAIStudioService: Extracted partial response - Summary: \(summary.count) chars, Tasks: \(tasks.count), Reminders: \(reminders.count), Titles: \(titles.count)")
            return SummaryResponse(
                summary: summary,
                tasks: tasks,
                reminders: reminders,
                titles: titles,
                contentType: contentType
            )
        }
        
        return nil
    }
    
    private func extractArrayItems(from arrayString: String) -> [String] {
        var items: [String] = []
        
        // Find all quoted strings in the array
        let pattern = "\"([^\"]*)\""
        let regex = try? NSRegularExpression(pattern: pattern)
        
        if let matches = regex?.matches(in: arrayString, range: NSRange(arrayString.startIndex..., in: arrayString)) {
            for match in matches {
                if let range = Range(match.range(at: 1), in: arrayString) {
                    let item = String(arrayString[range])
                    if !item.isEmpty {
                        items.append(item)
                    }
                }
            }
        }
        
        return items
    }
    
    // MARK: - Title Extraction
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        print("🤖 GoogleAIStudioService: Starting title extraction")
        
        // Use the existing generateContent method with structured output
        // This is more cost-effective than making separate calls
        let response = try await generateContent(prompt: text, useStructuredOutput: true)
        
        // Parse the structured response to extract titles
        // The structured response includes summary, tasks, reminders, and titles
        let lines = response.components(separatedBy: .newlines)
        var titles: [TitleItem] = []
        
        for line in lines {
            if line.contains("SUGGESTED TITLES:") {
                // Extract titles from the structured response
                let titleLines = lines.dropFirst(lines.firstIndex(of: line) ?? 0 + 1)
                    .prefix(while: { !$0.contains("CONTENT TYPE:") })
                
                for titleLine in titleLines {
                    let cleanedLine = titleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanedLine.hasPrefix("• ") && cleanedLine.count > 3 {
                        let titleText = String(cleanedLine.dropFirst(2))
                        let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(titleText)
                        if cleanedTitle != "Untitled Conversation" {
                            titles.append(TitleItem(
                                text: cleanedTitle,
                                confidence: 0.8,
                                category: .general
                            ))
                        }
                    }
                }
                break
            }
        }
        
        return titles.isEmpty ? [] : titles
    }
    
    private func parseTitlesFromJSON(_ jsonString: String) throws -> [TitleItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct TitleResponse: Codable {
            let text: String
            let category: String?
            let confidence: Double?
        }
        
        struct TitlesResponse: Codable {
            let titles: [TitleResponse]
        }
        
        do {
            let response = try JSONDecoder().decode(TitlesResponse.self, from: data)
            
            return response.titles.map { titleResponse in
                let category = TitleItem.TitleCategory(rawValue: titleResponse.category?.lowercased() ?? "general") ?? .general
                return TitleItem(
                    text: titleResponse.text,
                    confidence: titleResponse.confidence ?? 0.8,
                    category: category
                )
            }
        } catch {
            // Try parsing as a simple array
            do {
                let titles = try JSONDecoder().decode([TitleResponse].self, from: data)
                return titles.map { titleResponse in
                    let category = TitleItem.TitleCategory(rawValue: titleResponse.category?.lowercased() ?? "general") ?? .general
                    return TitleItem(
                        text: titleResponse.text,
                        confidence: titleResponse.confidence ?? 0.8,
                        category: category
                    )
                }
            } catch {
                throw SummarizationError.aiServiceUnavailable(service: "Failed to parse titles JSON: \(error.localizedDescription)")
            }
        }
    }
    
    private func extractJSONFromResponse(_ response: String) -> String {
        // Remove markdown code blocks if present
        var cleaned = response
        
        if cleaned.contains("```json") {
            if let start = cleaned.range(of: "```json") {
                cleaned = String(cleaned[start.upperBound...])
            }
            if let end = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<end.lowerBound])
            }
        } else if cleaned.contains("```") {
            if let start = cleaned.range(of: "```") {
                cleaned = String(cleaned[start.upperBound...])
            }
            if let end = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<end.lowerBound])
            }
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Model Loading
    
    func loadAvailableModels() async throws -> [String] {
        // Return only the two specific Gemini models
        return [
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite"
        ]
    }
} 