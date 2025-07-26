import Foundation
import CoreLocation

// MARK: - Recording File Structure

struct RecordingFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    let duration: TimeInterval
    let locationData: LocationData?
    
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Transcript Data Structures

struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    
    init(speaker: String, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct TranscriptData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    let segments: [TranscriptSegment]
    let speakerMappings: [String: String] // Maps "Speaker 1" -> "John Doe"
    let createdAt: Date
    let lastModified: Date
    
    init(recordingURL: URL, recordingName: String, recordingDate: Date, segments: [TranscriptSegment], speakerMappings: [String: String] = [:]) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.segments = segments
        self.speakerMappings = speakerMappings
        self.createdAt = Date()
        self.lastModified = Date()
    }
    
    var fullText: String {
        return segments.map { segment in
            let speakerName = speakerMappings[segment.speaker] ?? segment.speaker
            return "\(speakerName): \(segment.text)"
        }.joined(separator: "\n")
    }
    
    var plainText: String {
        return segments.map { $0.text }.joined(separator: " ")
    }
    
    func updatedTranscript(segments: [TranscriptSegment], speakerMappings: [String: String]) -> TranscriptData {
        return TranscriptData(
            recordingURL: self.recordingURL,
            recordingName: self.recordingName,
            recordingDate: self.recordingDate,
            segments: segments,
            speakerMappings: speakerMappings
        )
    }
}

class TranscriptManager: ObservableObject {
    @Published var transcripts: [TranscriptData] = []
    private let transcriptsKey = "SavedTranscripts"
    
    init() {
        loadTranscripts()
    }
    
    func saveTranscript(_ transcript: TranscriptData) {
        if let index = transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
            transcripts[index] = transcript
        } else {
            transcripts.append(transcript)
        }
        saveTranscriptsToDisk()
    }
    
    func updateTranscript(_ transcript: TranscriptData) {
        if let index = transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
            var updatedTranscript = transcript
            updatedTranscript = TranscriptData(
                recordingURL: transcript.recordingURL,
                recordingName: transcript.recordingName,
                recordingDate: transcript.recordingDate,
                segments: transcript.segments,
                speakerMappings: transcript.speakerMappings
            )
            transcripts[index] = updatedTranscript
            saveTranscriptsToDisk()
        }
    }
    
    func deleteTranscript(for recordingURL: URL) {
        transcripts.removeAll { $0.recordingURL == recordingURL }
        saveTranscriptsToDisk()
    }
    
    func getTranscript(for recordingURL: URL) -> TranscriptData? {
        return transcripts.first { $0.recordingURL == recordingURL }
    }
    
    func hasTranscript(for recordingURL: URL) -> Bool {
        return transcripts.contains { $0.recordingURL == recordingURL }
    }
    
    private func saveTranscriptsToDisk() {
        do {
            let data = try JSONEncoder().encode(transcripts)
            UserDefaults.standard.set(data, forKey: transcriptsKey)
        } catch {
            print("Failed to save transcripts: \(error)")
        }
    }
    
    private func loadTranscripts() {
        guard let data = UserDefaults.standard.data(forKey: transcriptsKey) else { return }
        do {
            transcripts = try JSONDecoder().decode([TranscriptData].self, from: data)
        } catch {
            print("Failed to load transcripts: \(error)")
        }
    }
}

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

class SummaryManager: ObservableObject {
    @Published var summaries: [SummaryData] = []
    private let summariesKey = "SavedSummaries"
    
    init() {
        loadSummaries()
    }
    
    func saveSummary(_ summary: SummaryData) {
        summaries.append(summary)
        saveSummariesToDisk()
    }
    
    func updateSummary(_ summary: SummaryData) {
        if let index = summaries.firstIndex(where: { $0.recordingURL == summary.recordingURL }) {
            summaries[index] = summary
            saveSummariesToDisk()
        }
    }
    
    func deleteSummary(for recordingURL: URL) {
        summaries.removeAll { $0.recordingURL == recordingURL }
        saveSummariesToDisk()
    }
    
    func getSummary(for recordingURL: URL) -> SummaryData? {
        return summaries.first { $0.recordingURL == recordingURL }
    }
    
    func hasSummary(for recordingURL: URL) -> Bool {
        return summaries.contains { $0.recordingURL == recordingURL }
    }
    
    private func saveSummariesToDisk() {
        do {
            let data = try JSONEncoder().encode(summaries)
            UserDefaults.standard.set(data, forKey: summariesKey)
        } catch {
            print("Failed to save summaries: \(error)")
        }
    }
    
    private func loadSummaries() {
        guard let data = UserDefaults.standard.data(forKey: summariesKey) else { return }
        do {
            summaries = try JSONDecoder().decode([SummaryData].self, from: data)
        } catch {
            print("Failed to load summaries: \(error)")
        }
    }
} 