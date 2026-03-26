import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarization engine that uses Apple's on-device Foundation Models runtime.
final class AppleNativeEngine: SummarizationEngine {
    let name: String = "Apple Native"
    let engineType: String = "Apple Native"
    let description: String = "On-device summaries powered by Apple's native Foundation Models framework."
    let version: String = "1.0"

    var metadataName: String { "Apple Foundation Model" }

    /// Static availability check so callers (e.g. AISettingsView) don't need to
    /// instantiate the engine just to ask whether the device supports it.
    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
        #else
        return false
        #endif
    }

    var isAvailable: Bool { AppleNativeEngine.modelAvailable }

    // MARK: - SummarizationEngine

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let prompt = """
        Summarize the following transcript in 4-7 concise bullet points. Keep factual details, decisions, action owners, and deadlines if present. Transcript:\n\n\(text)
        """
        return try await askModel(prompt)
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        let prompt = """
        Extract personal and actionable tasks from the following text. \
        Focus only on tasks that require action by the speaker. \
        Return each task on its own line starting with a bullet (- or •). \
        Avoid tasks about news, public figures, or world events.

        Text:
        \(text)
        """
        let response = try await askModel(prompt)
        return parseTasksFromResponse(response)
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let prompt = """
        Extract personal time-sensitive reminders from the following text. \
        Focus on appointments, deadlines, or commitments that affect the speaker. \
        Return each reminder on its own line starting with a bullet (- or •). \
        Avoid reminders about news, public events, or world happenings.

        Text:
        \(text)
        """
        let response = try await askModel(prompt)
        return parseRemindersFromResponse(response)
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        let prompt = """
        Suggest 3 short, descriptive titles for the following content. \
        Return each title on its own line starting with a bullet (- or •).

        Content:
        \(text)
        """
        let response = try await askModel(prompt)
        return parseTitlesFromResponse(response)
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        let lowered = text.lowercased()
        if lowered.contains("meeting") || lowered.contains("agenda") {
            return .meeting
        }
        if lowered.contains("journal") || lowered.contains("diary") {
            return .personalJournal
        }
        return .general
    }

    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Run all extractions concurrently to minimise total latency.
        async let summaryResult = generateSummary(from: text, contentType: .general)
        async let tasksResult = extractTasks(from: text)
        async let remindersResult = extractReminders(from: text)
        async let contentTypeResult = classifyContent(text)

        let summary = try await summaryResult
        let tasks = try await tasksResult
        let reminders = try await remindersResult
        let contentType = try await contentTypeResult

        let titles = [TitleItem(text: summaryTitle(from: summary), confidence: 0.7, category: .general)]
        return (summary: summary, tasks: tasks, reminders: reminders, titles: titles, contentType: contentType)
    }

    // MARK: - Private helpers

    private func summaryTitle(from summary: String) -> String {
        let cleaned = summary
            .replacingOccurrences(of: "•", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let firstLine = cleaned.components(separatedBy: .newlines).first, !firstLine.isEmpty {
            return String(firstLine.prefix(80))
        }
        return "Summary"
    }

    private func askModel(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                throw SummarizationError.aiServiceUnavailable(service: "Apple Foundation Models are not available on this device")
            }
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !output.isEmpty else {
                throw SummarizationError.emptyResponse
            }
            return output
        }
        throw SummarizationError.aiServiceUnavailable(service: "Apple Native requires iOS/macOS/visionOS 26 or newer")
        #else
        throw SummarizationError.aiServiceUnavailable(service: "FoundationModels framework unavailable in this build")
        #endif
    }

    private func parseTasksFromResponse(_ response: String) -> [TaskItem] {
        response.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { return nil }
            let taskText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !taskText.isEmpty else { return nil }
            return TaskItem(text: taskText, priority: .medium, confidence: 0.8)
        }
    }

    private func parseRemindersFromResponse(_ response: String) -> [ReminderItem] {
        response.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { return nil }
            let reminderText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reminderText.isEmpty else { return nil }
            let timeRef = ReminderItem.TimeReference.fromReminderText(reminderText)
            return ReminderItem(text: reminderText, timeReference: timeRef, urgency: .later, confidence: 0.8)
        }
    }

    private func parseTitlesFromResponse(_ response: String) -> [TitleItem] {
        response.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { return nil }
            let titleText = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !titleText.isEmpty else { return nil }
            return TitleItem(text: titleText, confidence: 0.8, category: .general)
        }
    }
}
