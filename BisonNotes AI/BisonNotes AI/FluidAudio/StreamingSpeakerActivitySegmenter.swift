import Foundation

/// Turns per-frame speaker activity probabilities into speaker intervals as
/// chunks arrive, instead of after the whole recording.
///
/// Produces the same segments as `Nemotron3Diarizer.segments(probabilities:
/// frameCount:numSpeakers:)` over the concatenated chunks: a speaker is active
/// on a frame whose probability exceeds `threshold`, and a run of active frames
/// becomes an interval if it lasts at least `minDurationSeconds`. The SDK
/// function needs every probability for the whole recording at once — 8 floats
/// every 10 ms, about 11.5 MB per hour with no upper bound — which defeated the
/// bounded-memory audio reader feeding it. This keeps one open run per speaker.
///
/// SDK-independent so the equivalence can be tested without models.
struct StreamingSpeakerActivitySegmenter {
    let numSpeakers: Int
    let threshold: Float
    let frameSeconds: Float
    let minDurationSeconds: Float

    /// Frames consumed so far; `frameCount * frameSeconds` is how much audio
    /// the model has actually finished, as opposed to how much was decoded.
    private(set) var frameCount = 0
    private var openRunStarts: [Int?]
    private var intervals: [LocalDiarizationInterval] = []

    /// Defaults match the SDK's `segments` defaults.
    init(
        numSpeakers: Int,
        threshold: Float = 0.5,
        frameSeconds: Float = 0.01,
        minDurationSeconds: Float = 0.2
    ) {
        self.numSpeakers = numSpeakers
        self.threshold = threshold
        self.frameSeconds = frameSeconds
        self.minDurationSeconds = minDurationSeconds
        self.openRunStarts = Array(repeating: nil, count: numSpeakers)
    }

    var processedSeconds: TimeInterval {
        TimeInterval(Float(frameCount) * frameSeconds)
    }

    /// `probabilities` is `[frames × numSpeakers]`, frame-major.
    mutating func append(probabilities: [Float], frameCount chunkFrames: Int) {
        let frames = min(chunkFrames, probabilities.count / max(numSpeakers, 1))
        for localFrame in 0..<frames {
            let frame = frameCount + localFrame
            let row = localFrame * numSpeakers
            for speaker in 0..<numSpeakers {
                let active = probabilities[row + speaker] > threshold
                if active, openRunStarts[speaker] == nil {
                    openRunStarts[speaker] = frame
                } else if !active, let start = openRunStarts[speaker] {
                    closeRun(speaker: speaker, start: start, end: frame)
                }
            }
        }
        frameCount += frames
    }

    /// Closes every run still open at the end of the stream and returns all
    /// intervals ordered by start time, then speaker.
    mutating func finish() -> [LocalDiarizationInterval] {
        for speaker in 0..<numSpeakers {
            if let start = openRunStarts[speaker] {
                closeRun(speaker: speaker, start: start, end: frameCount)
            }
        }
        return intervals.sorted {
            if $0.startTime == $1.startTime {
                return $0.speakerID < $1.speakerID
            }
            return $0.startTime < $1.startTime
        }
    }

    private mutating func closeRun(speaker: Int, start: Int, end: Int) {
        openRunStarts[speaker] = nil
        // Same Float arithmetic as the SDK, so boundaries match it exactly.
        guard Float(end - start) * frameSeconds >= minDurationSeconds else { return }
        intervals.append(
            LocalDiarizationInterval(
                speakerID: "speaker_\(speaker)",
                startTime: TimeInterval(Float(start) * frameSeconds),
                endTime: TimeInterval(Float(end) * frameSeconds)
            )
        )
    }
}
