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

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let prompt = """
        Summarize the following transcript in 4-7 concise bullet points. Keep factual details, decisions, action owners, and deadlines if present. Transcript:\n\n\(text)
        """
        return try await askModel(prompt)
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        let result = try await processComplete(text: text)
        return result.tasks
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let result = try await processComplete(text: text)
        return result.reminders
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        let result = try await processComplete(text: text)
        return result.titles
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        let lowered = text.lowercased()
        if lowered.contains("meeting") || lowered.contains("agenda") {
            return .meeting
        }
        if lowered.contains("task") || lowered.contains("todo") {
            return .technical
        }
        return .general
    }

    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let summary = try await generateSummary(from: text, contentType: .general)
        let contentType = try await classifyContent(text)

        return (
            summary: summary,
            tasks: [],
            reminders: [],
            titles: [TitleItem(text: summaryTitle(from: summary), confidence: 0.7, category: .general)],
            contentType: contentType
        )
    }

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
}
