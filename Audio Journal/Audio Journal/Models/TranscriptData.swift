import Foundation

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

public struct TranscriptData: Codable, Identifiable {
    public let id: UUID
    var recordingId: UUID? // For unified architecture
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    let segments: [TranscriptSegment]
    let speakerMappings: [String: String] // Maps "Speaker 1" -> "John Doe"
    let engine: TranscriptionEngine?
    let createdAt: Date
    let lastModified: Date
    let processingTime: TimeInterval
    let confidence: Double
    
    // Legacy initializer for backward compatibility
    init(recordingURL: URL, recordingName: String, recordingDate: Date, segments: [TranscriptSegment], speakerMappings: [String: String] = [:]) {
        self.id = UUID()
        self.recordingId = nil
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.segments = segments
        self.speakerMappings = speakerMappings
        self.engine = nil
        self.createdAt = Date()
        self.lastModified = Date()
        self.processingTime = 0
        self.confidence = 0.5
    }
    
    // New initializer for unified architecture
    init(recordingId: UUID, recordingURL: URL, recordingName: String, recordingDate: Date, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) {
        self.id = UUID()
        self.recordingId = recordingId
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.segments = segments
        self.speakerMappings = speakerMappings
        self.engine = engine
        self.createdAt = Date()
        self.lastModified = Date()
        self.processingTime = processingTime
        self.confidence = confidence
    }
    
    // Initializer for Core Data conversion that preserves the original ID
    init(id: UUID, recordingId: UUID, recordingURL: URL, recordingName: String, recordingDate: Date, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5, createdAt: Date? = nil, lastModified: Date? = nil) {
        self.id = id
        self.recordingId = recordingId
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.segments = segments
        self.speakerMappings = speakerMappings
        self.engine = engine
        self.createdAt = createdAt ?? Date()
        self.lastModified = lastModified ?? Date()
        self.processingTime = processingTime
        self.confidence = confidence
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
    
    var wordCount: Int {
        return plainText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }
    
    func updatedTranscript(segments: [TranscriptSegment], speakerMappings: [String: String]) -> TranscriptData {
        return TranscriptData(
            recordingId: self.recordingId ?? UUID(),
            recordingURL: self.recordingURL,
            recordingName: self.recordingName,
            recordingDate: self.recordingDate,
            segments: segments,
            speakerMappings: speakerMappings,
            engine: self.engine,
            processingTime: self.processingTime,
            confidence: self.confidence
        )
    }
}