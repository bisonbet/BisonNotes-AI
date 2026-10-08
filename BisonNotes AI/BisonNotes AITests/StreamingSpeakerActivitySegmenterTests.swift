import XCTest
@testable import BisonNotes_AI

final class StreamingSpeakerActivitySegmenterTests: XCTestCase {
    /// Streaming must reproduce the SDK's whole-recording segmentation exactly,
    /// however the frames are split into chunks — including runs that cross a
    /// chunk boundary and runs still open at the end of the stream.
    func testMatchesWholeRecordingSegmentationForAnyChunking() {
        var generator = SeededGenerator(seed: 0x5EED)
        let numSpeakers = 8
        let frameCount = 4_000
        let probabilities = Self.speakerTurns(
            frameCount: frameCount,
            numSpeakers: numSpeakers,
            using: &generator
        )
        let expected = Self.referenceSegments(
            probabilities: probabilities,
            frameCount: frameCount,
            numSpeakers: numSpeakers
        )
        XCTAssertGreaterThan(expected.count, 20, "The fixture should exercise many runs")

        for chunkFrames in [1, 7, 128, 1_024, frameCount] {
            var segmenter = StreamingSpeakerActivitySegmenter(numSpeakers: numSpeakers)
            var start = 0
            while start < frameCount {
                let end = min(start + chunkFrames, frameCount)
                segmenter.append(
                    probabilities: Array(probabilities[(start * numSpeakers)..<(end * numSpeakers)]),
                    frameCount: end - start
                )
                start = end
            }
            XCTAssertEqual(segmenter.frameCount, frameCount)
            XCTAssertEqual(segmenter.finish(), expected, "chunk size \(chunkFrames)")
        }
    }

    func testDropsRunsShorterThanTheMinimumAndClosesOpenRunsAtTheEnd() {
        var segmenter = StreamingSpeakerActivitySegmenter(numSpeakers: 2)
        // Speaker 0: 10 frames (0.1 s) — too short. Speaker 1: active from
        // frame 5 to the end of the stream (25 frames, 0.25 s).
        var probabilities: [Float] = []
        for frame in 0..<30 {
            probabilities.append(frame < 10 ? 0.9 : 0.1)
            probabilities.append(frame >= 5 ? 0.9 : 0.1)
        }
        segmenter.append(probabilities: probabilities, frameCount: 30)

        let intervals = segmenter.finish()
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.speakerID, "speaker_1")
        XCTAssertEqual(intervals.first?.startTime ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(intervals.first?.endTime ?? 0, 0.30, accuracy: 1e-6)
    }

    func testProcessedSecondsTracksFramesConsumed() {
        var segmenter = StreamingSpeakerActivitySegmenter(numSpeakers: 8)
        segmenter.append(probabilities: Array(repeating: 0, count: 8 * 250), frameCount: 250)
        XCTAssertEqual(segmenter.processedSeconds, 2.5, accuracy: 1e-6)
    }

    // MARK: - Fixtures

    /// A copy of `Nemotron3Diarizer.segments` from FluidAudio 0.17.7, mapped to
    /// the app's interval type. Kept here so the equivalence is tested without
    /// the SDK or its models.
    private static func referenceSegments(
        probabilities: [Float],
        frameCount: Int,
        numSpeakers: Int,
        threshold: Float = 0.5,
        frameSeconds: Float = 0.01,
        minDurationSeconds: Float = 0.2
    ) -> [LocalDiarizationInterval] {
        var result: [LocalDiarizationInterval] = []
        for speaker in 0..<numSpeakers {
            var start: Int?
            for frame in 0...frameCount {
                let active = frame < frameCount && probabilities[frame * numSpeakers + speaker] > threshold
                if active, start == nil {
                    start = frame
                } else if !active, let runStart = start {
                    if Float(frame - runStart) * frameSeconds >= minDurationSeconds {
                        result.append(
                            LocalDiarizationInterval(
                                speakerID: "speaker_\(speaker)",
                                startTime: TimeInterval(Float(runStart) * frameSeconds),
                                endTime: TimeInterval(Float(frame) * frameSeconds)
                            )
                        )
                    }
                    start = nil
                }
            }
        }
        return result.sorted {
            if $0.startTime == $1.startTime {
                return $0.speakerID < $1.speakerID
            }
            return $0.startTime < $1.startTime
        }
    }

    /// Speakers taking turns of random length with some overlap and some
    /// sub-minimum blips, so both kept and dropped runs occur.
    private static func speakerTurns(
        frameCount: Int,
        numSpeakers: Int,
        using generator: inout SeededGenerator
    ) -> [Float] {
        var probabilities = [Float](repeating: 0.05, count: frameCount * numSpeakers)
        var frame = 0
        while frame < frameCount {
            let speaker = Int.random(in: 0..<numSpeakers, using: &generator)
            let length = Int.random(in: 3...120, using: &generator)
            for offset in 0..<length where frame + offset < frameCount {
                probabilities[(frame + offset) * numSpeakers + speaker] = 0.9
            }
            frame += Int.random(in: 1...length, using: &generator)
        }
        return probabilities
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
