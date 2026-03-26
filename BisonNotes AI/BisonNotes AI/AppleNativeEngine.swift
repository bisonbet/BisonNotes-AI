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
        let chunks = chunkText(text)

        if chunks.count == 1 {
            let prompt = """
            Summarize the following transcript in 4-7 concise bullet points. Keep factual details, decisions, action owners, and deadlines if present. Transcript:\n\n\(chunks[0])
            """
            return try await askModelWithFallback(prompt)
        }

        // Multi-chunk: summarize each chunk then combine into a final summary.
        AppLogger.shared.info(
            "[AppleNativeEngine] Transcript too long – processing in \(chunks.count) chunks",
            category: "AppleNativeEngine"
        )
        var chunkSummaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let chunkPrompt = """
            This is part \(index + 1) of \(chunks.count) of a longer transcript. \
            Summarize this section in 2-4 concise bullet points covering key facts, decisions, and action items:

            \(chunk)
            """
            let chunkSummary = try await askModelWithFallback(chunkPrompt)
            chunkSummaries.append(chunkSummary)
        }

        let combined = chunkSummaries.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")

        let finalPrompt = """
        The following are summaries of sequential sections of a transcript. \
        Combine them into a single cohesive summary of 4-7 bullet points, \
        preserving all key decisions, action items, and deadlines:

        \(combined)
        """
        return try await askModelWithFallback(finalPrompt)
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        let prompt = """
        Extract personal and actionable tasks from the following text. \
        Focus only on tasks that require action by the speaker. \
        Return each task on its own line starting with a bullet (- or •). \
        Avoid tasks about news, public figures, or world events.

        Text:
        \(truncateText(text))
        """
        let response = try await askModelWithFallback(prompt)
        return parseTasksFromResponse(response)
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let prompt = """
        Extract personal time-sensitive reminders from the following text. \
        Focus on appointments, deadlines, or commitments that affect the speaker. \
        Return each reminder on its own line starting with a bullet (- or •). \
        Avoid reminders about news, public events, or world happenings.

        Text:
        \(truncateText(text))
        """
        let response = try await askModelWithFallback(prompt)
        return parseRemindersFromResponse(response)
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        let prompt = """
        Suggest 3 short, descriptive titles for the following content. \
        Return each title on its own line starting with a bullet (- or •).

        Content:
        \(truncateText(text))
        """
        let response = try await askModelWithFallback(prompt)
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

    /// Approximate character budget for user-supplied text.
    /// Apple Foundation Models cap at 4,096 tokens; at ~4 chars/token that is
    /// ~16 384 characters total.  We reserve ~2 000 chars for prompt instructions
    /// and the model's response, leaving ~14 000 for the transcript/text.
    private static let maxTextCharacters = 14_000

    /// Maximum characters per chunk when splitting long transcripts.
    private static let chunkCharacters = 12_000

    /// Truncate `text` so the combined prompt stays inside the context window.
    /// Keeps the first 85 % and the last 15 % so the opening topic and the
    /// closing remarks are both represented.
    private func truncateText(_ text: String) -> String {
        guard text.count > Self.maxTextCharacters else { return text }
        let keepStart = Int(Double(Self.maxTextCharacters) * 0.85)
        let keepEnd   = Self.maxTextCharacters - keepStart
        return String(text.prefix(keepStart))
            + "\n\n[…transcript truncated to fit context window…]\n\n"
            + String(text.suffix(keepEnd))
    }

    /// Split `text` into overlapping chunks that each fit comfortably inside
    /// the context window.  A 500-character overlap ensures continuity.
    private func chunkText(_ text: String) -> [String] {
        guard text.count > Self.chunkCharacters else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        let overlap = 500
        while start < text.endIndex {
            let end = text.index(start, offsetBy: Self.chunkCharacters, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            guard end < text.endIndex else { break }
            // Step forward by (chunk - overlap) so consecutive chunks share context
            let nextOffset = Self.chunkCharacters - overlap
            start = text.index(start, offsetBy: nextOffset, limitedBy: text.endIndex) ?? text.endIndex
        }
        return chunks
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
            guard SystemLanguageModel.default.availability == .available else {
                throw SummarizationError.aiServiceUnavailable(service: "Apple Native")
            }
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !output.isEmpty else {
                throw SummarizationError.processingFailed(reason: "Apple Foundation Models returned an empty response")
            }
            return output
        }
        throw SummarizationError.aiServiceUnavailable(service: "Apple Native")
        #else
        throw SummarizationError.aiServiceUnavailable(service: "Apple Native")
        #endif
    }

    /// Ask the model with automatic context-window handling.
    /// For prompts that are too large the text portion is first truncated;
    /// if the error persists a hard truncation of the entire prompt is applied.
    private func askModelWithFallback(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            do {
                return try await askModel(prompt)
            } catch {
                let isContextError = error.localizedDescription.lowercased().contains("context")
                    || String(describing: error).contains("exceededContextWindowSize")
                guard isContextError else { throw error }

                AppLogger.shared.warning(
                    "[AppleNativeEngine] Context window exceeded – retrying with truncated prompt",
                    category: "AppleNativeEngine"
                )
                // Hard-truncate the entire prompt to the safe budget and retry once.
                let safePrompt = String(prompt.prefix(Self.maxTextCharacters + 500))
                return try await askModel(safePrompt)
            }
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
