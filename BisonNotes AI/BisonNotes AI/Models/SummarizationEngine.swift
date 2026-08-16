import Foundation

// MARK: - Connection Testing Protocol

protocol ConnectionTestable {
    func testConnection() async -> Bool
}

// MARK: - Summarization Engine Protocol

struct SummarizationResult: Sendable {
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    let titles: [TitleItem]
    let contentType: ContentType
}

protocol SummarizationEngine {
    var name: String { get }
    var engineType: String { get }
    var description: String { get }
    var isAvailable: Bool { get }
    var version: String { get }

    /// The name to display in metadata (e.g., specific model name)
    /// Defaults to `name` if not implemented
    var metadataName: String { get }

    func generateSummary(from text: String, contentType: ContentType) async throws -> String
    func extractTasks(from text: String) async throws -> [TaskItem]
    func extractReminders(from text: String) async throws -> [ReminderItem]
    func extractTitles(from text: String) async throws -> [TitleItem]
    func classifyContent(_ text: String) async throws -> ContentType

    // Optional: Full processing in one call for efficiency
    func processComplete(text: String) async throws -> SummarizationResult
}

extension SummarizationEngine {
    var metadataName: String {
        return name
    }

    var engineType: String {
        return "AI Assistant"
    }
}

// MARK: - Summary Detail Preference

/// Controls how much narrative detail the summarization engines should retain.
///
/// The preference is intentionally shared by every engine instead of being part
/// of a provider-specific configuration. This keeps a user's choice consistent
/// when they switch between cloud, self-hosted, and on-device models.
enum SummaryDetailLevel: Int, CaseIterable, Identifiable, Equatable, Sendable {
    case concise = 0
    case balanced = 1
    case detailed = 2

    static let storageKey = "summaryDetailLevel"
    static let defaultLevel: SummaryDetailLevel = .balanced

    var id: Int { rawValue }

    /// Reads the preference at request time so changes apply to the next summary
    /// without requiring an engine or service to be recreated.
    static var current: SummaryDetailLevel {
        guard let storedValue = UserDefaults.standard.object(forKey: storageKey) as? Int,
              let level = SummaryDetailLevel(rawValue: storedValue) else {
            return defaultLevel
        }
        return level
    }

    var displayName: String {
        switch self {
        case .concise:
            return "Brief"
        case .balanced:
            return "Balanced"
        case .detailed:
            return "Detailed"
        }
    }

    var userDescription: String {
        switch self {
        case .concise:
            return "Key points, decisions, and deadlines in a compact summary."
        case .balanced:
            return "A practical mix of the main ideas and supporting context."
        case .detailed:
            return "More facts, context, nuance, and conclusions from the transcript."
        }
    }

    private var targetPercentageDescription: String {
        switch self {
        case .concise:
            return "5–10%"
        case .balanced:
            return "10–15%"
        case .detailed:
            return "15–25%"
        }
    }

    private var targetRatios: (lower: Double, upper: Double) {
        switch self {
        case .concise:
            return (0.05, 0.10)
        case .balanced:
            return (0.10, 0.15)
        case .detailed:
            return (0.15, 0.25)
        }
    }

    /// Returns a practical word range for prompt-driven engines and chunk
    /// consolidation. The model may use fewer words for a short transcript, but
    /// should not pad the result just to hit the range.
    func targetWordRange(for sourceWordCount: Int) -> ClosedRange<Int> {
        let sourceWordCount = max(sourceWordCount, 1)
        let ratios = targetRatios
        let lowerBound = max(40, Int(Double(sourceWordCount) * ratios.lower))
        let upperBound = max(lowerBound + 20, Int(Double(sourceWordCount) * ratios.upper))
        return lowerBound...upperBound
    }

