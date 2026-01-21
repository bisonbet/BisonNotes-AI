import Foundation

// MARK: - Content Type

enum ContentType: String, CaseIterable, Codable, Sendable {
    case meeting = "Meeting"
    case personalJournal = "Personal Journal"
    case technical = "Technical"
    case general = "General"
    
    var description: String {
        switch self {
        case .meeting:
            return "Meeting or conversation with multiple participants"
        case .personalJournal:
            return "Personal thoughts, experiences, and reflections"
        case .technical:
            return "Technical discussions, documentation, or instructions"
        case .general:
            return "General content that doesn't fit other categories"
        }
    }
}

// MARK: - Task Item

struct TaskItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let text: String
    let priority: Priority
    let timeReference: String?
    let category: TaskCategory
    let confidence: Double
    
    init(text: String, priority: Priority = .medium, timeReference: String? = nil, category: TaskCategory = .general, confidence: Double = 0.5) {
        self.id = UUID()
        self.text = text
        self.priority = priority
        self.timeReference = timeReference
        self.category = category
        self.confidence = confidence
    }
    
    enum Priority: String, CaseIterable, Codable, Sendable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        
        var color: String {
            switch self {
            case .high: return "red"
            case .medium: return "orange"
            case .low: return "green"
            }
        }
        
        var sortOrder: Int {
            switch self {
            case .high: return 0
            case .medium: return 1
            case .low: return 2
            }
        }
    }
    
    enum TaskCategory: String, CaseIterable, Codable, Sendable {
        case call = "Call"
        case meeting = "Meeting"
        case purchase = "Purchase"
        case research = "Research"
        case email = "Email"
        case travel = "Travel"
        case health = "Health"
        case general = "General"
        
        var icon: String {
            switch self {
            case .call: return "phone"
            case .meeting: return "calendar"
            case .purchase: return "cart"
            case .research: return "magnifyingglass"
            case .email: return "envelope"
            case .travel: return "airplane"
            case .health: return "heart"
            case .general: return "checkmark.circle"
            }
        }
    }
    
    var displayText: String {
        if let timeRef = timeReference {
            return "\(text) (\(timeRef))"
        }
        return text
    }
}

// MARK: - Reminder Item

struct ReminderItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let text: String
    let timeReference: TimeReference
    let urgency: Urgency
    let confidence: Double
    
    init(text: String, timeReference: TimeReference, urgency: Urgency = .later, confidence: Double = 0.5) {
        self.id = UUID()
        self.text = text
        self.timeReference = timeReference
        self.urgency = urgency
        self.confidence = confidence
    }
    
    struct TimeReference: Codable, Equatable, Hashable, Sendable {
        let originalText: String
        let parsedDate: Date?
        let relativeTime: String?
        let isSpecific: Bool

        init(originalText: String, parsedDate: Date? = nil, relativeTime: String? = nil) {
            self.originalText = originalText
            self.parsedDate = parsedDate
            self.relativeTime = relativeTime
            self.isSpecific = parsedDate != nil
        }

        /// Smart initializer that extracts time references from reminder text
        /// If no time reference is found, defaults to "Later" instead of showing full text
        static func fromReminderText(_ text: String) -> TimeReference {
            let lowercased = text.lowercased()

            // Check for common time patterns
            let timePatterns: [(pattern: String, display: String)] = [
                ("today", "Today"),
                ("tomorrow", "Tomorrow"),
                ("tonight", "Tonight"),
                ("this morning", "This morning"),
                ("this afternoon", "This afternoon"),
                ("this evening", "This evening"),
                ("tomorrow morning", "Tomorrow morning"),
                ("tomorrow afternoon", "Tomorrow afternoon"),
                ("tomorrow evening", "Tomorrow evening"),
                ("next week", "Next week"),
                ("this week", "This week"),
                ("next month", "Next month"),
                ("this month", "This month"),
                ("monday", "Monday"),
                ("tuesday", "Tuesday"),
                ("wednesday", "Wednesday"),
                ("thursday", "Thursday"),
                ("friday", "Friday"),
                ("saturday", "Saturday"),
                ("sunday", "Sunday"),
                ("later", "Later"),
                ("soon", "Soon"),
                ("asap", "ASAP"),
                ("immediately", "Immediately"),
                ("urgently", "Urgently")
            ]

            // Find the first matching time pattern
            for (pattern, display) in timePatterns {
                if lowercased.contains(pattern) {
                    return TimeReference(
                        originalText: pattern,
                        parsedDate: nil,
                        relativeTime: display
                    )
                }
            }

            // Check for time patterns like "3pm", "5:30", "at 2:00"
            let timeRegex = try? NSRegularExpression(
                pattern: "\\b(at |by )?\\d{1,2}(:\\d{2})?(am|pm|AM|PM)?\\b",
                options: .caseInsensitive
            )
            if let match = timeRegex?.firstMatch(in: text, range: NSRange(location: 0, length: text.count)) {
                let timeString = String(text[Range(match.range, in: text)!])
                return TimeReference(
                    originalText: timeString.trimmingCharacters(in: .whitespaces),
                    parsedDate: nil,
                    relativeTime: timeString.trimmingCharacters(in: .whitespaces)
                )
            }

            // Default to "Later" if no time reference found
            return TimeReference(
                originalText: "later",
                parsedDate: nil,
                relativeTime: "Later"
            )
        }

        var displayText: String {
            if let relative = relativeTime {
                return relative
            }
            if let date = parsedDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return formatter.string(from: date)
            }
            return originalText
        }
    }
    
    enum Urgency: String, CaseIterable, Codable, Sendable {
        case immediate = "Immediate"
        case today = "Today"
        case thisWeek = "This Week"
        case later = "Later"
        
        var color: String {
            switch self {
            case .immediate: return "red"
            case .today: return "orange"
            case .thisWeek: return "yellow"
            case .later: return "blue"
            }
        }
        
        var sortOrder: Int {
            switch self {
            case .immediate: return 0
            case .today: return 1
            case .thisWeek: return 2
            case .later: return 3
            }
        }
        
        var icon: String {
            switch self {
            case .immediate: return "exclamationmark.triangle.fill"
            case .today: return "clock.fill"
            case .thisWeek: return "calendar"
            case .later: return "clock"
            }
        }
    }
    
    var displayText: String {
        return "\(text) - \(timeReference.displayText)"
    }
}

