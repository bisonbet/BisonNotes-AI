import Foundation

// MARK: - Connection Testing Protocol

protocol ConnectionTestable {
    func testConnection() async -> Bool
}

// MARK: - Summarization Engine Protocol

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
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)
}

extension SummarizationEngine {
    var metadataName: String {
        return name
    }
    
    var engineType: String {
        return "AI Assistant"
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

// MARK: - Placeholder Engine for Future Implementation

class PlaceholderEngine: SummarizationEngine {
    let name: String
    let description: String
    let isAvailable: Bool = false
    let version: String = "1.0"
    
    init(name: String, description: String) {
        self.name = name
        self.description = description
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
}
