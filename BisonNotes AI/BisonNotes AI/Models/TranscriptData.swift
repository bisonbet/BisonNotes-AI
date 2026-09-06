import Foundation

// MARK: - Transcript Data Structures

/// The model-produced text associated with one original ASR segment.
///
/// The original `TranscriptSegment.text` remains the source of truth for
/// summaries, word timing, and all existing transcript consumers. Cleanup is
/// intentionally additive so older records and older app versions can still
/// read the original transcript.
struct TranscriptSegmentCleanup: Codable, Equatable, Sendable {
    let normalizedText: String
    let modelId: String
    let modelRevision: String
    let promptVersion: String
    let createdAt: Date

    init(
        normalizedText: String,
        modelId: String = TranscriptCleanupSettings.modelId,
        modelRevision: String = TranscriptCleanupSettings.modelRevision,
        promptVersion: String = TranscriptCleanupSettings.promptVersion,
        createdAt: Date = Date()
    ) {
        self.normalizedText = normalizedText
        self.modelId = modelId
        self.modelRevision = modelRevision
        self.promptVersion = promptVersion
        self.createdAt = createdAt
    }
}

enum TranscriptRepresentation: String, CaseIterable, Identifiable, Sendable {
    case original
    case cleaned

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TranscriptSegment: Codable, Identifiable, Sendable {
    let id: UUID
    let speaker: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Whether this segment's text had a word boundary before it in the
    /// source transcript. Older persisted segments default to true.
    let hasLeadingSpace: Bool
    let cleanup: TranscriptSegmentCleanup?

    private enum CodingKeys: String, CodingKey {
        case id
        case speaker
        case text
        case startTime
        case endTime
        case hasLeadingSpace
        case cleanup
    }

    init(
        speaker: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        hasLeadingSpace: Bool = true,
        cleanup: TranscriptSegmentCleanup? = nil
    ) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.hasLeadingSpace = hasLeadingSpace
        self.cleanup = cleanup
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.speaker = try container.decode(String.self, forKey: .speaker)
        self.text = try container.decode(String.self, forKey: .text)
        self.startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        self.endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        self.hasLeadingSpace = try container.decodeIfPresent(Bool.self, forKey: .hasLeadingSpace) ?? true
        self.cleanup = try container.decodeIfPresent(TranscriptSegmentCleanup.self, forKey: .cleanup)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(hasLeadingSpace, forKey: .hasLeadingSpace)
        try container.encodeIfPresent(cleanup, forKey: .cleanup)
    }

    /// Creates a segment with the same identity and timing metadata while
    /// replacing the original text. Editing original text invalidates derived
    /// cleanup by construction.
    func withOriginalText(_ text: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime,
            hasLeadingSpace: hasLeadingSpace,
            cleanup: nil
        )
    }

    /// Creates a segment with the same original text and metadata while
    /// attaching a newly validated cleanup value.
    func withCleanup(_ cleanup: TranscriptSegmentCleanup?) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speaker: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime,
            hasLeadingSpace: hasLeadingSpace,
            cleanup: cleanup
        )
    }

    /// Preserves every field, including segment identity, for callers that
    /// need an explicit immutable copy operation.
    ///
    /// Changing the original text drops any derived cleanup, exactly as
    /// `withOriginalText` does — a cleaned value that describes text which no
    /// longer exists is never carried forward. An explicit `replaceCleanup`
    /// still wins, so a caller can rewrite both halves in one step.
    func preservingIdentity(
        speaker: String? = nil,
        text: String? = nil,
        cleanup: TranscriptSegmentCleanup? = nil,
        replaceCleanup: Bool = false
    ) -> TranscriptSegment {
        let resolvedText = text ?? self.text
        let resolvedCleanup: TranscriptSegmentCleanup?
        if replaceCleanup {
            resolvedCleanup = cleanup
        } else {
            resolvedCleanup = resolvedText == self.text ? self.cleanup : nil
        }

        return TranscriptSegment(
            id: id,
            speaker: speaker ?? self.speaker,
            text: resolvedText,
            startTime: startTime,
            endTime: endTime,
            hasLeadingSpace: hasLeadingSpace,
            cleanup: resolvedCleanup
        )
    }
}

private extension TranscriptSegment {
    init(
        id: UUID,
        speaker: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        hasLeadingSpace: Bool,
        cleanup: TranscriptSegmentCleanup?
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.hasLeadingSpace = hasLeadingSpace
        self.cleanup = cleanup
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
    init(id: UUID, recordingId: UUID?, recordingURL: URL, recordingName: String, recordingDate: Date, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5, createdAt: Date? = nil, lastModified: Date? = nil) {
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
        fullText(for: .original)
    }

    /// Representation-aware full text for ordinary transcript display and
    /// text export. The legacy `fullText` property above remains original-only.
    func fullText(for representation: TranscriptRepresentation) -> String {
        segments.map { segment in
            let speakerName = speakerMappings[segment.speaker] ?? segment.speaker
            return "\(speakerName): \(text(for: segment, representation: representation))"
        }.joined(separator: "\n")
    }

    var plainText: String {
        plainText(for: .original)
    }

    /// Representation-aware text that retains the original segment boundaries
    /// and leading-space metadata.
    func plainText(for representation: TranscriptRepresentation) -> String {
        SpeakerTranscriptAligner.joinWordText(
            segments.map {
                (text: text(for: $0, representation: representation), hasLeadingSpace: $0.hasLeadingSpace)
            }
        )
    }

    var hasCleanedText: Bool {
        segments.contains { $0.cleanup != nil }
    }

    func textForExport(for representation: TranscriptRepresentation) -> String {
        plainText(for: representation)
    }

    func text(for segment: TranscriptSegment, representation: TranscriptRepresentation) -> String {
        guard representation == .cleaned, let normalizedText = segment.cleanup?.normalizedText else {
            return segment.text
        }
        return normalizedText
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

    /// Copies a transcript's identity and durable metadata while changing only
    /// its segment payload or speaker mappings. Cleanup publication uses this
    /// instead of `updatedTranscript`, which intentionally creates a new
    /// transcript identity for its legacy callers.
    func preservingIdentity(
        segments: [TranscriptSegment]? = nil,
        speakerMappings: [String: String]? = nil,
        lastModified: Date = Date()
    ) -> TranscriptData {
        TranscriptData(
            id: id,
            recordingId: recordingId,
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            segments: segments ?? self.segments,
            speakerMappings: speakerMappings ?? self.speakerMappings,
            engine: engine,
            processingTime: processingTime,
            confidence: confidence,
            createdAt: createdAt,
            lastModified: lastModified
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
    let transcriptCleanupWarning: TranscriptCleanupWarning?

    init(result: TranscriptionResult, engine: TranscriptionEngine) {
        self.segments = result.segments
        self.speakerMappings = result.speakerMappings ?? [:]
        self.engine = engine
        self.speakerLabelWarning = result.speakerLabelWarning
        self.transcriptCleanupWarning = result.transcriptCleanupWarning
    }
}
