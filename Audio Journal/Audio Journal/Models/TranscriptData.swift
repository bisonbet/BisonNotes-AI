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