// MARK: - Title Item

struct TitleItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let text: String
    let confidence: Double
    let category: TitleCategory
    
    init(text: String, confidence: Double = 0.5, category: TitleCategory = .general) {
        self.id = UUID()
        self.text = text
        self.confidence = confidence
        self.category = category
    }
    
    enum TitleCategory: String, CaseIterable, Codable, Sendable {
        case meeting = "Meeting"
        case personal = "Personal"
        case technical = "Technical"
        case general = "General"
        
        var icon: String {
            switch self {
            case .meeting: return "person.2"
            case .personal: return "person"
            case .technical: return "gearshape"
            case .general: return "text.quote"
            }
        }
    }
    
    var displayText: String {
        return text
    }
}

// MARK: - Enhanced Summary Data

public struct EnhancedSummaryData: Codable, Identifiable, Sendable {
    public let id: UUID
    let recordingId: UUID? // For unified architecture
    let transcriptId: UUID? // Optional link to transcript used for generation
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    
    // Core content
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    let titles: [TitleItem]
    
    // Metadata
    let contentType: ContentType
    let aiEngine: String
    let aiModel: String
    let generatedAt: Date
    let version: Int
    let wordCount: Int
    let originalLength: Int
    let compressionRatio: Double
    
    // Quality metrics
    let confidence: Double
    let processingTime: TimeInterval
    
    var qualityDescription: String {
        if confidence >= 0.85 {
            return "High"
        } else if confidence >= 0.7 {
            return "Good"
        } else if confidence >= 0.5 {
            return "Fair"
        } else {
            return "Needs Review"
        }
    }
    