    /// Prompt text shared by providers that construct their own request format.
    /// Tasks, reminders, titles, and content type remain factual metadata; this
    /// setting changes only the narrative summary field.
    func promptInstructions(forSourceWordCount sourceWordCount: Int? = nil) -> String {
        let targetDescription: String
        if let sourceWordCount {
            let targetRange = targetWordRange(for: sourceWordCount)
            targetDescription = "Target approximately \(targetRange.lowerBound)-\(targetRange.upperBound) "
                + "words for the narrative summary when the transcript is long enough."
        } else {
            targetDescription = "Use this detail level consistently; keep the summary proportionate to the "
                + "transcript rather than padding it to meet a fixed length."
        }

        let focus: String
        switch self {
        case .concise:
            focus = "Prioritize the main topic, decisions, action items, deadlines, and essential supporting "
                + "facts. Omit repetition and minor context."
        case .balanced:
            focus = "Include the main ideas plus the context, facts, dates, decisions, and conclusions "
                + "needed to understand them."
        case .detailed:
            focus = "Capture meaningful context, supporting facts, nuance, examples, names, dates, rationale, "
                + "and conclusions without repeating the transcript."
        }

        return """
        **Summary Detail: \(displayName) (\(targetPercentageDescription) of the source when practical)**
        - \(targetDescription)
        - \(focus)
        - Use clear Markdown sections and bullets where they improve readability.
        - Do not invent, speculate, or pad the summary; preserve names, numbers, dates, quotes, and decisions.
        - Apply this length preference only to the narrative `summary` field or Summary section.
        - Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.
        """
    }

    /// Short description suitable for a structured-output schema field.
    var schemaDescription: String {
        "\(displayName) summary: \(userDescription) "
            + "Target approximately \(targetPercentageDescription) of the source when practical."
    }

    /// The deterministic fallback summary has no model prompt, so it varies the
    /// number of selected high-value sentences using the same preference.
    var basicSentenceLimit: Int {
        switch self {
        case .concise:
            return 2
        case .balanced:
            return 4
        case .detailed:
            return 7
        }
    }
}

// MARK: - Processing Configuration

struct SummarizationConfig {
    let maxSummaryLength: Int
    let maxTasks: Int
    let maxReminders: Int
    let maxTokens: Int
    let minConfidenceThreshold: Double
    let timeoutInterval: TimeInterval
    let enableParallelProcessing: Bool

    static let `default` = SummarizationConfig(
        maxSummaryLength: 500,
        maxTasks: 5,
        maxReminders: 5,
        maxTokens: 8192,
        minConfidenceThreshold: 0.8,
        timeoutInterval: 180.0,
        enableParallelProcessing: true
    )

    static let conservative = SummarizationConfig(
        maxSummaryLength: 300,
        maxTasks: 5,
        maxReminders: 5,
        maxTokens: 4096,
        minConfidenceThreshold: 0.5,
        timeoutInterval: 180.0,
        enableParallelProcessing: false
    )

    static let onDeviceUnlimited = SummarizationConfig(
        maxSummaryLength: 500,
        maxTasks: 5,
        maxReminders: 5,
        maxTokens: 8192,
        minConfidenceThreshold: 0.8,
        timeoutInterval: .infinity,
        enableParallelProcessing: false
    )
}

// MARK: - Global Timeout Configuration

struct SummarizationTimeouts {
    static let storageKey = "summarizationTimeout"
    static let defaultTimeout: TimeInterval = 180.0
    static let minimumTimeout: TimeInterval = 30.0
    static let maximumTimeout: TimeInterval = 600.0
    // NOTE: The timeout value is read when configs are created. Updates apply to new requests,
    // while in-flight operations continue with their originally captured timeout.

    static func current() -> TimeInterval {
        let storedValue = UserDefaults.standard.double(forKey: storageKey)
        guard storedValue > 0 else { return defaultTimeout }
        return clamp(storedValue)
    }

    static func clamp(_ value: TimeInterval) -> TimeInterval {
        return min(max(value, minimumTimeout), maximumTimeout)
    }
}

// MARK: - Timeout Helpers

/// Run an async operation with a timeout, cancelling all tasks when the first completes.
///
/// - Parameters:
///   - seconds: Maximum duration to wait before throwing a timeout error.
///   - timeoutError: Error to throw when the timeout elapses.
///   - operation: Async work to perform.
/// - Returns: The value produced by `operation` if it completes before the timeout.
/// - Throws: `timeoutError` when the timeout elapses, or any error thrown by `operation`.
func withTimeout<T>(
    seconds: TimeInterval,
    timeoutError: Error = SummarizationError.processingTimeout,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw timeoutError
        }

        guard let result = try await group.next() else {
            throw SummarizationError.processingTimeout
        }
        group.cancelAll()
        return result
    }
}
