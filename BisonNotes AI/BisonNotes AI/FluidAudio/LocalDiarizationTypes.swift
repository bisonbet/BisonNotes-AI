import Foundation

/// The local speaker-labeling method selected for a completed Parakeet job.
///
/// The setting is deliberately separate from the Parakeet setting. A caller
/// must opt in with `LocalSpeakerLabelsConfiguration.isEnabled` before it may
/// prepare or run either diarizer.
public enum LocalDiarizationMethod: String, CaseIterable, Codable, Sendable {
    case offlineVBx
    case experimentalLSEEND

    public static let defaultMethod: LocalDiarizationMethod = .offlineVBx

    public var displayName: String {
        switch self {
        case .offlineVBx:
            return "Offline VBx"
        case .experimentalLSEEND:
            return "LS-EEND"
        }
    }

    public var isExperimental: Bool {
        self == .experimentalLSEEND
    }

    /// LS-EEND's completed-file contract is limited to one hour. VBx has no
    /// app-imposed speaker-count or duration cap in this layer.
    public var maximumSupportedDuration: TimeInterval? {
        switch self {
        case .offlineVBx:
            return nil
        case .experimentalLSEEND:
            return 60 * 60
        }
    }

    /// The initial LS-EEND DIHARD3 model exposes up to ten speaker tracks.
    /// Offline VBx leaves speaker count estimation to the SDK.
    public var maximumSupportedSpeakerCount: Int? {
        switch self {
        case .offlineVBx:
            return nil
        case .experimentalLSEEND:
            return 10
        }
    }
}

/// Settings captured once when a completed Parakeet job starts.
public struct LocalSpeakerLabelsConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var method: LocalDiarizationMethod

    public init(
        isEnabled: Bool = false,
        method: LocalDiarizationMethod = .defaultMethod
    ) {
        self.isEnabled = isEnabled
        self.method = method
    }
}

/// A Foundation-only copy of the token timing data needed by the app. The
/// adapter boundary converts FluidAudio's `TokenTiming` into this value.
public struct TimedTranscriptToken: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let confidence: Double?

    public init(
        text: String,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        confidence: Double? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// A reconstructed ASR word with absolute timing. `hasLeadingSpace` records
/// SentencePiece/TDT word boundaries without putting formatting whitespace in
/// the word itself. The first word's flag is ignored when plain text is built.
public struct TimedTranscriptWord: Codable, Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
    public let confidence: Double?
    public let hasLeadingSpace: Bool

    public init(
        text: String,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        confidence: Double? = nil,
        hasLeadingSpace: Bool = true
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.hasLeadingSpace = hasLeadingSpace
    }
}

/// A raw, app-owned diarizer interval. `speakerID` is the identity emitted by
/// the selected SDK adapter; the aligner converts it to a stable `speaker_N`
/// identity before returning labeled transcript values.
public struct LocalDiarizationInterval: Codable, Equatable, Sendable {
    public let speakerID: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double?

