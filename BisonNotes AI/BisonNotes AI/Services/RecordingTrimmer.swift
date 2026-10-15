//
//  RecordingTrimmer.swift
//  BisonNotes AI
//
//  Clips a start/end range out of an existing recording into a new file.
//
//  The source file is only ever read. Writing the clip and giving it a Core
//  Data row is the caller's job (see TrimRecordingView), the same split
//  RecordingCombiner and CombineRecordingsView use.
//

import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Range math

/// Pure time-range rules for a trim, kept free of AVFoundation state so they
/// can be pinned by tests without an audio file.
enum RecordingTrimMath {
    /// The shortest clip a trim may produce. A zero-length export fails inside
    /// AVFoundation with an unhelpful error, so refuse it up front instead.
    static let minimumClipDuration: TimeInterval = 1

    /// Edges closer than this to the file's own edges are treated as untouched,
    /// so a handle dragged "all the way" still reads as the full recording.
    static let edgeTolerance: TimeInterval = 0.05

    /// Clamps a requested range into `[0, duration]` and keeps at least
    /// `minimumClipDuration` between the edges. The edge the user is moving
    /// (`moving`) yields; the other one stays put whenever it can.
    static func clamped(
        start: TimeInterval,
        end: TimeInterval,
        duration: TimeInterval,
        moving: Edge = .end
    ) -> (start: TimeInterval, end: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return (0, 0) }
        let minimumGap = min(minimumClipDuration, duration)
        var start = start.isFinite ? min(max(start, 0), duration) : 0
        var end = end.isFinite ? min(max(end, 0), duration) : duration

        if end - start < minimumGap {
            switch moving {
            case .start:
                start = max(0, end - minimumGap)
                end = max(end, start + minimumGap)
            case .end:
                end = min(duration, start + minimumGap)
                start = min(start, end - minimumGap)
            }
        }
        return (start, end)
    }

    enum Edge: Sendable {
        case start
        case end
    }

    /// True when the range removes something from the recording. Exporting
    /// the whole file again would just duplicate it.
    static func removesAudio(start: TimeInterval, end: TimeInterval, duration: TimeInterval) -> Bool {
        start > edgeTolerance || end < duration - edgeTolerance
    }

    /// Whether `start...end` is a range a trim can export.
    static func isValid(start: TimeInterval, end: TimeInterval, duration: TimeInterval) -> Bool {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else { return false }
        return start >= 0
            && end <= duration + edgeTolerance
            && end - start >= min(minimumClipDuration, duration)
            && removesAudio(start: start, end: end, duration: duration)
    }

    /// The export range. A fine timescale keeps a 3-hour offset exact to the
    /// millisecond; 600 is plenty for video but rounds audio edges visibly.
    static func timeRange(start: TimeInterval, end: TimeInterval) -> CMTimeRange {
        let timescale: CMTimeScale = 48_000
        let startTime = CMTime(seconds: start, preferredTimescale: timescale)
        let endTime = CMTime(seconds: end, preferredTimescale: timescale)
        return CMTimeRange(start: startTime, end: endTime)
    }

    /// Containers whose AAC packets can be copied into an `.m4a` without
    /// decoding. Anything else is re-encoded.
    static let passthroughExtensions: Set<String> = ["m4a", "mp4", "m4b", "aac"]

    static func prefersPassthrough(for url: URL) -> Bool {
        passthroughExtensions.contains(url.pathExtension.lowercased())
    }

    /// The trimmed recording's own date: the moment the kept audio began.
    static func trimmedRecordingDate(sourceDate: Date, start: TimeInterval) -> Date {
        sourceDate.addingTimeInterval(max(0, start))
    }

    /// `h:mm:ss.t` above an hour, `m:ss.t` below — a trim edge needs the tenths
    /// that the player's scrubber leaves out.
    static func formatEdge(_ time: TimeInterval) -> String {
        let tenths = Int((max(time, 0) * 10).rounded())
        let totalSeconds = tenths / 10
        let fraction = tenths % 10
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%d", hours, minutes, seconds, fraction)
        }
        return String(format: "%d:%02d.%d", minutes, seconds, fraction)
    }
}