    // Legacy initializer for backward compatibility
    init(recordingURL: URL, recordingName: String, recordingDate: Date, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0) {
        self.id = UUID()
        self.recordingId = nil
        self.transcriptId = nil
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = summary
        self.tasks = tasks.sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        self.reminders = reminders.sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        self.titles = titles.sorted { $0.confidence > $1.confidence }
        self.contentType = contentType
        self.aiEngine = aiEngine
        self.aiModel = aiModel
        self.generatedAt = Date()
        self.version = 1
        self.wordCount = summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.originalLength = originalLength
        self.compressionRatio = originalLength > 0 ? Double(self.wordCount) / Double(originalLength) : 0.0
        self.processingTime = processingTime
        
        // Calculate confidence after all properties are initialized
        let taskConfidence = tasks.isEmpty ? 0.5 : tasks.map { $0.confidence }.reduce(0, +) / Double(tasks.count)
        let reminderConfidence = reminders.isEmpty ? 0.5 : reminders.map { $0.confidence }.reduce(0, +) / Double(reminders.count)
        let titleConfidence = titles.isEmpty ? 0.5 : titles.map { $0.confidence }.reduce(0, +) / Double(titles.count)
        self.confidence = (taskConfidence + reminderConfidence + titleConfidence) / 3.0
    }
    
    // New initializer for unified architecture
    init(recordingId: UUID, transcriptId: UUID? = nil, recordingURL: URL, recordingName: String, recordingDate: Date, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0) {
        self.id = UUID()
        self.recordingId = recordingId
        self.transcriptId = transcriptId
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = summary
        self.tasks = tasks.sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        self.reminders = reminders.sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        self.titles = titles.sorted { $0.confidence > $1.confidence }
        self.contentType = contentType
        self.aiEngine = aiEngine
        self.aiModel = aiModel
        self.generatedAt = Date()
        self.version = 1
        self.wordCount = summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.originalLength = originalLength
        self.compressionRatio = originalLength > 0 ? Double(self.wordCount) / Double(originalLength) : 0.0
        self.processingTime = processingTime
        
        // Calculate confidence after all properties are initialized
        let taskConfidence = tasks.isEmpty ? 0.5 : tasks.map { $0.confidence }.reduce(0, +) / Double(tasks.count)
        let reminderConfidence = reminders.isEmpty ? 0.5 : reminders.map { $0.confidence }.reduce(0, +) / Double(reminders.count)
        let titleConfidence = titles.isEmpty ? 0.5 : titles.map { $0.confidence }.reduce(0, +) / Double(titles.count)
        self.confidence = (taskConfidence + reminderConfidence + titleConfidence) / 3.0
    }
    
    // Initializer for Core Data conversion that preserves the original ID
    init(id: UUID, recordingId: UUID, transcriptId: UUID? = nil, recordingURL: URL, recordingName: String, recordingDate: Date, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0, generatedAt: Date? = nil, version: Int = 1, wordCount: Int? = nil, compressionRatio: Double? = nil, confidence: Double? = nil) {
        self.id = id
        self.recordingId = recordingId
        self.transcriptId = transcriptId
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = summary
        self.tasks = tasks.sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        self.reminders = reminders.sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        self.titles = titles.sorted { $0.confidence > $1.confidence }
        self.contentType = contentType
        self.aiEngine = aiEngine
        self.aiModel = aiModel
        self.generatedAt = generatedAt ?? Date()
        self.version = version
        self.wordCount = wordCount ?? summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.originalLength = originalLength
        self.compressionRatio = compressionRatio ?? (originalLength > 0 ? Double(self.wordCount) / Double(originalLength) : 0.0)
        self.processingTime = processingTime
        self.confidence = confidence ?? {
            let taskConfidence = tasks.isEmpty ? 0.5 : tasks.map { $0.confidence }.reduce(0, +) / Double(tasks.count)
            let reminderConfidence = reminders.isEmpty ? 0.5 : reminders.map { $0.confidence }.reduce(0, +) / Double(reminders.count)
            let titleConfidence = titles.isEmpty ? 0.5 : titles.map { $0.confidence }.reduce(0, +) / Double(titles.count)
            return (taskConfidence + reminderConfidence + titleConfidence) / 3.0
        }()
    }
    
    var formattedCompressionRatio: String {
        return String(format: "%.1f%%", compressionRatio * 100)
    }
    
    var formattedProcessingTime: String {
        return String(format: "%.1fs", processingTime)
    }
}

// MARK: - Summary Statistics

struct SummaryStatistics {
    let totalSummaries: Int
    let averageConfidence: Double
    let averageCompressionRatio: Double
    let totalTasks: Int
    let totalReminders: Int
    let engineUsage: [String: Int]
    
    var formattedAverageConfidence: String {
        return String(format: "%.1f%%", averageConfidence * 100)
    }
    
    var formattedAverageCompressionRatio: String {
        return String(format: "%.1f%%", averageCompressionRatio * 100)
    }
}