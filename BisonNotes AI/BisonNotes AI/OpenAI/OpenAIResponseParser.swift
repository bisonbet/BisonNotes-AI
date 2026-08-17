//
//  ChatCompletionResponseParser.swift
//  Audio Journal
//
//  Chat-completion response parsing with standardized title cleaning
//

import Foundation

// MARK: - Chat Completion Response Parser

class ChatCompletionResponseParser {

    private struct CompleteResponse: Codable {
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

    private struct WrappedResponse: Codable {
        let json: CompleteResponse
    }

    // MARK: - Complete Response Parsing

    static func parseCompleteResponseFromJSON(_ jsonString: String) throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        let cleanedJSON = extractJSONFromResponse(jsonString)

        guard !cleanedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AppLog.shared.networking("Empty JSON response received from compatible API", level: .error)
            throw SummarizationError.aiServiceUnavailable(service: "Compatible API returned empty response")
        }

        guard cleanedJSON.data(using: .utf8) != nil else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }

        do {
            let response = try decodeCompleteResponse(from: cleanedJSON)

            let tasks = response.tasks.map { taskResponse in
                TaskItem(
                    text: RecordingNameGenerator.cleanAIOutput(normalizeModelText(taskResponse.text)),
                    priority: TaskItem.Priority(rawValue: taskResponse.priority?.lowercased() ?? "medium") ?? .medium,
                    timeReference: taskResponse.timeReference.map(normalizeModelText),
                    category: TaskItem.TaskCategory(rawValue: taskResponse.category?.lowercased() ?? "general") ?? .general,
                    confidence: taskResponse.confidence ?? 0.8
                )
            }

            let reminders = response.reminders.map { reminderResponse in
                let urgency = ReminderItem.Urgency(rawValue: reminderResponse.urgency?.lowercased() ?? "later") ?? .later
                let cleanedText = RecordingNameGenerator.cleanAIOutput(normalizeModelText(reminderResponse.text))

                // Use smart fallback: if AI didn't provide time reference, extract from reminder text
                let timeRef: ReminderItem.TimeReference
                if let aiTimeRef = reminderResponse.timeReference, !aiTimeRef.isEmpty && aiTimeRef != "No time specified" {
                    timeRef = ReminderItem.TimeReference(originalText: normalizeModelText(aiTimeRef))
                } else {
                    timeRef = ReminderItem.TimeReference.fromReminderText(cleanedText)
                }

                return ReminderItem(
                    text: cleanedText,
                    timeReference: timeRef,
                    urgency: urgency,
                    confidence: reminderResponse.confidence ?? 0.8
                )
            }

            let titles = response.titles.map { titleResponse in
                let category = TitleItem.TitleCategory(rawValue: titleResponse.category?.lowercased() ?? "general") ?? .general
                // Apply standardized title cleaning
                let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(
                    normalizeModelText(titleResponse.text)
                )
                return TitleItem(
                    text: cleanedTitle,
                    confidence: titleResponse.confidence ?? 0.8,
                    category: category
                )
            }

            return (normalizeModelText(response.summary), tasks, reminders, titles)
        } catch {
            AppLog.shared.networking("JSON parsing error for complete response: \(error)", level: .error)

            if cleanedJSON == "{}" {
                AppLog.shared.networking("Compatible API returned empty JSON object - check credentials and model configuration", level: .error)
                throw SummarizationError.aiServiceUnavailable(service: "Compatible API returned empty JSON - check credentials and model configuration")
            }

            // Complete responses are a strict structured-output contract. Never
            // turn malformed JSON into line-based tasks or reminders: doing so
            // can persist JSON keys and summary text as user data. SummaryManager
            // owns the bounded retry when this error is thrown.
            AppLog.shared.networking(
                "Compatible API returned invalid structured response; discarding it instead of extracting metadata",
                level: .error
            )
            throw SummarizationError.aiServiceUnavailable(
                service: "Compatible API returned invalid structured response"
            )
        }
    }

    /// Decodes the complete structured response and makes one narrow recovery
    /// attempt for models that emit an invalid backslash escape inside a JSON
    /// string (for example `\A`). Other malformed JSON remains a hard failure.
    private static func decodeCompleteResponse(from json: String) throws -> CompleteResponse {
        guard let data = json.data(using: .utf8) else {
            throw SummarizationError.aiServiceUnavailable(service: "Invalid JSON data")
        }

        do {
            return try decodeCompleteResponsePayload(from: data)
        } catch {
            guard let repairedJSON = repairMalformedJSONEscapes(in: json),
                  let repairedData = repairedJSON.data(using: .utf8) else {
                throw error
            }

            AppLog.shared.networking(
                "Repairing invalid JSON escape sequences in complete response",
                level: .debug
            )
            return try decodeCompleteResponsePayload(from: repairedData)
        }
    }

    private static func decodeCompleteResponsePayload(from data: Data) throws -> CompleteResponse {
        // Some gateways wrap tool-shaped JSON in {"json": {...}} while standard
        // chat-completion endpoints return the complete object directly.
        do {
            let wrapped = try JSONDecoder().decode(WrappedResponse.self, from: data)
            AppLog.shared.networking("Parsed wrapped JSON response", level: .debug)
            return wrapped.json
        } catch {
            let response = try JSONDecoder().decode(CompleteResponse.self, from: data)
            AppLog.shared.networking("Parsed standard JSON response", level: .debug)
            return response
        }
    }

    /// Removes only backslashes that are illegal JSON escapes while preserving
    /// all valid JSON escapes. This lets us recover a usable response from a
    /// model that emitted `\A` instead of rejecting otherwise complete data.
    private static func repairMalformedJSONEscapes(in json: String) -> String? {
        var repaired = String()
        repaired.reserveCapacity(json.count)

        var inString = false
        var changed = false
        var index = json.startIndex

        while index < json.endIndex {
            let character = json[index]

            if character == "\"" {
                repaired.append(character)
                inString.toggle()
                index = json.index(after: index)
                continue
            }

            guard inString, character == "\\" else {
                repaired.append(character)
                index = json.index(after: index)
                continue
            }

            let nextIndex = json.index(after: index)
            guard nextIndex < json.endIndex else {
                changed = true
                index = nextIndex
                continue
            }

            let nextCharacter = json[nextIndex]
            if isValidJSONEscapeCharacter(nextCharacter) {
                repaired.append(character)
                repaired.append(nextCharacter)
            } else {
                // The backslash cannot represent a valid JSON escape. Drop
                // only that invalid marker and retain the model's character.
                repaired.append(nextCharacter)
                changed = true
            }
            index = json.index(after: nextIndex)
        }

        return changed ? repaired : nil
    }

    private static func isValidJSONEscapeCharacter(_ character: Character) -> Bool {
        switch character {
        case "\"", "\\", "/", "b", "f", "n", "r", "t", "u":
            return true
        default:
            return false
        }
    }

    /// Normalizes text that was valid JSON but contained a second layer of
    /// escaping, which some compatible gateways return for Markdown strings.
    static func normalizeModelText(_ text: String) -> String {
        var normalized = text
        normalized = normalized.replacingOccurrences(of: "\\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\r", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\t", with: "\t")
        normalized = normalized.replacingOccurrences(of: "\\\"", with: "\"")
        return removeInvalidEscapeMarkers(from: normalized)
    }

    private static func removeInvalidEscapeMarkers(from text: String) -> String {
        var normalized = String()
        normalized.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "\\" else {
                normalized.append(character)
                index = text.index(after: index)
                continue
            }

            let nextIndex = text.index(after: index)
            guard nextIndex < text.endIndex else {
                index = nextIndex
                continue
            }

            let nextCharacter = text[nextIndex]
            if isValidJSONEscapeCharacter(nextCharacter) {
                normalized.append(character)
                index = nextIndex
            } else {
                // Keep the content but remove a stray model-generated escape
                // marker such as the `\A` seen in malformed summaries.
                index = nextIndex
            }
        }

        return normalized
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
                let cleanedTitle = RecordingNameGenerator.cleanStandardizedTitleResponse(
                    normalizeModelText(titleResponse.text)
                )
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
                    text: RecordingNameGenerator.cleanAIOutput(normalizeModelText(taskResponse.text)),
                    priority: TaskItem.Priority(rawValue: taskResponse.priority?.lowercased() ?? "medium") ?? .medium,
                    timeReference: taskResponse.timeReference.map(normalizeModelText),
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
                let cleanedText = RecordingNameGenerator.cleanAIOutput(normalizeModelText(reminderResponse.text))

                // Use smart fallback: if AI didn't provide time reference, extract from reminder text
                let timeRef: ReminderItem.TimeReference
                if let aiTimeRef = reminderResponse.timeReference, !aiTimeRef.isEmpty && aiTimeRef != "No time specified" {
                    timeRef = ReminderItem.TimeReference(originalText: normalizeModelText(aiTimeRef))
                } else {
                    timeRef = ReminderItem.TimeReference.fromReminderText(cleanedText)
                }

                return ReminderItem(
                    text: cleanedText,
                    timeReference: timeRef,
                    urgency: urgency,
                    confidence: reminderResponse.confidence ?? 0.8
                )
            }
        } catch {
            throw SummarizationError.aiServiceUnavailable(service: "Failed to parse reminders JSON: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    private static func extractJSONFromResponse(_ response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 1: Remove markdown code blocks.
        if let start = cleaned.range(of: "```json", options: .caseInsensitive) {
            cleaned = String(cleaned[start.upperBound...])
            if let end = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<end.lowerBound])
            }
        } else if let start = cleaned.range(of: "```") {
            cleaned = String(cleaned[start.upperBound...])
            if let end = cleaned.range(of: "```") {
                cleaned = String(cleaned[..<end.lowerBound])
            }
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 2: Try to extract JSON from text that might have explanations
        // Some models output: "Here's the JSON: {..." or "The response is: {..."
        if !cleaned.hasPrefix("{") && !cleaned.hasPrefix("[") {
            // Look for the first { or [ and take everything from there
            if let jsonStart = cleaned.firstIndex(where: { $0 == "{" || $0 == "[" }) {
                cleaned = String(cleaned[jsonStart...])
            }
        }

        // Step 3: Find the matching closing delimiter while ignoring braces,
        // brackets, and quotes inside JSON strings.
        if let firstCharacter = cleaned.first,
           firstCharacter == "{" || firstCharacter == "[" {
            var delimiters: [Character] = []
            var isInsideString = false
            var index = cleaned.startIndex
            var endIndex: String.Index?

            while index < cleaned.endIndex {
                let character = cleaned[index]

                if character == "\"" {
                    let previousIndex = index > cleaned.startIndex
                        ? cleaned.index(before: index)
                        : nil
                    let isEscaped = previousIndex.map { cleaned[$0] == "\\" } ?? false
                    if !isEscaped {
                        isInsideString.toggle()
                    }
                } else if !isInsideString {
                    if character == "{" || character == "[" {
                        delimiters.append(character)
                    } else if character == "}" || character == "]" {
                        let expectedOpening: Character = character == "}" ? "{" : "["
                        if delimiters.last == expectedOpening {
                            delimiters.removeLast()
                            if delimiters.isEmpty {
                                endIndex = cleaned.index(after: index)
                                break
                            }
                        }
                    }
                }

                index = cleaned.index(after: index)
            }

            if let endIndex {
                cleaned = String(cleaned[..<endIndex])
            }
        }

        AppLog.shared.networking("Extracted JSON: \(cleaned.count) chars", level: .debug)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