// MARK: - Export

struct RecordingTrimResult: Sendable {
    let outputURL: URL
    /// Read back from the exported file, never `end - start`: a passthrough
    /// cut lands on AAC packet boundaries, so the real length can differ.
    let duration: TimeInterval
    let fileSize: Int64
    let usedPassthrough: Bool
}

enum RecordingTrimmerError: LocalizedError {
    case invalidRange
    case noAudioTrack
    case exportSessionFailed
    case exportFailed(String)
    case outputUnreadable

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return "Choose a start and end that keep at least one second and remove part of the recording."
        case .noAudioTrack:
            return "This recording does not contain an audio track."
        case .exportSessionFailed:
            return "Failed to create an export session for the trimmed recording."
        case .exportFailed(let message):
            return "Failed to export the trimmed recording: \(message)"
        case .outputUnreadable:
            return "The trimmed recording was written but could not be read back."
        }
    }
}

@MainActor
enum RecordingTrimmer {
    /// Writes `start...end` of `sourceURL` to `outputURL` as `.m4a`.
    ///
    /// Copies the AAC packets when the source allows it, so a 3-hour `.m4a`
    /// trims in seconds; falls back to re-encoding when it does not. On any
    /// failure the partial output is removed before the error is thrown —
    /// nothing references it yet, so nothing else would clean it up.
    static func export(
        sourceURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        outputURL: URL
    ) async throws -> RecordingTrimResult {
        let asset = AVURLAsset(url: sourceURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw RecordingTrimmerError.noAudioTrack
        }
        let sourceDuration = try await asset.load(.duration).seconds
        guard RecordingTrimMath.isValid(start: start, end: end, duration: sourceDuration) else {
            throw RecordingTrimmerError.invalidRange
        }
        let clampedEnd = min(end, sourceDuration)
        let range = RecordingTrimMath.timeRange(start: start, end: clampedEnd)

        var usedPassthrough = false
        if RecordingTrimMath.prefersPassthrough(for: sourceURL),
           await AVAssetExportSession.compatibility(
               ofExportPreset: AVAssetExportPresetPassthrough,
               with: asset,
               outputFileType: .m4a
           ) {
            do {
                try await runExport(asset: asset, preset: AVAssetExportPresetPassthrough, range: range, outputURL: outputURL)
                usedPassthrough = true
            } catch {
                AppLog.shared.recording(
                    "Trim passthrough failed, re-encoding instead: \(error.localizedDescription)",
                    level: .error
                )
                removePartialOutput(at: outputURL)
            }
        }

        do {
            if !usedPassthrough {
                try await runExport(asset: asset, preset: AVAssetExportPresetAppleM4A, range: range, outputURL: outputURL)
            }
            let exported = AVURLAsset(url: outputURL)
            let duration = try await exported.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  try await !exported.loadTracks(withMediaType: .audio).isEmpty else {
                throw RecordingTrimmerError.outputUnreadable
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else { throw RecordingTrimmerError.outputUnreadable }
            AppFileProtection.apply(to: outputURL)

            AppLog.shared.recording(
                "Trimmed \(sourceURL.lastPathComponent) to \(outputURL.lastPathComponent): "
                    + "\(String(format: "%.1f", duration))s, passthrough=\(usedPassthrough)"
            )
            return RecordingTrimResult(
                outputURL: outputURL,
                duration: duration,
                fileSize: fileSize,
                usedPassthrough: usedPassthrough
            )
        } catch {
            removePartialOutput(at: outputURL)
            throw error
        }
    }

    private static func runExport(
        asset: AVURLAsset,
        preset: String,
        range: CMTimeRange,
        outputURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw RecordingTrimmerError.exportSessionFailed
        }
        session.timeRange = range
        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            throw RecordingTrimmerError.exportFailed(error.localizedDescription)
        }
    }

    private static func removePartialOutput(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.shared.fileManagement(
                "Could not remove partial trim output \(url.lastPathComponent): \(error.localizedDescription)",
                level: .error
            )
        }
    }
}

// MARK: - Trailing silence