    public init(
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// A sanitized diarizer interval with a stable, first-appearance speaker ID.
public struct NormalizedSpeakerInterval: Codable, Equatable, Sendable {
    public let speakerID: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Double?

    public init(
        speakerID: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.speakerID = speakerID
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

/// The SDK-independent result returned by a concrete diarizer adapter.
public struct LocalDiarizationResult: Codable, Equatable, Sendable {
    public let intervals: [LocalDiarizationInterval]
    public let audioDuration: TimeInterval?

    public init(
        intervals: [LocalDiarizationInterval],
        audioDuration: TimeInterval? = nil
    ) {
        self.intervals = intervals
        self.audioDuration = audioDuration
    }
}

public enum LocalDiarizationProgressPhase: String, Codable, Sendable {
    case preparing
    case downloading
    case loading
    case processing
    case completed
    case cancelling
}

/// Progress emitted by model preparation and complete-file inference. A nil
/// fraction is intentionally supported because the pinned LS-EEND loader does
/// not expose determinate download progress end to end.
public struct LocalDiarizationProgress: Equatable, Sendable {
    public let method: LocalDiarizationMethod
    public let phase: LocalDiarizationProgressPhase
    public let fractionCompleted: Double?

    public init(
        method: LocalDiarizationMethod,
        phase: LocalDiarizationProgressPhase,
        fractionCompleted: Double? = nil
    ) {
        self.method = method
        self.phase = phase
        self.fractionCompleted = fractionCompleted
    }
}

public enum LocalDiarizationModelState: String, Codable, Sendable {
    case downloadRequired
    case preparing
    case ready
    case failed
    case cancelled
}

public struct LocalDiarizationModelStatus: Equatable, Sendable {
    public let method: LocalDiarizationMethod
    public let state: LocalDiarizationModelState
    public let fractionCompleted: Double?

    public init(
        method: LocalDiarizationMethod,
        state: LocalDiarizationModelState,
        fractionCompleted: Double? = nil
    ) {
        self.method = method
        self.state = state
        self.fractionCompleted = fractionCompleted
    }

    public var isReady: Bool {
        state == .ready
    }
}

/// Lifecycle seam used by settings and completed-file orchestration. Missing
/// models are reported by `modelStatus`; `prepareModel` is only called by an
/// explicit user action and must never be reached from transcription as an
/// implicit download.
public protocol LocalDiarizationModelManaging: Sendable {
    func modelStatus(for method: LocalDiarizationMethod) async -> LocalDiarizationModelStatus

    func prepareModel(
        for method: LocalDiarizationMethod,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws

    func cancelModelPreparation(for method: LocalDiarizationMethod) async
    func unloadModel(for method: LocalDiarizationMethod) async
    func deleteModel(for method: LocalDiarizationMethod) async throws
}

/// Injectable complete-file diarization seam. Implementations own all SDK
/// conversion and model resources; callers only see app-owned values.
public protocol LocalDiarizing: Sendable {
    func diarize(
        audioURL: URL,
        method: LocalDiarizationMethod,
        audioDuration: TimeInterval?,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws -> LocalDiarizationResult
}

public enum LocalSpeakerLabelWarning: Codable, Equatable, Sendable {
    case modelNotReady(method: LocalDiarizationMethod)
    case timingUnavailable
    case diarizationFailed(method: LocalDiarizationMethod)
    case cancelled
    case experimentalDurationLimit(duration: TimeInterval, maximumDuration: TimeInterval)

    public var userVisibleMessage: String {
        switch self {
        case .modelNotReady:
            return "Transcription completed without speaker labels. "
                + "Download the speaker model in Settings before trying again."
        case .timingUnavailable:
            return "Transcription completed without speaker labels because timing data was unavailable."
        case .diarizationFailed:
            return "Transcription completed without speaker labels."
        case .cancelled:
            return "Speaker labeling was cancelled; the unlabeled transcript is retained."
        case .experimentalDurationLimit:
            return "Transcription completed without speaker labels. LS-EEND supports completed files up to one hour."
        }
    }
}

public struct LocalSpeakerLabeledSegment: Codable, Equatable, Sendable {
    public static let unknownSpeakerID = "Unknown"

    public let speakerID: String
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let hasLeadingSpace: Bool

    public init(
        speakerID: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        hasLeadingSpace: Bool = true
    ) {
        self.speakerID = speakerID
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.hasLeadingSpace = hasLeadingSpace
    }
}

public struct LocalSpeakerLabelingResult: Codable, Equatable, Sendable {
    public let segments: [LocalSpeakerLabeledSegment]
    public let normalizedIntervals: [NormalizedSpeakerInterval]
    public let warning: LocalSpeakerLabelWarning?
    public let didApplyLabels: Bool

    public init(
        segments: [LocalSpeakerLabeledSegment],
        normalizedIntervals: [NormalizedSpeakerInterval] = [],
        warning: LocalSpeakerLabelWarning? = nil,
        didApplyLabels: Bool? = nil
    ) {
        self.segments = segments
        self.normalizedIntervals = normalizedIntervals
        self.warning = warning
        self.didApplyLabels = didApplyLabels ?? (warning == nil)
    }

    public static func unlabeled(warning: LocalSpeakerLabelWarning) -> LocalSpeakerLabelingResult {
        LocalSpeakerLabelingResult(
            segments: [],
            warning: warning,
            didApplyLabels: false
        )
    }
}

// MARK: - Alignment implementation values

struct SpeakerAlignmentRange {
    let lowerBound: TimeInterval
    let upperBound: TimeInterval

    var duration: TimeInterval {
        upperBound - lowerBound
    }
}

struct SpeakerAlignmentIndexedInterval {
    let stableOrder: Int
    let interval: NormalizedSpeakerInterval
}

struct SpeakerAlignmentRawInterval {
    let inputOrder: Int
    let raw: LocalDiarizationInterval
    let range: SpeakerAlignmentRange
}

struct SpeakerAlignmentSegmentBuilder {
    let speakerID: String
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    let hasLeadingSpace: Bool

    func canMerge(
        speakerID: String,
        startTime: TimeInterval,
        meaningfulSilence: TimeInterval,
        epsilon: TimeInterval
    ) -> Bool {
        guard self.speakerID == speakerID else { return false }
        return startTime - endTime <= meaningfulSilence + epsilon
    }

    mutating func append(
        text: String,
        hasLeadingSpace: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.text = SpeakerTranscriptAligner.joinWordText(
            [(self.text, false), (text, hasLeadingSpace)]
        )
        self.startTime = min(self.startTime, startTime)
        self.endTime = max(self.endTime, endTime)
    }

    func build() -> LocalSpeakerLabeledSegment {
        LocalSpeakerLabeledSegment(
            speakerID: speakerID,
            text: text,
            startTime: startTime,
            endTime: endTime,
            hasLeadingSpace: hasLeadingSpace
        )
    }
}
