import Foundation

// MARK: - Connection Testing Protocol

protocol ConnectionTestable {
    func testConnection() async -> Bool
}

// MARK: - Summarization Engine Protocol

protocol SummarizationEngine {
    var name: String { get }
    var description: String { get }
    var isAvailable: Bool { get }
    var version: String { get }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String
    func extractTasks(from text: String) async throws -> [TaskItem]
    func extractReminders(from text: String) async throws -> [ReminderItem]
    func extractTitles(from text: String) async throws -> [TitleItem]
    func classifyContent(_ text: String) async throws -> ContentType
    
    // Optional: Full processing in one call for efficiency
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)
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
    
    static func current() -> TimeInterval {
        let storedValue = UserDefaults.standard.double(forKey: storageKey)
        guard storedValue > 0 else { return defaultTimeout }
        return clamp(storedValue)
    }
    
    static func clamp(_ value: TimeInterval) -> TimeInterval {
        return min(max(value, minimumTimeout), maximumTimeout)
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
