import Foundation

// MARK: - Transcript Data Structures

struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Whether this segment's text had a word boundary before it in the
    /// source transcript. Older persisted segments default to true.
    let hasLeadingSpace: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case speaker
        case text
        case startTime
        case endTime
        case hasLeadingSpace
    }

    init(
        speaker: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        hasLeadingSpace: Bool = true
    ) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.hasLeadingSpace = hasLeadingSpace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.speaker = try container.decode(String.self, forKey: .speaker)
        self.text = try container.decode(String.self, forKey: .text)
        self.startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        self.endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        self.hasLeadingSpace = try container.decodeIfPresent(Bool.self, forKey: .hasLeadingSpace) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(hasLeadingSpace, forKey: .hasLeadingSpace)
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
        SpeakerTranscriptAligner.joinWordText(
            segments.map { (text: $0.text, hasLeadingSpace: $0.hasLeadingSpace) }
        )
    }

    /// Text formatted for AI summarization: includes speaker labels when multiple speakers are present.
    var textForSummarization: String {
        let uniqueSpeakers = Set(segments.map { $0.speaker })
        let hasMultipleSpeakers = uniqueSpeakers.count > 1
            || (uniqueSpeakers.count == 1 && uniqueSpeakers.first != "Speaker" && uniqueSpeakers.first != "Unknown")

        guard hasMultipleSpeakers else {
            return plainText
        }

        return segments.map { segment in
            let name = speakerMappings[segment.speaker] ?? formatSpeakerName(segment.speaker)
            return "\(name): \(segment.text)"
        }.joined(separator: "\n")
    }

    private func formatSpeakerName(_ raw: String) -> String {
        // "speaker_1" → "Speaker 1", "speaker_2" → "Speaker 2"
        if raw.hasPrefix("speaker_") {
            let num = raw.dropFirst("speaker_".count)
            return "Speaker \(num)"
        }
        return raw
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

/// Metadata carried by the existing direct rerun replacement path. Keeping
/// this as one value prevents a rerun from dropping labels, engine identity,
/// or its visible recoverable warning while replacing transcript content.
struct TranscriptRerunReplacement {
    let segments: [TranscriptSegment]
    let speakerMappings: [String: String]
    let engine: TranscriptionEngine
    let speakerLabelWarning: LocalSpeakerLabelWarning?

    init(result: TranscriptionResult, engine: TranscriptionEngine) {
        self.segments = result.segments
        self.speakerMappings = result.speakerMappings ?? [:]
        self.engine = engine
        self.speakerLabelWarning = result.speakerLabelWarning
    }
}