/// What the trailing-silence scan found. It is a suggestion only: the view
/// offers it, and the user decides whether to move the end handle.
struct TrailingSilenceSuggestion: Equatable, Sendable {
    /// Where the end handle would go: the last sustained activity plus padding.
    let suggestedEnd: TimeInterval
    /// End of the last window that held sustained activity.
    let lastActivityEnd: TimeInterval
    /// How much audio after `suggestedEnd` the scan judged silent.
    var trailingSilence: TimeInterval { max(0, totalDuration - suggestedEnd) }
    let totalDuration: TimeInterval
}

enum TrailingSilenceScanOutcome: Equatable, Sendable {
    /// Sustained activity was found with silence after it.
    case suggestion(TrailingSilenceSuggestion)
    /// Activity runs to (nearly) the end; there is nothing worth cutting.
    case noTrailingSilence
    /// No window anywhere crossed the threshold.
    case entirelySilent
}

/// Scans RMS energy backwards from the end of a file for the last sustained
/// activity. Window levels are computed with Accelerate, as in
/// `AudioCleanupService`.
enum TrailingSilenceDetector {
    struct Configuration: Equatable, Sendable {
        /// Length of each RMS window.
        var windowDuration: TimeInterval = 0.5
        /// A window louder than this counts as activity. Room tone and a
        /// recorder's own hiss sit well below it; quiet speech sits above it.
        var activityThresholdDB: Float = -45
        /// Consecutive active windows needed before activity is believed, so a
        /// lone click or a cough in the dead air does not end the scan.
        var minimumActiveWindows: Int = 3
        /// Kept after the last activity so the final word is not clipped.
        var padding: TimeInterval = 1.5
        /// Less silence than this is not worth suggesting a trim for.
        var minimumTrailingSilence: TimeInterval = 5

        static let standard = Configuration()
    }

    /// Incremental reverse scan over per-window levels, fed from the last
    /// window towards the first. Pure, so the decision can be tested on
    /// synthetic levels; the file reader only feeds it.
    struct ReverseScan: Sendable {
        let configuration: Configuration
        private(set) var activeRun = 0
        /// Index of the highest window in the current active run.
        private(set) var runTopIndex: Int?
        /// Set once a sustained run is found; the scan can stop.
        private(set) var lastActiveWindowIndex: Int?

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        var isFinished: Bool { lastActiveWindowIndex != nil }

        /// Feeds one window's level. Windows must arrive in strictly
        /// descending index order. Returns true once a sustained run is found.
        @discardableResult
        mutating func feed(levelDB: Float, windowIndex: Int) -> Bool {
            guard !isFinished else { return true }
            if levelDB > configuration.activityThresholdDB {
                if activeRun == 0 { runTopIndex = windowIndex }
                activeRun += 1
                if activeRun >= max(1, configuration.minimumActiveWindows) {
                    lastActiveWindowIndex = runTopIndex
                    return true
                }
            } else {
                activeRun = 0
                runTopIndex = nil
            }
            return false
        }

        /// The outcome once the scan has run out of windows (or finished).
        func outcome(totalFrames: Int64, sampleRate: Double, windowFrames: Int) -> TrailingSilenceScanOutcome {
            guard sampleRate > 0, totalFrames > 0 else { return .entirelySilent }
            let totalDuration = Double(totalFrames) / sampleRate
            // A run shorter than the minimum that reaches the start of the file
            // is still the only activity there is — keep it rather than call
            // the recording silent.
            guard let index = lastActiveWindowIndex ?? runTopIndex else { return .entirelySilent }
            let activityEndFrame = min(totalFrames, Int64(index + 1) * Int64(windowFrames))
            let lastActivityEnd = Double(activityEndFrame) / sampleRate
            let suggestedEnd = min(totalDuration, lastActivityEnd + configuration.padding)
            guard totalDuration - suggestedEnd >= configuration.minimumTrailingSilence else {
                return .noTrailingSilence
            }
            return .suggestion(TrailingSilenceSuggestion(
                suggestedEnd: suggestedEnd,
                lastActivityEnd: lastActivityEnd,
                totalDuration: totalDuration
            ))
        }
    }

