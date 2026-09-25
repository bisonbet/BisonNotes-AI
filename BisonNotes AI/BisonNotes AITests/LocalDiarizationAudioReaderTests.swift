import AVFoundation
import XCTest
@testable import BisonNotes_AI

final class LocalDiarizationAudioReaderTests: XCTestCase {
    func testResamplesToSixteenKilohertzInBoundedBlocks() throws {
        let url = try makeWAV(sampleRate: 48_000, seconds: 3.5) { _, time in
            0.5 * Float(sin(2 * Double.pi * 440 * time))
        }
        defer { try? FileManager.default.removeItem(at: url) }

        // A small source block forces many blocks and exercises the resampler
        // carrying state across them.
        let reader = try LocalDiarizationAudioReader(url: url, sourceBlockFrames: 4_096)
        var samples: [Float] = []
        var blockCount = 0
        var largestBlock = 0
        while let block = try reader.nextBlock() {
            samples.append(contentsOf: block)
            blockCount += 1
            largestBlock = max(largestBlock, block.count)
        }

        XCTAssertEqual(Double(samples.count), 3.5 * 16_000, accuracy: 64)
        XCTAssertGreaterThan(blockCount, 10)
        XCTAssertLessThanOrEqual(largestBlock, 4_096, "Blocks must stay bounded by the source block size")
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        // A 0.5-amplitude sine has an RMS of about 0.354; the resampler must
        // not attenuate, clip, or drop blocks along the way.
        XCTAssertEqual(rms(samples.dropFirst(1_600).dropLast(1_600)), 0.354, accuracy: 0.02)
        XCTAssertEqual(reader.fractionRead ?? 0, 1, accuracy: 0.0001)
        XCTAssertNil(try reader.nextBlock(), "A drained reader must stay drained")
    }

    func testStereoSourceIsDownmixedRatherThanReducedToOneChannel() throws {
        // Opposite-phase channels cancel only if both are mixed; taking the
        // first channel alone would leave a full-strength tone.
        let url = try makeWAV(sampleRate: 44_100, channels: 2, seconds: 1) { channel, time in
            let tone = 0.5 * Float(sin(2 * Double.pi * 300 * time))
            return channel == 0 ? tone : -tone
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try LocalDiarizationAudioReader(url: url)
        var samples: [Float] = []
        while let block = try reader.nextBlock() {
            samples.append(contentsOf: block)
        }

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 64)
        XCTAssertLessThan(rms(samples[...]), 0.01)
    }

    func testUnreadableFileFailsAtOpenInsteadOfYieldingSilence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LocalDiarizationAudioReader(url: url))
    }

    private func makeWAV(
        sampleRate: Double,
        channels: AVAudioChannelCount = 1,
        seconds: Double,
        sample: (_ channel: Int, _ time: Double) -> Float
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-reader-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        )
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = sample(channel, Double(frame) / sampleRate)
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
