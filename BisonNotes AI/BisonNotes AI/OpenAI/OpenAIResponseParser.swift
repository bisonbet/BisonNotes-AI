//
//  OpenAIResponseParser.swift
//  Audio Journal
//
//  OpenAI response parsing with standardized title cleaning
//

import Foundation

// MARK: - OpenAI Response Parser

class OpenAIResponseParser {
    
    // MARK: - Complete Response Parsing
    
    static func parseCompleteResponseFromJSON(_ jsonString: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct CompleteResponse: Codable {
            let summary: String
            let tasks: [TaskResponse]
            let reminders: [ReminderResponse]
            let titles: [TitleResponse]
            
            struct TaskResponse: Codable {
                let text: String
                let priority: String?
                let category: String?
                let timeReference: String?
                let confidence: Double?
            }
            
            struct ReminderResponse: Codable {
                let text: String
                let urgency: String?
                let timeReference: String?
                let confidence: Double?
            }
            
            struct TitleResponse: Codable {
                let text: String
                let category: String?
                let confidence: Double?
            }
        }
        
        do {
            // Extract JSON from markdown code blocks if present
            let jsonString = extractJSONFromResponse(jsonString)
            let jsonData = jsonString.data(using: .utf8) ?? data
            
            let response = try JSONDecoder().decode(CompleteResponse.self, from: jsonData)
            
            let tasks = response.tasks.map { taskResponse in
                TaskItem(
                    text: taskResponse.text,
                    priority: TaskItem.Priority(rawValue: taskResponse.priority?.lowercased() ?? "medium") ?? .medium,
                    timeReference: taskResponse.timeReference,
                    category: TaskItem.TaskCategory(rawValue: taskResponse.category?.lowercased() ?? "general") ?? .general,
                    confidence: taskResponse.confidence ?? 0.8
                )
            }
            
            let reminders = response.reminders.map { reminderResponse in
                let urgency = ReminderItem.Urgency(rawValue: reminderResponse.urgency?.lowercased() ?? "later") ?? .later
                let timeRef = ReminderItem.TimeReference(originalText: reminderResponse.timeReference ?? "No time specified")
                
                return ReminderItem(
                    text: reminderResponse.text,
                    timeReference: timeRef,
                    urgency: urgency,
                    confidence: reminderResponse.confidence ?? 0.8
                )
            }
            
            let titles = response.titles.map { titleResponse in
                let category = TitleItem.TitleCategory(rawValue: titleResponse.category?.lowercased() ?? "general") ?? .general
                // Apply standardized title cleaning
                let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(titleResponse.text)
                return TitleItem(
                    text: cleanedTitle,
                    confidence: titleResponse.confidence ?? 0.8,
                    category: category
                )
            }
            
            return (response.summary, tasks, reminders, titles)
        } catch {
            print("❌ JSON parsing error for complete response: \(error)")
            print("📝 Raw JSON: \(cleanedJSON)")
            
            // Check if the JSON is empty or malformed
            if cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("⚠️ Empty JSON response received from OpenAI")
                throw SummarizationError.aiServiceUnavailable(service: "OpenAI returned empty response")
            }
            
            if cleanedJSON == "{}" {
                print("⚠️ OpenAI returned empty JSON object - this may indicate an API configuration issue")
                throw SummarizationError.aiServiceUnavailable(service: "OpenAI returned empty JSON - check API key and model configuration")
            }
            
            // Fallback: try to extract information from plain text
            let summary = extractSummaryFromPlainText(jsonString)
            let tasks = extractTasksFromPlainText(jsonString)
            let reminders = extractRemindersFromPlainText(jsonString)
            let titles = extractTitlesFromPlainText(jsonString)
            
            return (summary, tasks, reminders, titles)
        }
    }
    
    // MARK: - Individual Response Parsing
    
    static func parseTitlesFromJSON(_ jsonString: String) throws -> [TitleItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct TitleResponse: Codable {
            let text: String
            let category: String?
            let confidence: Double?
        }
        
        do {
            let titles = try JSONDecoder().decode([TitleResponse].self, from: data)
            return titles.map { titleResponse in
                let category = TitleItem.TitleCategory(rawValue: titleResponse.category?.lowercased() ?? "general") ?? .general
                // Apply standardized title cleaning
                let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(titleResponse.text)
                return TitleItem(
                    text: cleanedTitle,
                    confidence: titleResponse.confidence ?? 0.8,
                    category: category
                )
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to parse titles JSON: \(error.localizedDescription)")
        }
    }
    
    static func parseTasksFromJSON(_ jsonString: String) throws -> [TaskItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct TaskResponse: Codable {
            let text: String
            let priority: String?
            let category: String?
            let timeReference: String?
            let confidence: Double?
        }
        
        do {
            let tasks = try JSONDecoder().decode([TaskResponse].self, from: data)
            return tasks.map { taskResponse in
                TaskItem(
                    text: taskResponse.text,
                    priority: TaskItem.Priority(rawValue: taskResponse.priority?.lowercased() ?? "medium") ?? .medium,
                    timeReference: taskResponse.timeReference,
                    category: TaskItem.TaskCategory(rawValue: taskResponse.category?.lowercased() ?? "general") ?? .general,
                    confidence: taskResponse.confidence ?? 0.8
                )
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to parse tasks JSON: \(error.localizedDescription)")
        }
    }
    
    static func parseRemindersFromJSON(_ jsonString: String) throws -> [ReminderItem] {
        let cleanedJSON = extractJSONFromResponse(jsonString)
        
        guard let data = cleanedJSON.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }
        
        struct ReminderResponse: Codable {
            let text: String
            let urgency: String?
            let timeReference: String?
            let confidence: Double?
        }
        
        do {
            let reminders = try JSONDecoder().decode([ReminderResponse].self, from: data)
            return reminders.map { reminderResponse in
                let urgency = ReminderItem.Urgency(rawValue: reminderResponse.urgency?.lowercased() ?? "later") ?? .later
                let timeRef = ReminderItem.TimeReference(originalText: reminderResponse.timeReference ?? "No time specified")
                
                return ReminderItem(
                    text: reminderResponse.text,
                    timeReference: timeRef,
                    urgency: urgency,
                    confidence: reminderResponse.confidence ?? 0.8
                )
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to parse reminders JSON: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Plain Text Extraction (Fallback)
    
    private static func extractSummaryFromPlainText(_ text: String) -> String {
        // First, try to extract JSON summary field if present
        if let jsonSummary = extractSummaryFromJSON(text) {
            return jsonSummary
        }
        
        // Try to find a summary in the text
        let lines = text.components(separatedBy: .newlines)
        var summaryLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && 
               !trimmed.lowercased().contains("task") &&
               !trimmed.lowercased().contains("reminder") &&
               !trimmed.contains("{") && !trimmed.contains("}") &&
               !trimmed.contains("[") && !trimmed.contains("]") &&
               !trimmed.contains("\"summary\"") && // Skip JSON structure lines
               trimmed.count > 20 {
                summaryLines.append(trimmed)
            }
        }
        
        let summary = summaryLines.joined(separator: "\n\n")
        
        // Add basic markdown formatting to the fallback summary
        if summary.isEmpty {
            return "## Summary\n\n*Unable to generate summary from the provided content.*"
        } else {
            // Add a header and format as markdown
            let formattedSummary = "## Summary\n\n" + summary
                .replacingOccurrences(of: ". ", with: ".\n\n• ")
                .replacingOccurrences(of: "• • ", with: "• ")
            return formattedSummary
        }
    }
    
    private static func extractTasksFromPlainText(_ text: String) -> [TaskItem] {
        let lines = text.components(separatedBy: .newlines)
        var tasks: [TaskItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for task indicators
            if trimmed.lowercased().contains("task") || 
               trimmed.lowercased().contains("todo") ||
               trimmed.lowercased().contains("action") ||
               trimmed.lowercased().contains("need to") ||
               trimmed.lowercased().contains("should") {
                
                // Clean up the task text
                let cleanText = trimmed
                    .replacingOccurrences(of: "Task:", with: "")
                    .replacingOccurrences(of: "TODO:", with: "")
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
    
    private static func extractRemindersFromPlainText(_ text: String) -> [ReminderItem] {
        let lines = text.components(separatedBy: .newlines)
        var reminders: [ReminderItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for reminder indicators
            if trimmed.lowercased().contains("reminder") || 
               trimmed.lowercased().contains("remember") ||
               trimmed.lowercased().contains("don't forget") ||
               trimmed.lowercased().contains("appointment") ||
               trimmed.lowercased().contains("meeting") {
                
                // Clean up the reminder text
                let cleanText = trimmed
                    .replacingOccurrences(of: "Reminder:", with: "")
                    .replacingOccurrences(of: "Remember:", with: "")
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
    
    private static func extractTitlesFromPlainText(_ text: String) -> [TitleItem] {
        let lines = text.components(separatedBy: .newlines)
        var titles: [TitleItem] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for title indicators
            if trimmed.lowercased().contains("title") || 
               trimmed.lowercased().contains("headline") ||
               trimmed.lowercased().contains("topic") ||
               trimmed.lowercased().contains("subject") {
                
                // Clean up the title text
                let cleanText = trimmed
                    .replacingOccurrences(of: "Title:", with: "")
                    .replacingOccurrences(of: "Headline:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !cleanText.isEmpty && cleanText.count > 5 {
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
        
        return titles
    }
    
    // MARK: - Helper Methods
    
    private static func extractJSONFromResponse(_ response: String) -> String {
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
    
    private static func extractSummaryFromJSON(_ text: String) -> String? {
        // Try to extract the summary field from JSON
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for "summary": "..." pattern
            if trimmed.contains("\"summary\"") && trimmed.contains(":") {
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    let afterColon = String(trimmed[trimmed.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    
                    // Remove quotes if present
                    if afterColon.hasPrefix("\"") && afterColon.hasSuffix("\"") {
                        let startIndex = afterColon.index(after: afterColon.startIndex)
                        let endIndex = afterColon.index(before: afterColon.endIndex)
                        return String(afterColon[startIndex..<endIndex])
                    } else if afterColon.hasPrefix("\"") {
                        // Handle multi-line summary
                        let startIndex = afterColon.index(after: afterColon.startIndex)
                        var summaryContent = String(afterColon[startIndex...])
                        
                        // Find the closing quote
                        if let endQuoteIndex = summaryContent.firstIndex(of: "\"") {
                            summaryContent = String(summaryContent[..<endQuoteIndex])
                        }
                        
                        return summaryContent
                    }
                }
            }
        }
        
        return nil
    }
} 