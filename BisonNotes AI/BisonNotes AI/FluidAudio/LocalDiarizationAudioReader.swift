import Foundation

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

/// Decodes an audio file to 16 kHz mono Float32 one bounded block at a time.
///
/// Streaming diarizers take 16 kHz mono samples, but decoding a whole meeting
/// into one array costs roughly 230 MB per hour before the model allocates
/// anything, which is enough to get a background job killed on iPhone. This
/// reader holds one source block and one converted block, however long the
/// recording is.
///
/// - Important: Not thread-safe; own it from a single task or actor.
final class LocalDiarizationAudioReader {
    enum ReaderError: Error, LocalizedError, Equatable {
        case unsupportedFormat
        case conversionFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "The source audio format cannot be converted for speaker labeling."
            case .conversionFailed:
                return "The source audio could not be decoded for speaker labeling."
            }
        }
    }

    static let diarizationSampleRate: Double = 16_000

    /// Source frames in the file, used only for progress.
    let sourceFrameCount: AVAudioFramePosition
    private let sourceSampleRate: Double
    private(set) var sourceFramesRead: AVAudioFramePosition = 0

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputFormat: AVAudioFormat
    private let outputCapacity: AVAudioFrameCount
    private var inputExhausted = false
    private var finished = false

    init(
        url: URL,
        sampleRate: Double = LocalDiarizationAudioReader.diarizationSampleRate,
        sourceBlockFrames: AVAudioFrameCount = 1 << 16
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: sourceBlockFrames)
        else {
            throw ReaderError.unsupportedFormat
        }
        // Without this a stereo source is reduced to its first channel, which
        // drops a speaker recorded on the other side of a two-mic setup.
        converter.downmix = true

        self.file = file
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputFormat = outputFormat
        self.sourceFrameCount = file.length
        self.sourceSampleRate = inputFormat.sampleRate
        let ratio = sampleRate / inputFormat.sampleRate
        // Headroom for the resampler's filter tail on the final block.
        self.outputCapacity = AVAudioFrameCount((Double(sourceBlockFrames) * ratio).rounded(.up)) + 1_024
    }

    /// The source's length in seconds, or nil when the file reports no length.
    var sourceDuration: TimeInterval? {
        guard sourceFrameCount > 0, sourceSampleRate > 0 else { return nil }
        return Double(sourceFrameCount) / sourceSampleRate
    }

    /// Fraction of the source decoded so far, or nil when the file reports no length.
    var fractionRead: Double? {
        guard sourceFrameCount > 0 else { return nil }
        return min(1, Double(sourceFramesRead) / Double(sourceFrameCount))
    }

    /// The next block of 16 kHz mono samples, or nil once the file and the
    /// converter's buffered tail are both drained.
    func nextBlock() throws -> [Float]? {
        guard !finished else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw ReaderError.conversionFailed
        }

        var readError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] _, inputStatus in
            guard !inputExhausted, file.framePosition < file.length else {
                inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: inputBuffer, frameCount: inputBuffer.frameCapacity)
            } catch {
                readError = error
                inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard inputBuffer.frameLength > 0 else {
                inputExhausted = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            sourceFramesRead += AVAudioFramePosition(inputBuffer.frameLength)
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let readError {
            throw readError
        }
        if status == .error {
            throw conversionError ?? ReaderError.conversionFailed
        }
        if status == .endOfStream {
            finished = true
        }

        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else {
            // Only a drained stream legitimately yields nothing; anything else
            // would make the caller spin on empty blocks.
            guard finished || inputExhausted else { throw ReaderError.conversionFailed }
            finished = true
            return nil
        }
        guard let channel = output.floatChannelData?[0] else {
            throw ReaderError.conversionFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: frameCount))
    }
}
#endif
