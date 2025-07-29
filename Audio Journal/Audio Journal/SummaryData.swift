import Foundation

// MARK: - Legacy Summary Data (for backward compatibility)

struct SummaryData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    let summary: String
    let tasks: [String]
    let reminders: [String]
    let createdAt: Date
    
    init(recordingURL: URL, recordingName: String, recordingDate: Date, summary: String, tasks: [String], reminders: [String]) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = summary
        self.tasks = tasks
        self.reminders = reminders
        self.createdAt = Date()
    }
}    