    /// RMS level in dBFS of each consecutive `windowFrames` slice of
    /// `samples`. The last window may be partial.
    static func windowLevelsDB(_ samples: UnsafeBufferPointer<Float>, windowFrames: Int) -> [Float] {
        guard windowFrames > 0, let base = samples.baseAddress, !samples.isEmpty else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity((samples.count + windowFrames - 1) / windowFrames)
        var offset = 0
        while offset < samples.count {
            let length = min(windowFrames, samples.count - offset)
            var rms: Float = 0
            vDSP_rmsqv(base + offset, 1, &rms, vDSP_Length(length))
            levels.append(20 * log10(max(rms, 1e-10)))
            offset += length
        }
        return levels
    }

    static func windowLevelsDB(_ samples: [Float], windowFrames: Int) -> [Float] {
        samples.withUnsafeBufferPointer { windowLevelsDB($0, windowFrames: windowFrames) }
    }

    /// Runs the reverse scan over in-memory mono samples.
    static func scan(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .standard
    ) -> TrailingSilenceScanOutcome {
        let windowFrames = max(1, Int(configuration.windowDuration * sampleRate))
        let levels = windowLevelsDB(samples, windowFrames: windowFrames)
        var reverse = ReverseScan(configuration: configuration)
        for index in levels.indices.reversed() {
            if reverse.feed(levelDB: levels[index], windowIndex: index) { break }
        }
        return reverse.outcome(totalFrames: Int64(samples.count), sampleRate: sampleRate, windowFrames: windowFrames)
    }

    /// Scans an audio file from its end, decoding only as far back as the
    /// last activity. A 3-hour file with 45 minutes of speech at the front
    /// still decodes the dead air, so the read is chunked, reports progress,
    /// and honours task cancellation.
    @concurrent
    nonisolated static func scan(
        fileURL: URL,
        configuration: Configuration = .standard,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TrailingSilenceScanOutcome {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard sampleRate > 0, totalFrames > 0 else { return .entirelySilent }

        let windowFrames = max(1, Int(configuration.windowDuration * sampleRate))
        let windowCount = Int((totalFrames + Int64(windowFrames) - 1) / Int64(windowFrames))
        // About a minute of audio per read keeps memory flat for any length.
        let windowsPerChunk = max(1, Int(60 / configuration.windowDuration))
        let chunkCapacity = AVAudioFrameCount(windowsPerChunk * windowFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            throw RecordingTrimmerError.outputUnreadable
        }

        var reverse = ReverseScan(configuration: configuration)
        var upperWindow = windowCount
        while upperWindow > 0, !reverse.isFinished {
            try Task.checkCancellation()
            let lowerWindow = max(0, upperWindow - windowsPerChunk)
            let startFrame = Int64(lowerWindow) * Int64(windowFrames)
            let endFrame = min(totalFrames, Int64(upperWindow) * Int64(windowFrames))
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: AVAudioFrameCount(endFrame - startFrame))

            let levels = chunkLevels(buffer: buffer, windowFrames: windowFrames)
            for offset in levels.indices.reversed() {
                if reverse.feed(levelDB: levels[offset], windowIndex: lowerWindow + offset) { break }
            }
            upperWindow = lowerWindow
            progress?(Double(windowCount - upperWindow) / Double(windowCount))
        }
        return reverse.outcome(totalFrames: totalFrames, sampleRate: sampleRate, windowFrames: windowFrames)
    }

    /// Per-window level of a decoded chunk, taking the loudest channel so a
    /// one-sided stereo recording is not halved into silence.
    private static func chunkLevels(buffer: AVAudioPCMBuffer, windowFrames: Int) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        var levels: [Float] = []
        for channel in 0..<Int(buffer.format.channelCount) {
            let channelLevels = windowLevelsDB(
                UnsafeBufferPointer(start: channels[channel], count: frameCount),
                windowFrames: windowFrames
            )
            if levels.isEmpty {
                levels = channelLevels
            } else {
                for index in levels.indices where index < channelLevels.count {
                    levels[index] = max(levels[index], channelLevels[index])
                }
            }
        }
        return levels
    }
}
